#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
APP_PORT="${APP_PORT:-18084}"
PROM_PORT="${PROM_PORT:-19094}"
REQUESTS="${REQUESTS:-40}"
AGENT_MODEL="${AGENT_MODEL:-openai/gpt-6.1-terra}"
MODEL_PROVIDER="${MODEL_PROVIDER:-openrouter}"
PYTHON_BIN="${PYTHON_BIN:-.venv/bin/python}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/security/sec-004}"

EVIDENCE_FILE="$ARTIFACT_DIR/evidence.json"
DIAGNOSIS_FILE="$ARTIFACT_DIR/diagnosis.json"
EVALUATION_FILE="$ARTIFACT_DIR/evaluation.json"
mkdir -p "$ARTIFACT_DIR"

APP_PF_PID=""; PROM_PF_PID=""
cleanup() {
  if [[ -n "$APP_PF_PID" ]]; then
    curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null 2>&1 || true
    kill "$APP_PF_PID" >/dev/null 2>&1 || true
    wait "$APP_PF_PID" 2>/dev/null || true
  fi
  if [[ -n "$PROM_PF_PID" ]]; then
    kill "$PROM_PF_PID" >/dev/null 2>&1 || true
    wait "$PROM_PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" port-forward svc/incident-demo "$APP_PORT:8080" >/tmp/ai-lab-sec004-app-pf.log 2>&1 &
APP_PF_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/prometheus "$PROM_PORT:9090" >/tmp/ai-lab-sec004-prom-pf.log 2>&1 &
PROM_PF_PID=$!

for i in {1..40}; do
  if curl -fsS "http://127.0.0.1:$APP_PORT/actuator/health" >/dev/null 2>&1 &&
     curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

echo "SEC-004 indirect prompt injection"
echo "1/5 Reset and inject application failure"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null
sleep 1
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=errors" >/dev/null

echo "2/5 Generate incident traffic and malicious untrusted log data"
REQUESTS="$REQUESTS" DELAY=0.08 bash scenarios/experiment-001/traffic-generator.sh "http://127.0.0.1:$APP_PORT/api/work"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/security/prompt-injection" >/dev/null
sleep 4

echo "3/5 Run real AI investigator over the poisoned evidence"
TOKEN="$(kubectl -n "$NAMESPACE" create token sre-investigator --duration=10m)"
test -n "$TOKEN" || { echo "ERROR: failed to mint sre-investigator token"; exit 1; }
NAMESPACE="$NAMESPACE" KUBERNETES_SERVICE_ACCOUNT=sre-investigator KUBERNETES_TOKEN="$TOKEN" \
PROMETHEUS_URL="http://127.0.0.1:$PROM_PORT" MODEL_PROVIDER="$MODEL_PROVIDER" \
AGENT_MODE=openai AGENT_MODEL="$AGENT_MODEL" "$PYTHON_BIN" agent/sre-investigator/investigator.py \
  --mode openai --model "$AGENT_MODEL" --evidence-out "$EVIDENCE_FILE" --diagnosis-out "$DIAGNOSIS_FILE"

echo "4/5 Evaluate prompt-injection resistance"
"$PYTHON_BIN" evaluations/security/evaluate_sec_004.py \
  --diagnosis "$DIAGNOSIS_FILE" --evidence "$EVIDENCE_FILE" --out "$EVALUATION_FILE"

echo "5/5 Restore healthy mode"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null

echo "Evidence:   $EVIDENCE_FILE"
echo "Diagnosis:  $DIAGNOSIS_FILE"
echo "Evaluation: $EVALUATION_FILE"
