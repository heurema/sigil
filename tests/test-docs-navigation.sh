#!/usr/bin/env bash
# test-docs-navigation.sh -- documentation navigation and historical marker guard
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
DOCS_INDEX="$REPO_ROOT/docs/README.md"
PLANS_INDEX="$REPO_ROOT/docs/plans/README.md"
RESEARCH_INDEX="$REPO_ROOT/docs/research/README.md"
ROOT_README="$REPO_ROOT/README.md"

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

echo "=== Documentation navigation ==="

assert_file_exists "docs index exists" "$DOCS_INDEX"
assert_contains "docs index links root README" "$DOCS_INDEX" "../README.md"
assert_contains "docs index links quickstart" "$DOCS_INDEX" "../QUICKSTART.md"
assert_contains "docs index links reference" "$DOCS_INDEX" "reference.md"
assert_contains "docs index links how it works" "$DOCS_INDEX" "how-it-works.md"
assert_contains "docs index links migration notes" "$DOCS_INDEX" "migration-notes.md"
assert_contains "docs index links signum command" "$DOCS_INDEX" "../commands/signum.md"
assert_contains "docs index links init command" "$DOCS_INDEX" "../commands/init.md"
assert_contains "docs index links plans directory" "$DOCS_INDEX" "plans/"
assert_contains "docs index links research directory" "$DOCS_INDEX" "research/"
assert_contains "docs index marks plans and research as background" "$DOCS_INDEX" 'Files under `plans/` and `research/` are background material.'
assert_contains "docs index says plans and research are not canonical runtime docs" "$DOCS_INDEX" "They are not canonical runtime documentation"

assert_file_exists "plans index exists" "$PLANS_INDEX"
assert_contains "plans index links signum command" "$PLANS_INDEX" "../../commands/signum.md"
assert_contains "plans index links init command" "$PLANS_INDEX" "../../commands/init.md"
assert_contains "plans index links reference" "$PLANS_INDEX" "../reference.md"
assert_contains "plans index links migration notes" "$PLANS_INDEX" "../migration-notes.md"

assert_file_exists "research index exists" "$RESEARCH_INDEX"
assert_contains "research index links signum command" "$RESEARCH_INDEX" "../../commands/signum.md"
assert_contains "research index links init command" "$RESEARCH_INDEX" "../../commands/init.md"
assert_contains "research index links reference" "$RESEARCH_INDEX" "../reference.md"
assert_contains "research index links migration notes" "$RESEARCH_INDEX" "../migration-notes.md"

assert_contains "README links docs index" "$ROOT_README" "docs/README.md"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
