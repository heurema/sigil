#!/usr/bin/env bash
# release-smoke.sh -- maintainer smoke path for release-time guardrails
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run_step() {
  local label="$1"
  shift
  echo "== $label =="
  "$@"
  echo ""
}

cd "$REPO_ROOT"

run_step "Emporium sync check" bash lib/check-emporium-sync.sh
run_step "/signum:init --harness command surface" bash tests/test-init-command-surface.sh
run_step "/signum:init --harness scaffold coverage" bash tests/test-init-harness-scaffold.sh
run_step "/signum:init --harness brownfield smoke" bash tests/test-brownfield-harness-flow.sh

echo "Release smoke passed."
