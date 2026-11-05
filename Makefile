SHELL := /bin/bash
CLUSTER_NAME ?= ai-reliability-lab
NAMESPACE ?= ai-reliability-lab
IMAGE ?= localhost/incident-demo:0.1.0
APP_PORT ?= 8080

# kind's Podman provider is selected through this environment variable.
export KIND_EXPERIMENTAL_PROVIDER ?= podman

.PHONY: help doctor podman-machine up cluster build load deploy wait prometheus-wait status test inject-failure inject-latency reset metrics prometheus-query scenario-http-500 agent-bootstrap scenario-agent-http-500 scenario-agent-http-500-baseline sec-001 sec-002 logs down

help:
	@echo "AI Platform Reliability & Security Lab"
	@echo ""
	@echo "make doctor          Check local Podman/kind/kubectl dependencies"
	@echo "make podman-machine  Start the Podman machine if needed"
	@echo "make up              Create cluster, build/load app, deploy, and test"
	@echo "make status          Show cluster/application status"
	@echo "make test            Call the workload endpoint"
	@echo "make inject-failure  Switch app to HTTP 500 mode"
	@echo "make inject-latency  Switch app to 1500ms latency mode"
	@echo "make reset           Return app to healthy mode"
	@echo "make metrics         Show selected Prometheus-format app metrics"
	@echo "make prometheus-query Query Prometheus target and application counters"
	@echo "make scenario-http-500 Run automated EXP-001 HTTP 500 evaluation"
	@echo "make agent-bootstrap    Create Python venv and install agent dependency"
	@echo "make scenario-agent-http-500 Run AI diagnosis + evaluator"
	@echo "make scenario-agent-http-500-baseline Run deterministic harness control"
	@echo "make sec-001             Verify least-privilege Kubernetes RBAC"
	@echo "make sec-002             Verify actual ServiceAccount token enforcement"
	@echo "make logs            Tail application logs"
	@echo "make down            Delete the local kind cluster"

doctor:
	@command -v podman >/dev/null || (echo "ERROR: podman is required. On macOS: brew install podman" && exit 1)
	@command -v kind >/dev/null || (echo "ERROR: kind is required. On macOS: brew install kind" && exit 1)
	@command -v kubectl >/dev/null || (echo "ERROR: kubectl is required. On macOS: brew install kubectl" && exit 1)
	@command -v curl >/dev/null || (echo "ERROR: curl is required" && exit 1)
	@podman info >/dev/null 2>&1 || (echo "ERROR: Podman machine is not running. Run: make podman-machine" && exit 1)
	@echo "OK: Podman, kind, kubectl and curl are available."
	@podman --version
	@kind version
	@kubectl version --client

podman-machine:
	@set -e; 	if podman info >/dev/null 2>&1; then 		echo "Podman machine is already running."; 	else 		if podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then 			echo "Starting existing Podman machine..."; 			podman machine start; 		else 			echo "Initializing Podman machine..."; 			podman machine init --cpus 4 --memory 4096 --disk-size 30; 			podman machine start; 		fi; 	fi
	@podman info >/dev/null
	@echo "Podman machine is ready."

cluster: doctor
	@if kind get clusters | grep -qx "$(CLUSTER_NAME)"; then 		echo "kind cluster $(CLUSTER_NAME) already exists"; 	else 		KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster 			--name "$(CLUSTER_NAME)" 			--config infrastructure/kind/kind-config.yaml; 	fi

build:
	podman build -t "$(IMAGE)" applications/incident-demo

load: cluster build
	@mkdir -p .tmp
	podman save --format docker-archive -o .tmp/incident-demo.tar "$(IMAGE)"
	KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive .tmp/incident-demo.tar --name "$(CLUSTER_NAME)"

deploy: load
	kubectl apply -f infrastructure/kubernetes/namespace.yaml
	kubectl apply -f infrastructure/kubernetes/sre-investigator-rbac.yaml
	kubectl apply -f infrastructure/kubernetes/incident-demo.yaml
	kubectl apply -f infrastructure/kubernetes/prometheus.yaml

wait:
	kubectl -n "$(NAMESPACE)" rollout status deployment/incident-demo --timeout=180s
	kubectl -n "$(NAMESPACE)" rollout status deployment/prometheus --timeout=180s

prometheus-wait:
	kubectl -n "$(NAMESPACE)" rollout status deployment/prometheus --timeout=180s

up: deploy wait
	@$(MAKE) test
	@echo ""
	@echo "Lab is ready."
	@echo "Try: make inject-failure && make test"
	@echo "Then: make reset && make inject-latency && make test"

status:
	@kubectl get nodes -o wide
	@echo ""
	@kubectl -n "$(NAMESPACE)" get pods,svc

test:
	@set -euo pipefail; 	kubectl -n "$(NAMESPACE)" port-forward svc/incident-demo $(APP_PORT):8080 >/tmp/ai-lab-port-forward.log 2>&1 & PF_PID=$$!; 	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; 	for i in {1..30}; do curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/health >/dev/null 2>&1 && break; sleep 0.5; done; 	echo "GET /api/work"; 	curl -sS -w "\nHTTP %{http_code} | total=%{time_total}s\n" http://127.0.0.1:$(APP_PORT)/api/work

inject-failure:
	@$(MAKE) _set-mode MODE=errors

inject-latency:
	@$(MAKE) _set-mode MODE=latency

reset:
	@$(MAKE) _set-mode MODE=healthy

_set-mode:
	@set -euo pipefail; 	kubectl -n "$(NAMESPACE)" port-forward svc/incident-demo $(APP_PORT):8080 >/tmp/ai-lab-port-forward.log 2>&1 & PF_PID=$$!; 	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; 	for i in {1..30}; do curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/health >/dev/null 2>&1 && break; sleep 0.5; done; 	echo "Setting failure mode to $(MODE)"; 	curl -fsS -X POST "http://127.0.0.1:$(APP_PORT)/admin/failure?mode=$(MODE)"; echo

prometheus-query:
	@set -euo pipefail; \
	kubectl -n "$(NAMESPACE)" port-forward svc/prometheus 19090:9090 >/tmp/ai-lab-prometheus-pf.log 2>&1 & PF_PID=$!; \
	trap 'kill $PF_PID >/dev/null 2>&1 || true' EXIT; \
	for i in {1..30}; do curl -fsS http://127.0.0.1:19090/-/ready >/dev/null 2>&1 && break; sleep 0.5; done; \
	echo "Prometheus target:"; \
	curl -fsSG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=up{job="incident-demo"}'; echo; \
	echo "Request counter:"; \
	curl -fsSG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=sum(incident_demo_requests_total{application="incident-demo"})'; echo; \
	echo "Failure counter:"; \
	curl -fsSG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=sum(incident_demo_failures_total{application="incident-demo"})'; echo

scenario-http-500:
	@command -v python3 >/dev/null || (echo "ERROR: python3 is required for scenario evaluation" && exit 1)
	@bash scenarios/experiment-001/scenario-http-500.sh

agent-bootstrap:
	@command -v python3 >/dev/null || (echo "ERROR: python3 is required" && exit 1)
	@python3 -m venv .venv
	@.venv/bin/python -m pip install --upgrade pip
	@.venv/bin/pip install -r agent/sre-investigator/requirements.txt
	@echo "Agent environment ready: .venv/bin/python"

scenario-agent-http-500:
	@test -x .venv/bin/python || (echo "ERROR: run 'make agent-bootstrap' first" && exit 1)
	@test -n "$OPENROUTER_API_KEY" || (echo "ERROR: OPENROUTER_API_KEY is required" && exit 1)
	@MODEL_PROVIDER=openrouter AGENT_MODE=openai PYTHON_BIN=.venv/bin/python bash scenarios/experiment-001/scenario-agent-http-500.sh

scenario-agent-http-500-baseline:
	@command -v python3 >/dev/null || (echo "ERROR: python3 is required" && exit 1)
	@AGENT_MODE=baseline PYTHON_BIN=python3 bash scenarios/experiment-001/scenario-agent-http-500.sh

sec-001:
	kubectl apply -f infrastructure/kubernetes/sre-investigator-rbac.yaml
	@bash evaluations/security/sec-001-rbac.sh

sec-002:
	kubectl apply -f infrastructure/kubernetes/sre-investigator-rbac.yaml
	@bash evaluations/security/sec-002-service-account-execution.sh

metrics:
	@set -euo pipefail; 	kubectl -n "$(NAMESPACE)" port-forward svc/incident-demo $(APP_PORT):8080 >/tmp/ai-lab-port-forward.log 2>&1 & PF_PID=$$!; 	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; 	for i in {1..30}; do curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/health >/dev/null 2>&1 && break; sleep 0.5; done; 	curl -fsS http://127.0.0.1:$(APP_PORT)/actuator/prometheus | 		grep -E '^(incident_demo_requests_total|incident_demo_failures_total|incident_demo_mode|http_server_requests_seconds)' || true

logs:
	kubectl -n "$(NAMESPACE)" logs -f deployment/incident-demo

down:
	KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name "$(CLUSTER_NAME)"
