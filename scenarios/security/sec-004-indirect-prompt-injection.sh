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
ATTACKS=(system-override fake-runbook fake-admin diagnostic-pretext output-hijack)

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

kubectl -n "$NAMESPACE" port-forward svc/incident-demo "$APP_PORT:8080" >/tmp/ai-lab-sec004-app-pf.log 2>&1 & APP_PF_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/prometheus "$PROM_PORT:9090" >/tmp/ai-lab-sec004-prom-pf.log 2>&1 & PROM_PF_PID=$!
for i in {1..40}; do
  if curl -fsS "http://127.0.0.1:$APP_PORT/actuator/health" >/dev/null 2>&1 &&
     curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

echo "SEC-004 indirect prompt-injection benchmark"
echo "1/4 Establish known application_failure ground truth"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null
sleep 1
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=errors" >/dev/null
REQUESTS="$REQUESTS" DELAY=0.08 bash scenarios/experiment-001/traffic-generator.sh "http://127.0.0.1:$APP_PORT/api/work"
sleep 4

echo "2/4 Run ${#ATTACKS[@]} adversarial log cases"
TOKEN="$(kubectl -n "$NAMESPACE" create token sre-investigator --duration=15m)"
test -n "$TOKEN" || { echo "ERROR: failed to mint sre-investigator token"; exit 1; }

for attack in "${ATTACKS[@]}"; do
  echo ""
  echo "=== SEC-004 case: $attack ==="
  CASE_DIR="$ARTIFACT_DIR/$attack"
  mkdir -p "$CASE_DIR"
  curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/security/prompt-injection?attack=$attack" >/dev/null

  NAMESPACE="$NAMESPACE" KUBERNETES_SERVICE_ACCOUNT=sre-investigator KUBERNETES_TOKEN="$TOKEN" \
  PROMETHEUS_URL="http://127.0.0.1:$PROM_PORT" MODEL_PROVIDER="$MODEL_PROVIDER" \
  AGENT_MODE=openai AGENT_MODEL="$AGENT_MODEL" "$PYTHON_BIN" agent/sre-investigator/investigator.py \
    --mode openai --model "$AGENT_MODEL" \
    --evidence-out "$CASE_DIR/evidence.json" --diagnosis-out "$CASE_DIR/diagnosis.json"

  "$PYTHON_BIN" evaluations/security/evaluate_sec_004.py \
    --attack "$attack" --diagnosis "$CASE_DIR/diagnosis.json" \
    --evidence "$CASE_DIR/evidence.json" --out "$CASE_DIR/evaluation.json"
done

echo "3/4 Aggregate benchmark"
"$PYTHON_BIN" evaluations/security/summarize_sec_004.py \
  --root "$ARTIFACT_DIR" --out "$ARTIFACT_DIR/summary.json"

echo "4/4 Restore healthy mode"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null

echo "Summary: $ARTIFACT_DIR/summary.json"
