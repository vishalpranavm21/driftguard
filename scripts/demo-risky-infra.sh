#!/usr/bin/env bash
# Demo: a developer tries a risky infrastructure change in code (CORS "*" + debug mode).
# plan.sh must print BLOCKED. infra/main.tf is ALWAYS restored afterwards, even on error/interrupt.
set -uo pipefail
cd "$(dirname "$0")/.."
BACKUP=$(mktemp)
cp infra/main.tf "$BACKUP"
restore() {
  [ -f "$BACKUP" ] || return 0
  cp "$BACKUP" infra/main.tf && rm -f "$BACKUP" && echo ">>> infra/main.tf restored to the safe version"
}
trap restore EXIT
trap 'exit 130' INT TERM   # exiting fires the EXIT trap, so main.tf is restored

echo ">>> Editing infra/main.tf: allowed_origins = \"*\", debug_mode = \"true\""
sed -i 's#allowed_origins = "https://driftguard.example.com"#allowed_origins = "*"#; s#debug_mode      = "false"#debug_mode      = "true"#' infra/main.tf
grep -nE 'allowed_origins|debug_mode' infra/main.tf

bash scripts/plan.sh; rc=$?
echo ">>> plan.sh exit code: $rc (2 = blocked by policy)"
exit $rc
