#!/usr/bin/env bash
set -euo pipefail

URL="${1:-http://127.0.0.1:8080/api/work}"
REQUESTS="${REQUESTS:-40}"
DELAY="${DELAY:-0.10}"

success=0
errors=0

for ((i=1; i<=REQUESTS; i++)); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$URL" || true)"
  if [[ "$code" =~ ^2 ]]; then
    success=$((success + 1))
  else
    errors=$((errors + 1))
  fi
  sleep "$DELAY"
done

echo "traffic requests=$REQUESTS success=$success errors=$errors"
