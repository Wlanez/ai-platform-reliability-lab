SHELL := /bin/bash
CLUSTER_NAME ?= ai-reliability-lab
NAMESPACE ?= ai-reliability-lab
IMAGE ?= incident-demo:0.1.0
APP_PORT ?= 8080

.PHONY: help doctor up cluster build load deploy wait status test inject-failure inject-latency reset metrics logs down

help:
	@echo "AI Platform Reliability & Security Lab"
	@echo ""
	@echo "make doctor          Check local dependencies"
	@echo "make up              Create cluster, build/load app, deploy, and test"
	@echo "make status          Show cluster/application status"
	@echo "make test            Call the healthy application"
	@echo "make inject-failure  Switch app to HTTP 500 mode"
	@echo "make inject-latency  Switch app to 1500ms latency mode"
	@echo "make reset           Return app to healthy mode"
	@echo "make metrics         Show selected Prometheus-format app metrics"
	@echo "make logs            Tail application logs"
	@echo "make down            Delete the local kind cluster"

doctor:
	@command -v docker >/dev/null || (echo "ERROR: docker is required" && exit 1)
	@docker info >/dev/null 2>&1 || (echo "ERROR: Docker is not running" && exit 1)
	@command -v kind >/dev/null || (echo "ERROR: kind is required. On macOS: brew install kind" && exit 1)
	@command -v kubectl >/dev/null || (echo "ERROR: kubectl is required. On macOS: brew install kubectl" && exit 1)
	@command -v curl >/dev/null || (echo "ERROR: curl is required" && exit 1)
	@echo "OK: Docker, kind, kubectl and curl are available."
	@docker --version
	@kind version
	@kubectl version --client

cluster: doctor
	@if kind get clusters | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		kind create cluster --name "$(CLUSTER_NAME)" --config infrastructure/kind/kind-config.yaml; \
	fi

build:
	docker build --platform linux/arm64 -t "$(IMAGE)" applications/incident-demo

load: cluster build
	kind load docker-image "$(IMAGE)" --name "$(CLUSTER_NAME)"

deploy: load
	kubectl apply -f infrastructure/kubernetes/namespace.yaml
	kubectl apply -f infrastructure/kubernetes/incident-demo.yaml

wait:
	kubectl -n "$(NAMESPACE)" rollout status deployment/incident-demo --timeout=120s

up: deploy wait
	@$(MAKE) test
	@echo ""
	@echo "Lab is ready."
	@echo "Try: make inject-failure && make test"
	@echo "Then: make reset && make inject-latency && make test"

status:
	@kubectl get nodes
	@echo ""
	@kubectl -n "$(NAMESPACE)" get pods,svc

test:
	@set -euo pipefail; \
	kubectl -n "$(NAMESPACE)" port-forward svc/incident-demo $(APP_PORT):8080 >/tmp/ai-lab-port-forward.log 2>&1 & PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	for i in {1..20}; do curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/health >/dev/null 2>&1 && break; sleep 0.5; done; \
	echo "GET /api/work"; \
	curl -sS -w "\nHTTP %{http_code} | total=%{time_total}s\n" http://127.0.0.1:$(APP_PORT)/api/work

inject-failure:
	@$(MAKE) _set-mode MODE=errors

inject-latency:
	@$(MAKE) _set-mode MODE=latency

reset:
	@$(MAKE) _set-mode MODE=healthy

_set-mode:
	@set -euo pipefail; \
	kubectl -n "$(NAMESPACE)" port-forward svc/incident-demo $(APP_PORT):8080 >/tmp/ai-lab-port-forward.log 2>&1 & PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	for i in {1..20}; do curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/health >/dev/null 2>&1 && break; sleep 0.5; done; \
	echo "Setting failure mode to $(MODE)"; \
	curl -fsS -X POST "http://127.0.0.1:$(APP_PORT)/admin/failure?mode=$(MODE)"; echo

metrics:
	@set -euo pipefail; \
	kubectl -n "$(NAMESPACE)" port-forward svc/incident-demo $(APP_PORT):8080 >/tmp/ai-lab-port-forward.log 2>&1 & PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	for i in {1..20}; do curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/health >/dev/null 2>&1 && break; sleep 0.5; done; \
	curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/prometheus | \
		grep -E '^(incident_demo_requests_total|incident_demo_failures_total|incident_demo_mode|http_server_requests_seconds)' || true

logs:
	kubectl -n "$(NAMESPACE)" logs -f deployment/incident-demo

down:
	kind delete cluster --name "$(CLUSTER_NAME)"
