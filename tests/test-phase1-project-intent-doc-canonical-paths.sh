#!/usr/bin/env bash
# test-phase1-project-intent-doc-canonical-paths.sh -- keep project-intent planning docs aligned with canonical contract-root storage
set -euo pipefail

PLAN_DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/plans/2026-03-15-phase1-project-intent-layer-plan.md"
DESIGN_DOC="$(cd "$(dirname "$0")/.." && pwd)/docs/plans/2026-03-15-phase1-project-intent-layer-design.md"

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

echo "=== Phase1 project-intent docs canonical paths ==="

assert_contains "$PLAN_DOC" 'CONTRACT_PATH="$ARTIFACT_ROOT/contract.json"' "plan doc introduces canonical contract path"
assert_contains "$PLAN_DOC" 'INTENT_CHECK_PATH="$ARTIFACT_ROOT/intent_check.json"' "plan doc introduces canonical intent-check path"
assert_contains "$PLAN_DOC" 'Write result to `$INTENT_CHECK_PATH`.' "plan doc writes canonical intent-check artifact"
assert_contains "$DESIGN_DOC" 'Assume `CONTRACT_PATH="$ARTIFACT_ROOT/contract.json"` and `INTENT_CHECK_PATH="$ARTIFACT_ROOT/intent_check.json"`' "design doc introduces canonical artifact paths"
assert_contains "$DESIGN_DOC" 'Add `intent_check.json` under the active contract artifact root to:' "design doc cleanup uses canonical artifact root"

assert_not_contains "$PLAN_DOC" '.signum/contract.json' "plan doc no longer teaches root contract path"
assert_not_contains "$PLAN_DOC" '.signum/intent_check.json' "plan doc no longer teaches root intent-check path"
assert_not_contains "$DESIGN_DOC" '.signum/contract.json' "design doc no longer teaches root contract path"
assert_not_contains "$DESIGN_DOC" '.signum/intent_check.json' "design doc no longer teaches root intent-check path"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
