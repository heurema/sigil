#!/usr/bin/env bash
# test-skill-artifact-root.sh -- keep root SKILL.md aligned with canonical contract-root storage
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/SKILL.md"

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

echo "=== Root skill artifact root ==="

assert_contains '.signum/contracts/<contractId>/' "skill uses canonical active contract artifact root"
assert_contains 'registry/state/archive/compatibility namespace' "skill classifies root signum namespace"
assert_not_contains 'Keep all artifacts in .signum' "unquoted stale root artifact wording removed"
assert_not_contains 'Keep all artifacts in `.signum/`' "quoted stale root artifact wording removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
