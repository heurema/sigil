#!/usr/bin/env bash
# test-quickstart-canonical-paths.sh -- ensure root and overlay quickstarts teach canonical contract-root artifact paths
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DOC="$SCRIPT_DIR/../QUICKSTART.md"
OVERLAY_DOC="$SCRIPT_DIR/../platforms/claude-code/QUICKSTART.md"

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

echo "=== Quickstart canonical paths ==="

assert_contains "$ROOT_DOC" '.signum/contracts/<contractId>/' "root quickstart mentions canonical contract root"
assert_contains "$ROOT_DOC" 'jq '\''.decision, .confidence.overall'\'' "$ARTIFACT_ROOT/proofpack.json"' "root quickstart reads proofpack from artifact root"
assert_contains "$ROOT_DOC" 'Check `audit_summary.json` under the active contract artifact root.' "root quickstart points findings to canonical audit summary"
assert_contains "$OVERLAY_DOC" '.signum/contracts/<contractId>/' "overlay quickstart mentions canonical contract root"
assert_contains "$OVERLAY_DOC" 'jq '\''.decision, .confidence.overall'\'' "$ARTIFACT_ROOT/proofpack.json"' "overlay quickstart reads proofpack from artifact root"
assert_contains "$OVERLAY_DOC" 'Check `audit_summary.json` under the active contract artifact root.' "overlay quickstart points findings to canonical audit summary"

assert_not_contains "$ROOT_DOC" "jq '.decision, .confidence.overall' .signum/proofpack.json" "root quickstart no longer teaches root proofpack path"
assert_not_contains "$ROOT_DOC" 'Check `.signum/audit_summary.json`.' "root quickstart no longer teaches root audit summary path"
assert_not_contains "$ROOT_DOC" 'Check `.signum/proofpack.json` for the result' "root checklist no longer teaches root proofpack path"
assert_not_contains "$OVERLAY_DOC" "jq '.decision, .confidence.overall' .signum/proofpack.json" "overlay quickstart no longer teaches root proofpack path"
assert_not_contains "$OVERLAY_DOC" 'Check `.signum/audit_summary.json`.' "overlay quickstart no longer teaches root audit summary path"
assert_not_contains "$OVERLAY_DOC" 'Check `.signum/proofpack.json` for the result' "overlay checklist no longer teaches root proofpack path"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
