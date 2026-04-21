#!/usr/bin/env bash
# test-extractable-checks-research-canonical-paths.sh -- keep extractable-checks research doc aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/research/2026-03-15-extractable-checks-architecture.md"

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

echo "=== Extractable checks research canonical paths ==="

assert_contains 'CONTRACT_PATH=".signum/contracts/<contractId>/contract.json"' "research doc introduces canonical contract path variable"
assert_contains 'RESULT=$(lib/glossary-check.sh "$CONTRACT_PATH" "$GLOSSARY_PATH" 2>/dev/null || echo '\''{}'\'')' "research doc uses canonical contract path in glossary-check example"
assert_not_contains 'RESULT=$(lib/glossary-check.sh .signum/contract.json "$GLOSSARY_PATH" 2>/dev/null || echo '\''{}'\'')' "old root contract path example removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
