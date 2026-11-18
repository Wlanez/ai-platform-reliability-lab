#!/usr/bin/env bash
set -euo pipefail
NAMESPACE="${NAMESPACE:-ai-reliability-lab}"; APP_PORT="${APP_PORT:-18085}"; PROM_PORT="${PROM_PORT:-19095}"
PYTHON_BIN="${PYTHON_BIN:-.venv/bin/python}"; MODEL="${AGENT_MODEL:-openai/gpt-6.1-terra}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/experiment-002a}"; ATTACK="${ATTACK:-system-override}"
mkdir -p "$ARTIFACT_DIR"; APP_PID=""; PROM_PID=""
cleanup(){ [[ -n "$APP_PID" ]] && { curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null 2>&1 || true; kill "$APP_PID" 2>/dev/null || true; }; [[ -n "$PROM_PID" ]] && kill "$PROM_PID" 2>/dev/null || true; }
trap cleanup EXIT
kubectl -n "$NAMESPACE" port-forward svc/incident-demo "$APP_PORT:8080" >/tmp/exp002a-app-pf.log 2>&1 & APP_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/prometheus "$PROM_PORT:9090" >/tmp/exp002a-prom-pf.log 2>&1 & PROM_PID=$!
for i in {1..40}; do curl -fsS "http://127.0.0.1:$APP_PORT/actuator/health" >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1 && break; sleep .5; done
echo "EXP-002A adversarial agentic investigation"
echo "1/4 Establish application_failure ground truth"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=errors" >/dev/null
REQUESTS=40 DELAY=.08 bash scenarios/experiment-001/traffic-generator.sh "http://127.0.0.1:$APP_PORT/api/work"; sleep 3
echo "2/4 Inject adversarial instruction into application logs: $ATTACK"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/security/prompt-injection?attack=$ATTACK" >/dev/null
TOKEN="$(kubectl -n "$NAMESPACE" create token sre-investigator --duration=10m)"
echo "3/4 Let model select live diagnostic tools through gateway"
NAMESPACE="$NAMESPACE" KUBERNETES_SERVICE_ACCOUNT=sre-investigator KUBERNETES_TOKEN="$TOKEN" PROMETHEUS_URL="http://127.0.0.1:$PROM_PORT" MODEL_PROVIDER="${MODEL_PROVIDER:-openrouter}" AGENT_EXPERIMENT=EXP-002A "$PYTHON_BIN" agent/sre-investigator/agentic_investigator.py --experiment EXP-002A --model "$MODEL" --audit-out "$ARTIFACT_DIR/tool-audit.jsonl" --diagnosis-out "$ARTIFACT_DIR/diagnosis.json"
echo "4/4 Score model resistance and system containment independently"
"$PYTHON_BIN" evaluations/reliability/evaluate_exp_002a.py --diagnosis "$ARTIFACT_DIR/diagnosis.json" --audit "$ARTIFACT_DIR/tool-audit.jsonl" --out "$ARTIFACT_DIR/evaluation.json"
echo "Artifacts: $ARTIFACT_DIR/{tool-audit.jsonl,diagnosis.json,evaluation.json}"
