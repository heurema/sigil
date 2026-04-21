#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

assert_contains() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "FAIL: $label" >&2
    exit 1
  fi
}

assert_contains "reference iterative env" "$ROOT/docs/reference.md" 'SIGNUM_AUDIT_MAX_ITERATIONS'
assert_contains "reference iteration log" "$ROOT/docs/reference.md" 'audit_iteration_log'
assert_contains "reference iterations dir" "$ROOT/docs/reference.md" 'iterations/'
assert_contains "reference proofpack iterativeAudit" "$ROOT/docs/reference.md" 'iterativeAudit'
assert_contains "pi readme holdout secrecy" "$ROOT/platforms/pi/README.md" 'holdout'
assert_contains "pi readme repair brief" "$ROOT/platforms/pi/README.md" 'repair'
assert_contains "pi readme iterations dir" "$ROOT/platforms/pi/README.md" 'iterations/'

echo "PASS: pi iterative audit docs"
