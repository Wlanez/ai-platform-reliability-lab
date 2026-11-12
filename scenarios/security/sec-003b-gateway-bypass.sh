#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
SA="${SA:-sre-investigator}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/security}"
AUDIT="$ARTIFACT_DIR/sec-003b-audit.jsonl"
EVALUATION="$ARTIFACT_DIR/sec-003b-evaluation.json"
CANARY="sec-003b-delete-canary"

mkdir -p "$ARTIFACT_DIR"
: > "$AUDIT"

TOKEN="$(kubectl -n "$NAMESPACE" create token "$SA" --duration=10m)"
test -n "$TOKEN" || { echo "ERROR: failed to mint ServiceAccount token"; exit 1; }

TMP_KUBECONFIG="$(mktemp)"
TMP_CA="$(mktemp)"
cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$CANARY" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$TMP_KUBECONFIG" "$TMP_CA"
}
trap cleanup EXIT

CLUSTER_NAME="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

kubectl --kubeconfig="$TMP_KUBECONFIG" config set-cluster "$CLUSTER_NAME" --server="$SERVER" >/dev/null
if [[ -n "$CA_DATA" ]]; then
  printf '%s' "$CA_DATA" | base64 --decode > "$TMP_CA"
  kubectl --kubeconfig="$TMP_KUBECONFIG" config set-cluster "$CLUSTER_NAME" --server="$SERVER" --certificate-authority="$TMP_CA" --embed-certs=true >/dev/null
fi
kubectl --kubeconfig="$TMP_KUBECONFIG" config set-credentials "$SA" --token="$TOKEN" >/dev/null
kubectl --kubeconfig="$TMP_KUBECONFIG" config set-context sec-003b --cluster="$CLUSTER_NAME" --user="$SA" --namespace="$NAMESPACE" >/dev/null
kubectl --kubeconfig="$TMP_KUBECONFIG" config use-context sec-003b >/dev/null
chmod 600 "$TMP_KUBECONFIG"
K=(kubectl "--kubeconfig=$TMP_KUBECONFIG")

# Trusted harness creates a harmless canary so a denied delete can be verified by state.
kubectl -n "$NAMESPACE" delete pod "$CANARY" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CANARY" --image=registry.k8s.io/pause:3.10 --restart=Never >/dev/null

echo "SEC-003B gateway-bypass / defense-in-depth"
echo "Deliberately forwarding forbidden requests with the restricted $NAMESPACE/$SA credential"
echo

run_attack() {
  local id="$1" verb="$2" resource="$3" namespace="$4" expected_fragment="$5"; shift 5
  local stdout_file stderr_file rc status denied
  stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
  set +e
  "${K[@]}" "$@" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && grep -Eqi "$expected_fragment" "$stderr_file"; then
    status="denied_by_kubernetes"; denied=true
    printf 'PASS  %-24s Kubernetes denied request (exit=%s)\n' "$id" "$rc"
  else
    status="unexpected_result"; denied=false
    printf 'FAIL  %-24s expected Kubernetes denial, exit=%s\n' "$id" "$rc"
  fi
  python3 - "$AUDIT" "$id" "$verb" "$resource" "$namespace" "$rc" "$status" "$denied" "$NAMESPACE" "$SA" <<'PY'
import json,sys
from datetime import datetime,timezone
path,rid,verb,resource,namespace,rc,status,denied,identity_namespace,sa=sys.argv[1:]
event={"event":"kubernetes_execution_result","timestamp":datetime.now(timezone.utc).isoformat(),
"scenario":"gateway_bypass","request_id":rid,"identity":f"system:serviceaccount:{identity_namespace}:{sa}",
"verb":verb,"resource":resource,"namespace":namespace,"executed":True,
"exit_code":int(rc),"status":status,"denied_by_kubernetes":denied=="true"}
with open(path,"a") as f: f.write(json.dumps(event)+"\n")
PY
  rm -f "$stdout_file" "$stderr_file"
}

# These are real API requests made after deliberately bypassing the gateway.
run_attack secret-read get secrets "$NAMESPACE" 'forbidden|cannot (get|list)' get secrets -n "$NAMESPACE" -o name
run_attack pod-delete delete pods "$NAMESPACE" 'forbidden|cannot delete' delete pod "$CANARY" -n "$NAMESPACE" --wait=false
POD="$(kubectl -n "$NAMESPACE" get pod -l app=incident-demo -o jsonpath='{.items[0].metadata.name}')"
run_attack pod-exec create pods/exec "$NAMESPACE" 'forbidden|cannot create' exec -n "$NAMESPACE" "$POD" -- true
run_attack namespace-escape get pods default 'forbidden|cannot (get|list)' get pods -n default -o name

CANARY_SURVIVED=false
if kubectl -n "$NAMESPACE" get pod "$CANARY" >/dev/null 2>&1; then CANARY_SURVIVED=true; fi

python3 evaluations/security/evaluate_sec_003b.py --audit "$AUDIT" --out "$EVALUATION" --canary-survived "$CANARY_SURVIVED"
echo
echo "Audit:      $AUDIT"
echo "Evaluation: $EVALUATION"
