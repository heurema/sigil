#!/usr/bin/env bash
# test-migration-notes.sh -- migration notes coverage guard
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/docs/migration-notes.md"
README="$REPO_ROOT/README.md"

passed=0
failed=0

assert_file_exists() {
  local name="$1" file="$2"
  if [ -f "$file" ]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing %s\n' "$name" "$file"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== Migration notes ==="

assert_file_exists "migration notes doc exists" "$DOC"
assert_contains "migration notes document canonical artifact root" "$DOC" ".signum/contracts/<contractId>/"
assert_contains "migration notes document canonical init command" "$DOC" "/signum:init"
assert_not_contains "migration notes avoid spaced init command" "$DOC" "/signum init"
assert_contains "migration notes reference proofpack schema" "$DOC" "lib/schemas/proofpack.schema.json"
assert_contains "migration notes reference proofpack validator" "$DOC" "scripts/validate_proofpack.py"
assert_contains "migration notes reference docs/reference" "$DOC" "docs/reference.md"
assert_contains "migration notes mention current proofpack version" "$DOC" "4.8"
assert_contains "README links migration notes" "$README" "docs/migration-notes.md"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
