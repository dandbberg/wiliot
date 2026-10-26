SHELL := /bin/bash
export AWS_REGION := ca-central-1
export AWS_DEFAULT_REGION := ca-central-1

# staging, perf or prod (envs/<env>/). Only staging is deployed.
ENV ?= staging
ifeq ($(wildcard envs/$(ENV)/infra.tfvars),)
$(error unknown ENV=$(ENV): no envs/$(ENV)/)
endif
# Each environment gets its own Terraform working dir, so switching ENV never
# leaves a stack pointed at another environment's state.
export TF_DATA_DIR := .terraform-$(ENV)
INFRA := terraform -chdir=infra
K8S   := terraform -chdir=k8s
INFRA_VARS := -var-file=../envs/$(ENV)/infra.tfvars
K8S_VARS   := -var-file=../envs/$(ENV)/k8s.tfvars

# Computed once per make run (:=), so images and workloads use the same tag.
# The ECR repo is immutable: every push needs a new tag.
ifndef TAG
TAG := $(shell git rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)
endif

# kubectl for the EKS cluster, kept out of ~/.kube/config (git-ignored).
export KUBECONFIG := $(CURDIR)/eks.kubeconfig

CHAOS := consumer producer broker drain outbox replay keda security

.PHONY: up pushed destroy infra images workloads access kubeconfig urls ui health db chaos $(addprefix chaos-,$(CHAOS)) test validate init-infra init-k8s

## Full deploy: infrastructure, the image, then Argo CD deploys the workloads.
## Ends with the UI links and a first health check (not fatal: still warming up).
up: pushed infra images workloads
	@echo; $(MAKE) -s urls
	@echo
	-@./scripts/health.sh

# Argo CD deploys the charts from GitHub while the image is built from this
# checkout, so both must be the same commit.
pushed:
	@git fetch -q origin main 2>/dev/null || { echo "Argo CD deploys from GitHub: push main there first"; exit 1; }
	@[ -z "$$(git status --porcelain --untracked-files=no)" ] || { echo "Uncommitted changes: commit and push first (Argo CD deploys what is on GitHub)"; exit 1; }
	@[ "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" ] || { echo "HEAD is not origin/main: push (or pull) first"; exit 1; }

init-infra:
	@$(INFRA) init -input=false -backend-config=../envs/$(ENV)/infra.backend.hcl >/dev/null

init-k8s:
	@$(K8S) init -input=false -backend-config=../envs/$(ENV)/k8s.backend.hcl >/dev/null

infra: init-infra
	$(INFRA) apply -input=false $(INFRA_VARS)

## The app image, built here with Docker (CodeBuild isn't available in this account).
images: init-infra
	./scripts/build-push.sh $(TAG)

## Argo CD and the root app (Terraform), then wait until Argo CD has deployed everything.
workloads: init-k8s
	$(K8S) apply -input=false $(K8S_VARS) -var image_tag=$(TAG)
	@$(MAKE) -s kubeconfig
	@./scripts/wait-argo.sh

## For another AWS admin of the account: make yourself cluster admin, then get kubectl.
access: init-infra
	@CLUSTER=$$($(INFRA) output -raw cluster_name) ./scripts/grant-access.sh
	@$(MAKE) -s kubeconfig

kubeconfig: init-infra
	@aws eks update-kubeconfig --name $$($(INFRA) output -raw cluster_name) --kubeconfig $(KUBECONFIG) >/dev/null
	@echo "kubectl: export KUBECONFIG=$(KUBECONFIG)"

## Teardown in reverse order: workloads first so nothing in-cluster holds AWS resources.
destroy: init-k8s init-infra
	$(K8S) destroy -input=false $(K8S_VARS) -var image_tag=unused
	CLUSTER=$$($(INFRA) output -raw cluster_name) ./scripts/wait-k8s-cleanup.sh
	$(INFRA) destroy -input=false $(INFRA_VARS)

## The web UIs' public URLs (allowed IPs only) and where their passwords are.
urls: init-infra
	@h=$$(kubectl -n monitoring get svc ui-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	  [ -n "$$h" ] || { echo "no UI gateway yet (is make workloads done?)"; exit 1; }; \
	  echo "  Grafana       https://$$h:3000/d/trades-pipeline"; \
	  echo "  Kafka UI      https://$$h:8080/ui/clusters/eks/all-topics/trades"; \
	  echo "  Prometheus    https://$$h:9090/alerts"; \
	  echo "  Alertmanager  https://$$h:9093/"; \
	  echo "  Argo CD       https://$$h:8443/"
	@echo
	@echo "  Certificate from the cluster's own CA: the browser warns once (Advanced -> Proceed)."
	@echo "  Grafana needs no login to view. Logins:"
	@echo "    Kafka UI, Prometheus, Alertmanager:  aws secretsmanager get-secret-value --secret-id $$($(INFRA) output -raw ui_admin_secret_name) --query SecretString --output text"
	@echo "    Grafana admin:                       aws secretsmanager get-secret-value --secret-id $$($(INFRA) output -raw grafana_admin_secret_name) --query SecretString --output text"
	@echo "    Argo CD (user admin):                kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

## Fallback without the public gateway: the UIs on localhost via port-forward (Ctrl+C stops).
ui: kubeconfig
	@GRAFANA_ADMIN_SECRET=$$($(INFRA) output -raw grafana_admin_secret_name) ./scripts/ui.sh

## One-command health check: HEALTHY / UNHEALTHY / UNKNOWN (exit 0 / 1 / 2).
health:
	@./scripts/health.sh

## Rows vs distinct trades, missing trade ids, newest trade age.
db:
	@./scripts/check-db.sh

## Stress tests (scripts/chaos.sh): make chaos runs all, make chaos-<test> one.
chaos:
	./scripts/chaos.sh all

$(addprefix chaos-,$(CHAOS)): chaos-%:
	./scripts/chaos.sh $*

## Unit tests, run inside the app image so the local Python version doesn't matter.
test:
	docker build -q -t trades-app:test app >/dev/null
	docker run --rm -v "$(CURDIR)/app/tests:/app/tests:ro" -e PYTHONPATH=/app trades-app:test unittest discover -s tests -v

## Static check of both stacks (no AWS calls).
validate:
	TF_DATA_DIR=.terraform-validate $(INFRA) init -backend=false -input=false >/dev/null && TF_DATA_DIR=.terraform-validate $(INFRA) validate
	TF_DATA_DIR=.terraform-validate $(K8S) init -backend=false -input=false >/dev/null && TF_DATA_DIR=.terraform-validate $(K8S) validate
