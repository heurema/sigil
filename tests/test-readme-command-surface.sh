#!/usr/bin/env bash
# test-readme-command-surface.sh -- README public command surface guard
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
README_FILE="$REPO_ROOT/README.md"

passed=0
failed=0

assert_contains() {
  local name="$1" needle="$2"
  if grep -Fq -- "$needle" "$README_FILE"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2"
  if grep -Fq -- "$needle" "$README_FILE"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== README command surface ==="

assert_contains "README has command surface section" "## Command surface"
assert_contains "README uses canonical init command" "/signum:init"
assert_not_contains "README avoids spaced init command" "/signum init"
assert_contains "README documents active contract artifact root" ".signum/contracts/<contractId>/"
assert_contains "README mentions CI wrapper" "lib/signum-ci.sh"
assert_contains "README mentions workflow template" "lib/templates/signum-gate.yml"
assert_contains "README mentions AUTO_OK" "AUTO_OK"
assert_contains "README mentions AUTO_BLOCK" "AUTO_BLOCK"
assert_contains "README mentions HUMAN_REVIEW" "HUMAN_REVIEW"
assert_contains "README references reference docs" "docs/reference.md"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
