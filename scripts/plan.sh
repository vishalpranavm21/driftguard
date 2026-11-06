#!/usr/bin/env bash
# Infrastructure drift detection + AI risk score + OPA gate (the Atlantis workflow, as a script).
# Exit codes: 0 in sync or healed, 1 error, 2 blocked by policy.
set -uo pipefail
cd "$(dirname "$0")/../infra"

tofu init -input=false >/dev/null
tofu plan -input=false -no-color -detailed-exitcode -out=tf.plan >/tmp/plan.txt; rc=$?
if [ $rc -eq 0 ]; then echo "No drift: infrastructure matches code."; exit 0; fi
if [ $rc -eq 1 ]; then cat /tmp/plan.txt; echo "plan failed"; exit 1; fi

echo ">>> Changes detected:"
grep -E "^\s+[~+-] |will be|must be" /tmp/plan.txt || true
tofu show -json tf.plan > plan.json

echo ">>> AI risk score"
curl -sf --max-time 90 -X POST "${ENGINE_URL:-http://localhost:8088}/score/plan" \
     -H 'content-type: application/json' --data-binary @plan.json > risk.json \
  || echo '{"risk_score":100,"category":"dangerous","reasons":["engine unreachable (fail-closed)"]}' > risk.json
jq '{risk_score, category, reasons}' risk.json

echo ">>> OPA policy gate"
if conftest test --no-color --policy ../policies/rego/risk risk.json \
   && conftest test --no-color --policy ../policies/rego/plan plan.json; then
  echo ">>> Gate passed: applying"
  tofu apply -input=false -no-color tf.plan
else
  echo "BLOCKED by policy. Nothing was applied."
  exit 2
fi
