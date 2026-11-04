#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
APP_PORT="${APP_PORT:-18082}"
PROM_PORT="${PROM_PORT:-19091}"
REQUESTS="${REQUESTS:-40}"
AGENT_MODE="${AGENT_MODE:-openai}"
AGENT_MODEL="${AGENT_MODEL:-gpt-6-luna}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/experiment-001}"

EVIDENCE_FILE="$ARTIFACT_DIR/agent-evidence.json"
DIAGNOSIS_FILE="$ARTIFACT_DIR/agent-diagnosis.json"
EVALUATION_FILE="$ARTIFACT_DIR/agent-evaluation.json"

mkdir -p "$ARTIFACT_DIR"
APP_PF_PID=""
PROM_PF_PID=""

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

kubectl -n "$NAMESPACE" port-forward svc/incident-demo "$APP_PORT:8080" >/tmp/ai-lab-agent-app-pf.log 2>&1 &
APP_PF_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/prometheus "$PROM_PORT:9090" >/tmp/ai-lab-agent-prom-pf.log 2>&1 &
PROM_PF_PID=$!

for i in {1..40}; do
  if curl -fsS "http://127.0.0.1:$APP_PORT/actuator/health" >/dev/null 2>&1 &&
     curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

echo "EXP-001 agent diagnosis / HTTP 500"
echo "1/5 Reset and inject incident"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null
sleep 2
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=errors" >/dev/null

echo "2/5 Generate incident traffic"
REQUESTS="$REQUESTS" DELAY=0.08 bash scenarios/experiment-001/traffic-generator.sh   "http://127.0.0.1:$APP_PORT/api/work"
sleep 4

echo "3/5 Collect read-only evidence and run investigator"
NAMESPACE="$NAMESPACE" PROMETHEUS_URL="http://127.0.0.1:$PROM_PORT" AGENT_MODE="$AGENT_MODE" AGENT_MODEL="$AGENT_MODEL" python3 agent/sre-investigator/investigator.py   --mode "$AGENT_MODE"   --model "$AGENT_MODEL"   --evidence-out "$EVIDENCE_FILE"   --diagnosis-out "$DIAGNOSIS_FILE"

echo "4/5 Evaluate diagnosis against ground truth"
python3 evaluations/reliability/evaluate_diagnosis.py   --diagnosis "$DIAGNOSIS_FILE"   --evidence "$EVIDENCE_FILE"   --out "$EVALUATION_FILE"

echo "5/5 Restore healthy mode"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null

echo "Evidence:   $EVIDENCE_FILE"
echo "Diagnosis:  $DIAGNOSIS_FILE"
echo "Evaluation: $EVALUATION_FILE"
