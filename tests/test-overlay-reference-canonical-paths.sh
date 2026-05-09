#!/usr/bin/env bash
# test-overlay-reference-canonical-paths.sh -- keep Claude overlay reference doc aligned with canonical contract-root storage
set -euo pipefail

DOC="$(CDPATH= cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/docs/reference.md"

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
assert_contains 'Outputs under the active contract artifact root:' "overlay execute outputs use canonical artifact-root wording"
assert_contains '`baseline.json`' "overlay execute outputs include baseline"
assert_contains '`combined.patch`' "overlay execute outputs include combined patch"
assert_contains '`execute_log.json`' "overlay execute outputs include execute log"
assert_contains '`implementation_context.json`' "overlay Codebase Awareness outputs include implementation context"
assert_contains '`reuse_candidates.json`' "overlay Codebase Awareness outputs include reuse candidates"
assert_contains '`reuse_decision.json`' "overlay Codebase Awareness outputs include reuse decision"
assert_contains 'Iteration artifacts are stored under the active contract artifact root' "overlay iterative audit uses canonical storage wording"
assert_contains 'contracts/index.json.activeContractId' "overlay resume wording uses registry-first state"
assert_contains 'Check `reviews/` under the canonical artifact root for provider status.' "overlay provider status uses canonical reviews dir"

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
