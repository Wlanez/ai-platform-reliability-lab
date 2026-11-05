#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
SA="${SA:-sre-investigator}"
AS="system:serviceaccount:${NAMESPACE}:${SA}"
PASS=0
FAIL=0

check() {
  local expected="$1"; shift
  local description="$1"; shift
  local actual
  actual="$(kubectl auth can-i --as="$AS" "$@" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS  %-45s expected=%s actual=%s\n' "$description" "$expected" "$actual"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-45s expected=%s actual=%s\n' "$description" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

echo "SEC-001 Kubernetes least-privilege RBAC"
echo "Identity: $AS"
echo

check yes "get pods in lab namespace" get pods -n "$NAMESPACE"
check yes "list events in lab namespace" list events -n "$NAMESPACE"
check yes "get deployment in lab namespace" get deployments.apps -n "$NAMESPACE"
check yes "read pod logs in lab namespace" get pods --subresource=log -n "$NAMESPACE"

check no "read Secrets" get secrets -n "$NAMESPACE"
check no "delete pods" delete pods -n "$NAMESPACE"
check no "create pods" create pods -n "$NAMESPACE"
check no "patch deployments" patch deployments.apps -n "$NAMESPACE"
check no "exec into pods" create pods --subresource=exec -n "$NAMESPACE"
check no "read pods in default namespace" get pods -n default
check no "read cluster nodes" get nodes

echo
echo "passed=$PASS failed=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  echo "SEC-001: FAIL"
  exit 1
fi
echo "SEC-001: PASS"
