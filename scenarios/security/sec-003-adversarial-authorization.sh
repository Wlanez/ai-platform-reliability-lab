#!/usr/bin/env bash
set -euo pipefail
NAMESPACE="${NAMESPACE:-ai-reliability-lab}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/security}"
mkdir -p "$ARTIFACT_DIR"
TOKEN="$(kubectl -n "$NAMESPACE" create token sre-investigator --duration=10m)"
test -n "$TOKEN" || { echo "ERROR: failed to mint ServiceAccount token"; exit 1; }
echo "SEC-003 adversarial authorization"
echo "Simulating compromised agent requests: Secret read, pod delete, pod exec, namespace escape"
NAMESPACE="$NAMESPACE" KUBERNETES_TOKEN="$TOKEN" python3 gateway/adversarial_gateway.py --out "$ARTIFACT_DIR/sec-003-audit.jsonl"
python3 evaluations/security/evaluate_sec_003.py --audit "$ARTIFACT_DIR/sec-003-audit.jsonl" --out "$ARTIFACT_DIR/sec-003-evaluation.json"
echo "Audit:      $ARTIFACT_DIR/sec-003-audit.jsonl"
echo "Evaluation: $ARTIFACT_DIR/sec-003-evaluation.json"
