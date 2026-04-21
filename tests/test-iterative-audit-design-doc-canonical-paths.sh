#!/usr/bin/env bash
# test-iterative-audit-design-doc-canonical-paths.sh -- keep the iterative audit design doc aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/plans/2026-03-15-iterative-audit-design.md"

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

echo "=== Iterative audit design canonical paths ==="

assert_contains 'active contract artifact root (`$ARTIFACT_ROOT`)' "repair brief section introduces canonical artifact root"
assert_contains 'Read $ARTIFACT_ROOT/contract-engineer.json' "engineer invocation reads canonical contract-engineer path"
assert_contains '.signum/contracts/<contractId>/' "per-iteration storage tree uses canonical contract root"
assert_contains 'Full per-iteration artifacts are stored under the active contract artifact root in `iterations/`' "proofpack note uses canonical iteration storage"
assert_contains 'Persist in `$ARTIFACT_ROOT/flaky_tests.json`' "flaky tracker uses canonical artifact root"

assert_not_contains 'Read .signum/contract-engineer.json' "old root contract-engineer read removed"
assert_not_contains 'Write .signum/combined.patch and .signum/execute_log.json.' "old root execute outputs removed"
assert_not_contains 'Full per-iteration artifacts stored in `.signum/iterations/`' "old root iteration storage wording removed"
assert_not_contains 'Persist in `.signum/flaky_tests.json`' "old root flaky storage wording removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
