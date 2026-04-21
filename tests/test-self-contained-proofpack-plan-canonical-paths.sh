#!/usr/bin/env bash
# test-self-contained-proofpack-plan-canonical-paths.sh -- keep self-contained proofpack plan examples aligned with canonical contract-root storage
set -euo pipefail

ROOT_DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/plans/2026-03-04-self-contained-proofpack-plan.md"
OVERLAY_DOC="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/docs/plans/2026-03-04-self-contained-proofpack-plan.md"

passed=0
failed=0

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

check_doc() {
  local file="$1"
  local label="$2"

  assert_contains "$file" 'ARTIFACT_ROOT=".signum/contracts/<contractId>"' "$label introduces canonical artifact root"
  assert_contains "$file" 'CONTRACT_PATH="$ARTIFACT_ROOT/contract.json"' "$label uses canonical contract path"
  assert_contains "$file" 'PROOFPACK_PATH="$ARTIFACT_ROOT/proofpack.json"' "$label uses canonical proofpack path"
  assert_contains "$file" 'ARTIFACT_ROOT=/tmp/signum-test/.signum/contracts/sig-test' "$label dry-run uses canonical contract dir"
  assert_contains "$file" "jq '.schemaVersion' \"\$ARTIFACT_ROOT/proofpack.json\"" "$label dry-run reads canonical proofpack path"

  assert_not_contains "$file" "DECISION=\$(jq -r '.decision' .signum/audit_summary.json)" "$label removes root audit summary read"
  assert_not_contains "$file" '# Reviews (dynamic — enumerate .signum/reviews/)' "$label removes root reviews dir comment"
  assert_not_contains "$file" "}' > .signum/proofpack.json" "$label removes root proofpack write"
  assert_not_contains "$file" "echo '{\"goal\":\"test\",\"riskLevel\":\"low\"}' > /tmp/signum-test/.signum/contract.json" "$label removes root dry-run contract path"
}

echo "=== Self-contained proofpack plan canonical paths ==="
check_doc "$ROOT_DOC" "root plan"
check_doc "$OVERLAY_DOC" "overlay plan"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
