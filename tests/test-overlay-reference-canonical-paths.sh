#!/usr/bin/env bash
# test-overlay-reference-canonical-paths.sh -- keep Claude overlay reference doc aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/docs/reference.md"

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

echo "=== Overlay reference canonical paths ==="

assert_contains '.signum/contracts/<contractId>/' "overlay reference mentions canonical contract artifact root"
assert_contains 'Outputs: `baseline.json`, `combined.patch`, `execute_log.json` under the active contract artifact root.' "overlay execute outputs use canonical wording"
assert_contains 'Iteration artifacts are stored under the active contract artifact root' "overlay iterative audit uses canonical storage wording"
assert_contains 'contracts/index.json.activeContractId' "overlay resume wording uses registry-first state"
assert_contains 'Check `reviews/` under the active contract artifact root for provider status.' "overlay provider status uses canonical reviews dir"

assert_not_contains 'Signum detects .signum/contract.json' "overlay no longer teaches root resume path"
assert_not_contains 'produces `.signum/contract.json`' "overlay no longer teaches root contract path"
assert_not_contains 'saves to `.signum/baseline.json`' "overlay no longer teaches root baseline path"
assert_not_contains 'Outputs: `.signum/baseline.json`, `.signum/combined.patch`, `.signum/execute_log.json`.' "overlay no longer lists root execute outputs"
assert_not_contains 'Assembles `.signum/proofpack.json`' "overlay no longer teaches root proofpack path"
assert_not_contains 'Check `.signum/reviews/` for provider status.' "overlay no longer teaches root reviews dir"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
