#!/usr/bin/env bash
# test-semantic-drift-research-canonical-paths.sh -- keep semantic drift research doc aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/research/2026-03-15-signum-codex-semantic-drift-across-contracts.md"

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

echo "=== Semantic drift research canonical paths ==="

assert_contains '.signum/contracts/<contractId>/contract.json' "research doc uses canonical task contract path"
assert_not_contains '.signum/contract.json' "old root task contract path removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
