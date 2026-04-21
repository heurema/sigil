#!/usr/bin/env bash
# test-architecture-canonical-artifact-root.sh -- keep ARCHITECTURE.md aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/ARCHITECTURE.md"

passed=0
failed=0

assert_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing \"%s\"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  FAIL: %s -- unexpectedly found \"%s\"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

echo "=== Architecture canonical artifact root ==="

assert_contains '.signum/contracts/<contractId>/proofpack.json' "architecture doc uses canonical proofpack path"
assert_contains 'creates canonical `contract.json` under the active contract artifact root' "main flow uses canonical contract wording"
assert_contains 'assembles `proofpack.json` under the active contract artifact root' "pack flow uses canonical proofpack wording"

assert_not_contains 'The output artifact is `.signum/proofpack.json`' "old root proofpack summary removed"
assert_not_contains 'Contractor creates `.signum/contract.json`' "old root contract flow removed"
assert_not_contains 'PACK assembles `.signum/proofpack.json`' "old root pack flow removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
