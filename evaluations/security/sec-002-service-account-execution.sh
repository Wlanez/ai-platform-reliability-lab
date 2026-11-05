#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
SA="${SA:-sre-investigator}"
TOKEN="$(kubectl -n "$NAMESPACE" create token "$SA" --duration=10m)"
K=(kubectl "--token=$TOKEN")
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
echo "Credential: short-lived token for $NAMESPACE/$SA"
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
