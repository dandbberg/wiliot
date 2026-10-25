SHELL := /bin/bash
export AWS_REGION := ca-central-1
export AWS_DEFAULT_REGION := ca-central-1

# Computed once per make run (:=), so images and workloads use the same tag.
# The ECR repo is immutable: every push needs a new tag.
ifndef TAG
TAG := $(shell git rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)
endif

# kubectl for the EKS cluster, kept out of ~/.kube/config (git-ignored).
EKS_KUBECONFIG := $(CURDIR)/eks.kubeconfig

.PHONY: up down infra images workloads kubeconfig ui health fmt validate test

## Full deploy: infrastructure, then images, then workloads.
up: infra images workloads

infra:
	terraform -chdir=infra init -input=false
	terraform -chdir=infra apply -input=false

images:
	./scripts/build-push.sh $(TAG)

workloads:
	terraform -chdir=k8s init -input=false
	terraform -chdir=k8s apply -input=false -var image_tag=$(TAG)
	$(MAKE) kubeconfig

kubeconfig:
	aws eks update-kubeconfig --name dan-berg --kubeconfig $(EKS_KUBECONFIG) --alias dan-berg-eks >/dev/null
	@echo "kubectl: export KUBECONFIG=$(EKS_KUBECONFIG)"

## Teardown in reverse order: workloads first so nothing in-cluster holds AWS resources.
down:
	terraform -chdir=k8s init -input=false
	terraform -chdir=k8s destroy -input=false -var image_tag=unused
	./scripts/wait-volumes-gone.sh
	terraform -chdir=infra init -input=false
	terraform -chdir=infra destroy -input=false

## Grafana, Kafka UI, Prometheus and Alertmanager on localhost (Ctrl+C stops).
ui:
	@./scripts/ui.sh

## One-command health check: HEALTHY / UNHEALTHY / UNKNOWN (exit 0 / 1 / 2).
health:
	@KUBECONFIG=$(EKS_KUBECONFIG) ./scripts/health.sh

fmt:
	terraform fmt -recursive

## Unit tests, run inside the app image so the local Python version doesn't matter.
test:
	docker build -q -t trades-app:test app >/dev/null
	docker run --rm -v "$(CURDIR)/app/tests:/app/tests:ro" -e PYTHONPATH=/app trades-app:test unittest discover -s tests -v

validate:
	terraform -chdir=infra init -backend=false -input=false >/dev/null && terraform -chdir=infra validate
	terraform -chdir=k8s init -backend=false -input=false >/dev/null && terraform -chdir=k8s validate
