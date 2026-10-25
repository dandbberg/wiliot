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

.PHONY: up destroy infra images workloads kubeconfig ui health db chaos $(addprefix chaos-,$(CHAOS)) test validate init-infra init-k8s

## Full deploy: infrastructure, then images, then workloads.
up: infra images workloads

init-infra:
	@$(INFRA) init -input=false -backend-config=../envs/$(ENV)/infra.backend.hcl >/dev/null

init-k8s:
	@$(K8S) init -input=false -backend-config=../envs/$(ENV)/k8s.backend.hcl >/dev/null

infra: init-infra
	$(INFRA) apply -input=false $(INFRA_VARS)

images: init-infra
	./scripts/build-push.sh $(TAG)

workloads: init-k8s
	$(K8S) apply -input=false $(K8S_VARS) -var image_tag=$(TAG)
	$(MAKE) kubeconfig

kubeconfig: init-infra
	@aws eks update-kubeconfig --name $$($(INFRA) output -raw cluster_name) --kubeconfig $(KUBECONFIG) >/dev/null
	@echo "kubectl: export KUBECONFIG=$(KUBECONFIG)"

## Teardown in reverse order: workloads first so nothing in-cluster holds AWS resources.
destroy: init-k8s init-infra
	$(K8S) destroy -input=false $(K8S_VARS) -var image_tag=unused
	./scripts/wait-volumes-gone.sh
	$(INFRA) destroy -input=false $(INFRA_VARS)

## Grafana, Kafka UI, Prometheus and Alertmanager on localhost (Ctrl+C stops).
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
