#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
SA="${SA:-sre-investigator}"
TOKEN="$(kubectl -n "$NAMESPACE" create token "$SA" --duration=10m)"
TMP_KUBECONFIG="$(mktemp)"
trap 'rm -f "$TMP_KUBECONFIG"' EXIT

CURRENT_CONTEXT="$(kubectl config current-context)"
CLUSTER_NAME="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

kubectl --kubeconfig="$TMP_KUBECONFIG" config set-cluster "$CLUSTER_NAME" --server="$SERVER" >/dev/null
if [[ -n "$CA_DATA" ]]; then
  printf '%s' "$CA_DATA" | base64 --decode > "$TMP_KUBECONFIG.ca"
  trap 'rm -f "$TMP_KUBECONFIG" "$TMP_KUBECONFIG.ca"' EXIT
  kubectl --kubeconfig="$TMP_KUBECONFIG" config set-cluster "$CLUSTER_NAME" --server="$SERVER" --certificate-authority="$TMP_KUBECONFIG.ca" --embed-certs=true >/dev/null
fi
kubectl --kubeconfig="$TMP_KUBECONFIG" config set-credentials "$SA" --token="$TOKEN" >/dev/null
kubectl --kubeconfig="$TMP_KUBECONFIG" config set-context sec-002 --cluster="$CLUSTER_NAME" --user="$SA" --namespace="$NAMESPACE" >/dev/null
kubectl --kubeconfig="$TMP_KUBECONFIG" config use-context sec-002 >/dev/null
chmod 600 "$TMP_KUBECONFIG"

K=(kubectl "--kubeconfig=$TMP_KUBECONFIG")
PASS=0
FAIL=0

check() {
  local expected="$1"; shift
  local description="$1"; shift
  local actual
  actual="$("${K[@]}" auth can-i "$@" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS  %-48s expected=%s actual=%s\n' "$description" "$expected" "$actual"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-48s expected=%s actual=%s\n' "$description" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

echo "SEC-002 Actual ServiceAccount credential enforcement"
echo "Credential: isolated kubeconfig containing only $NAMESPACE/$SA token"
echo

check yes "token can read lab pods" get pods -n "$NAMESPACE"
check yes "token can read lab pod logs" get pods --subresource=log -n "$NAMESPACE"
check no "token cannot read Secrets" get secrets -n "$NAMESPACE"
check no "token cannot delete pods" delete pods -n "$NAMESPACE"
check no "token cannot exec into pods" create pods --subresource=exec -n "$NAMESPACE"
check no "token cannot escape to default namespace" get pods -n default
check no "token cannot read cluster nodes" get nodes

echo
echo "passed=$PASS failed=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  echo "SEC-002: FAIL"
  exit 1
fi
echo "SEC-002: PASS"
