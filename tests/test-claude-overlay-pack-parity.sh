#!/usr/bin/env bash
# test-claude-overlay-pack-parity.sh -- ensure Claude overlay PACK advertises and emits advisory anti-entropy artifact
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMAND="$SCRIPT_DIR/../platforms/claude-code/commands/signum.md"

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

echo "=== Claude overlay PACK parity ==="
assert_pass "overlay command exists" test -f "$COMMAND"
assert_pass "explain mode lists anti-entropy PACK step" grep -Fq '"emit advisory anti-entropy report"' "$COMMAND"
assert_pass "explain mode lists anti-entropy artifact" grep -Fq '"anti_entropy_report.json"' "$COMMAND"
assert_pass "PACK calls pack-anti-entropy wrapper" grep -Fq 'bash lib/pack-anti-entropy.sh' "$COMMAND"
assert_pass "per-contract sync includes anti-entropy artifact" grep -Fq '"anti_entropy_report.json"' "$COMMAND"
assert_pass "per-contract sync uses sync_contract_artifacts helper" grep -Fq 'sync_contract_artifacts "$CONTRACT_ID"' "$COMMAND"
assert_pass "final output shows anti-entropy summary" grep -Fq 'echo "Anti-entropy:' "$COMMAND"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
