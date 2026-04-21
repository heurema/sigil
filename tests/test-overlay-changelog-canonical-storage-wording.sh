#!/usr/bin/env bash
# test-overlay-changelog-canonical-storage-wording.sh -- keep overlay changelog iteration wording aligned with canonical contract-root storage
set -euo pipefail

CHANGELOG="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/CHANGELOG.md"

passed=0
failed=0

assert_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$CHANGELOG"; then
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
  if grep -Fq -- "$needle" "$CHANGELOG"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

echo "=== Overlay changelog canonical storage wording ==="

assert_contains 'Lane artifacts in `iterations/NN/lanes/A|B/` under the active contract artifact root' "overlay changelog uses canonical lane artifact wording"
assert_contains 'Per-iteration artifact storage in `iterations/NN/` under the active contract artifact root' "overlay changelog uses canonical iteration wording"

assert_not_contains 'Lane artifacts in `.signum/iterations/NN/lanes/A|B/`' "overlay changelog no longer teaches root lane paths"
assert_not_contains 'Per-iteration artifact storage in `.signum/iterations/NN/`' "overlay changelog no longer teaches root iteration paths"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
