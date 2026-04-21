#!/usr/bin/env bash
# test-resume-detection-parity.sh -- ensure resume detection uses activeContractId/index with legacy fallback
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_COMMAND="$SCRIPT_DIR/../commands/signum.md"
OVERLAY_COMMAND="$SCRIPT_DIR/../platforms/claude-code/commands/signum.md"

passed=0
failed=0

assert_pass() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — exited non-zero: %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_absent() {
  local name="$1"; shift
  local pattern="$1"; shift
  local file="$1"
  if grep -Fq "$pattern" "$file"; then
    printf '  FAIL: %s — found forbidden pattern: %s\n' "$name" "$pattern"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== Resume detection parity ==="

assert_pass "root command exists" test -f "$ROOT_COMMAND"
assert_pass "overlay command exists" test -f "$OVERLAY_COMMAND"

for command in "$ROOT_COMMAND" "$OVERLAY_COMMAND"; do
  assert_pass "command uses describe_active_contract_state in $(basename "$(dirname "$command")")" \
    grep -Fq 'describe_active_contract_state' "$command"
  assert_pass "command has legacy resumable fallback in $(basename "$(dirname "$command")")" \
    grep -Fq 'LEGACY_RESUMABLE' "$command"
  assert_pass "command has legacy contract-only fallback in $(basename "$(dirname "$command")")" \
    grep -Fq 'LEGACY_CONTRACT_ONLY' "$command"
  assert_pass "command has legacy migration path in $(basename "$(dirname "$command")")" \
    grep -Fq 'set_active_contract "$LEGACY_CONTRACT_ID"' "$command"
  assert_pass "command clears active contract through helper on restart in $(basename "$(dirname "$command")")" \
    grep -Fq 'clear_active_contract >/dev/null 2>&1 || true' "$command"
done

assert_absent "root command removed direct root resumable heuristic" \
  'if [ -f .signum/contract.json ] && [ -f .signum/execution_context.json ]; then' "$ROOT_COMMAND"
assert_absent "overlay command removed direct root EXISTS heuristic" \
  'test -f .signum/contract.json && echo "EXISTS" || echo "NONE"' "$OVERLAY_COMMAND"
assert_absent "root command removed direct activeContractId jq mutation" \
  "jq '.activeContractId = null'" "$ROOT_COMMAND"
assert_absent "overlay command removed direct activeContractId jq mutation" \
  "jq '.activeContractId = null'" "$OVERLAY_COMMAND"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
