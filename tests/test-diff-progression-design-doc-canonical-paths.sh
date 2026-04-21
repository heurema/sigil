#!/usr/bin/env bash
# test-diff-progression-design-doc-canonical-paths.sh -- keep diff progression design doc aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/plans/2026-03-15-diff-progression-design.md"

passed=0
failed=0

assert_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

echo "=== Diff progression design canonical paths ==="

assert_contains 'ARTIFACT_ROOT=".signum/contracts/<contractId>"' "design doc introduces canonical artifact root"
assert_contains 'git diff > "$ARTIFACT_ROOT/iteration_delta.patch"' "delta capture writes canonical working copy"
assert_contains 'git diff "$BASE" > "$ARTIFACT_ROOT/combined.patch"' "combined patch capture writes canonical working copy"
assert_contains '.signum/contracts/<contractId>/' "storage tree uses canonical contract root"
assert_contains 'current delta (canonical working copy)' "storage description calls out canonical working copy"

assert_not_contains 'git diff > .signum/iteration_delta.patch' "old root delta capture removed"
assert_not_contains 'git diff $BASE > .signum/combined.patch' "old root combined patch capture removed"
assert_not_contains 'rm -f .signum/iteration_delta.patch .signum/execute_log .signum/combined.patch' "old root stale-clear snippet removed"
assert_not_contains '.signum/iterations/' "old root iteration storage removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
