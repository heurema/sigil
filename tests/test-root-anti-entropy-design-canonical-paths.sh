#!/usr/bin/env bash
# test-root-anti-entropy-design-canonical-paths.sh -- keep the anti-entropy/reconcile design note aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/plans/2026-04-10-root-anti-entropy-reconcile-design.md"

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

echo "=== Root anti-entropy design canonical paths ==="

assert_contains 'active contract artifact root (`.signum/contracts/<contractId>/anti_entropy_report.json`)' "design note uses canonical anti-entropy artifact path"
assert_contains 'reads canonical `contract.json`, `proofpack.json`, `modules.yaml`' "stage 1 reads canonical artifacts"
assert_contains 'emits `anti_entropy_report.json` under the active contract artifact root' "stage 1 emits canonical anti-entropy artifact"
assert_contains 'mutates canonical `contract.json` metadata after audit' "reconcile critique mentions canonical contract metadata"

assert_not_contains 'mutates `.signum/contract.json` timestamps after audit' "design note no longer teaches root contract mutation"
assert_not_contains '- `.signum/anti_entropy_report.json`' "design note no longer teaches root anti-entropy artifact path"
assert_not_contains 'emits `.signum/anti_entropy_report.json`' "design note no longer teaches root anti-entropy emit path"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
