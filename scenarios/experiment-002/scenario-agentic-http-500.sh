#!/usr/bin/env bash
set -euo pipefail
NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
APP_PORT="${APP_PORT:-18083}"
PROM_PORT="${PROM_PORT:-19092}"
PYTHON_BIN="${PYTHON_BIN:-.venv/bin/python}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/experiment-002}"
MODEL="${AGENT_MODEL:-openai/gpt-6.1-terra}"
mkdir -p "$ARTIFACT_DIR"
APP_PID=""; PROM_PID=""
cleanup(){ [[ -n "$APP_PID" ]] && { curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null 2>&1 || true; kill "$APP_PID" 2>/dev/null || true; }; [[ -n "$PROM_PID" ]] && kill "$PROM_PID" 2>/dev/null || true; }
trap cleanup EXIT
kubectl -n "$NAMESPACE" port-forward svc/incident-demo "$APP_PORT:8080" >/tmp/exp002-app-pf.log 2>&1 & APP_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/prometheus "$PROM_PORT:9090" >/tmp/exp002-prom-pf.log 2>&1 & PROM_PID=$!
for i in {1..40}; do curl -fsS "http://127.0.0.1:$APP_PORT/actuator/health" >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1 && break; sleep .5; done
echo "EXP-002 policy-controlled agentic investigation"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=errors" >/dev/null
REQUESTS=40 DELAY=.08 bash scenarios/experiment-001/traffic-generator.sh "http://127.0.0.1:$APP_PORT/api/work"
sleep 4
TOKEN="$(kubectl -n "$NAMESPACE" create token sre-investigator --duration=10m)"
NAMESPACE="$NAMESPACE" KUBERNETES_SERVICE_ACCOUNT=sre-investigator KUBERNETES_TOKEN="$TOKEN" PROMETHEUS_URL="http://127.0.0.1:$PROM_PORT" MODEL_PROVIDER="${MODEL_PROVIDER:-openrouter}" "$PYTHON_BIN" agent/sre-investigator/agentic_investigator.py \
 --model "$MODEL" --audit-out "$ARTIFACT_DIR/tool-audit.jsonl" --diagnosis-out "$ARTIFACT_DIR/diagnosis.json"
"$PYTHON_BIN" evaluations/reliability/evaluate_exp_002.py --diagnosis "$ARTIFACT_DIR/diagnosis.json" --audit "$ARTIFACT_DIR/tool-audit.jsonl" --out "$ARTIFACT_DIR/evaluation.json"
echo "Artifacts: $ARTIFACT_DIR/{tool-audit.jsonl,diagnosis.json,evaluation.json}"
