#!/usr/bin/env bash
# test-contract-hierarchy-research-canonical-paths.sh -- keep contract hierarchy research doc aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/research/2026-03-15-contract-hierarchy-clarification-architecture-2026.md"

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

echo "=== Contract hierarchy research canonical paths ==="

assert_contains '.signum/contracts/<contractId>/contract.json' "research doc uses canonical contract path"
assert_contains '.signum/contracts/<contractId>/contract-engineer.json' "research doc uses canonical contract-engineer path"
assert_contains '.signum/contracts/<contractId>/contract-policy.json' "research doc uses canonical contract-policy path"
assert_contains '.signum/contracts/<contractId>/proofpack.json' "research doc uses canonical proofpack path"

assert_not_contains '├── .signum/contract.json' "old root contract path removed"
assert_not_contains '├── .signum/contract-engineer.json' "old root contract-engineer path removed"
assert_not_contains '├── .signum/contract-policy.json' "old root contract-policy path removed"
assert_not_contains '└── .signum/proofpack.json' "old root proofpack path removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
