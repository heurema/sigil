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
assert_pass "per-contract canonical verification includes anti-entropy artifact" grep -Fq '"anti_entropy_report.json"' "$COMMAND"
assert_pass "per-contract PACK uses canonical verification helper" grep -Fq 'verify_canonical_contract_artifacts "$CONTRACT_ID"' "$COMMAND"
assert_pass "PACK emits releaseVerdict for validator compatibility" grep -Fq 'releaseVerdict: $releaseVerdict' "$COMMAND"
assert_pass "PACK emits timing for validator compatibility" grep -Fq 'timing: { startedAt:' "$COMMAND"
assert_pass "PACK emits reviewCoverage for validator compatibility" grep -Fq 'reviewCoverage: { availableReviews:' "$COMMAND"
assert_pass "PACK builds Codebase Awareness reuse summary" grep -Fq 'PROOFPACK_REUSE_SUMMARY' "$COMMAND"
assert_pass "PACK calls reuse summary wrapper" grep -Fq 'scripts/build_reuse_summary.py' "$COMMAND"
assert_pass "PACK includes Codebase Awareness proofpack section" grep -Fq '.codebaseAwareness = $codebaseAwarenessJson' "$COMMAND"
assert_pass "PACK references reuse_summary artifact" grep -Fq 'reuse_summary.json' "$COMMAND"
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
