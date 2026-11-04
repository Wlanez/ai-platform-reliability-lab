#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
APP_PORT="${APP_PORT:-18080}"
PROM_PORT="${PROM_PORT:-19090}"
REQUESTS="${REQUESTS:-40}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-0.90}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/experiment-001}"
RESULT_FILE="$ARTIFACT_DIR/http-500-result.json"

mkdir -p "$ARTIFACT_DIR"

APP_PF_PID=""
PROM_PF_PID=""

cleanup() {
  [[ -n "$APP_PF_PID" ]] && kill "$APP_PF_PID" >/dev/null 2>&1 || true
  [[ -n "$PROM_PF_PID" ]] && kill "$PROM_PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" port-forward svc/incident-demo "$APP_PORT:8080" >/tmp/ai-lab-app-pf.log 2>&1 &
APP_PF_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/prometheus "$PROM_PORT:9090" >/tmp/ai-lab-prom-pf.log 2>&1 &
PROM_PF_PID=$!

for i in {1..40}; do
  if curl -fsS "http://127.0.0.1:$APP_PORT/actuator/health" >/dev/null 2>&1 &&
     curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

query_prometheus() {
  local query="$1"
  curl -fsSG "http://127.0.0.1:$PROM_PORT/api/v1/query"     --data-urlencode "query=$query" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["data"]["result"]; print(r[0]["value"][1] if r else "0")'
}

wait_for_target() {
  for i in {1..30}; do
    up="$(query_prometheus 'up{job="incident-demo"}')"
    if [[ "$up" == "1" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Prometheus never reported incident-demo as up" >&2
  exit 1
}

echo "EXP-001-http-500"
echo "1/6 Prometheus target readiness"
wait_for_target

echo "2/6 Reset application to healthy"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null
sleep 3

echo "3/6 Generate healthy baseline traffic"
REQUESTS=10 DELAY=0.05 ./scenarios/experiment-001/traffic-generator.sh   "http://127.0.0.1:$APP_PORT/api/work"
sleep 3

before_requests="$(query_prometheus 'sum(incident_demo_requests_total{application="incident-demo"})')"
before_failures="$(query_prometheus 'sum(incident_demo_failures_total{application="incident-demo"})')"

echo "   baseline requests=$before_requests failures=$before_failures"

echo "4/6 Inject HTTP 500 failure"
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=errors" >/dev/null

echo "5/6 Generate incident traffic"
REQUESTS="$REQUESTS" DELAY=0.10 ./scenarios/experiment-001/traffic-generator.sh   "http://127.0.0.1:$APP_PORT/api/work"
sleep 4

after_requests="$(query_prometheus 'sum(incident_demo_requests_total{application="incident-demo"})')"
after_failures="$(query_prometheus 'sum(incident_demo_failures_total{application="incident-demo"})')"
mode="$(query_prometheus 'incident_demo_mode{application="incident-demo"}')"
target_up="$(query_prometheus 'up{job="incident-demo"}')"

echo "6/6 Evaluate observed Prometheus deltas"

python3 - "$before_requests" "$before_failures" "$after_requests" "$after_failures" "$mode" "$target_up" "$ERROR_THRESHOLD" "$RESULT_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone

before_req, before_fail, after_req, after_fail, mode, target_up, threshold, result_file = sys.argv[1:]
before_req = float(before_req)
before_fail = float(before_fail)
after_req = float(after_req)
after_fail = float(after_fail)
mode = float(mode)
target_up = float(target_up)
threshold = float(threshold)

request_delta = after_req - before_req
failure_delta = after_fail - before_fail
error_rate = failure_delta / request_delta if request_delta > 0 else 0.0

passed = (
    request_delta > 0
    and failure_delta > 0
    and error_rate >= threshold
    and mode == 1.0
    and target_up == 1.0
)

result = {
    "experiment": "EXP-001-http-500",
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "expected": {
        "mode": "errors",
        "minimum_error_rate": threshold,
        "prometheus_target_up": True,
    },
    "observed": {
        "request_delta": request_delta,
        "failure_delta": failure_delta,
        "error_rate": error_rate,
        "mode_metric": mode,
        "prometheus_target_up": target_up == 1.0,
    },
    "result": "PASS" if passed else "FAIL",
}

with open(result_file, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2)
    f.write("\n")

print(json.dumps(result, indent=2))
sys.exit(0 if passed else 1)
PY

# Always restore healthy mode after a successful evaluation.
curl -fsS -X POST "http://127.0.0.1:$APP_PORT/admin/failure?mode=healthy" >/dev/null
echo "Result written to $RESULT_FILE"
