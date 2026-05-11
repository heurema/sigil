#!/usr/bin/env bash
# test-reference-proofpack-fields.sh -- keep docs/reference.md aligned with current proofpack schema/validator fields
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/docs/reference.md"

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

echo "=== Reference proofpack fields ==="

assert_contains 'lib/schemas/proofpack.schema.json' "reference names proofpack schema source"
assert_contains 'scripts/validate_proofpack.py' "reference names proofpack validator source"
assert_contains '.signum/contracts/<contractId>/proofpack.json' "reference documents current proofpack emission target"
assert_not_contains 'proofpack.json fields (v4.6)' "old v4.6 proofpack heading removed"

for field in \
  'schemaVersion' \
  'contractId' \
  'decision' \
  'releaseVerdict' \
  'riskLevel' \
  'timing' \
  'reviewCoverage' \
  'contractSource' \
  'ciContext' \
  'baselineComparison' \
  'approval' \
  'checks.policy_scan' \
  'removalEvidence'
do
  assert_contains "\`$field\`" "reference documents $field"
done

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
