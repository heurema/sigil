#!/usr/bin/env bash
# test-signum-gate-canonical-paths.sh -- regression checks for canonical proofpack paths in gate templates
set -euo pipefail

ROOT_TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/lib/templates/signum-gate.yml"
OVERLAY_TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/lib/templates/signum-gate.yml"

passed=0
failed=0

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

check_template() {
  local file="$1"
  local label="$2"

  printf '=== %s ===\n' "$label"
  assert_contains "$file" 'source lib/signum-ci.sh' "$label sources CI helper"
  assert_contains "$file" 'ARTIFACT_ROOT=$(resolve_ci_artifact_root "$SIGNUM_PROJECT_ROOT" "$INPUT_CONTRACT_ID" 2>/dev/null || true)' "$label resolves canonical artifact root"
  assert_contains "$file" 'PROOFPACK_PATH=$(resolve_ci_proofpack_path "$SIGNUM_PROJECT_ROOT" "$INPUT_CONTRACT_ID" 2>/dev/null || true)' "$label resolves canonical proofpack path"
  assert_contains "$file" 'echo "proofpack_path=$PROOFPACK_PATH" >> "$GITHUB_OUTPUT"' "$label exports proofpack path"
  assert_contains "$file" 'echo "proofpack_upload_path=$PROOFPACK_UPLOAD_PATH" >> "$GITHUB_OUTPUT"' "$label exports proofpack upload path"
  assert_contains "$file" 'echo "artifact_upload_path=$ARTIFACT_UPLOAD_PATH" >> "$GITHUB_OUTPUT"' "$label exports artifact upload path"
  assert_contains "$file" "path: \${{ steps.signum.outputs.proofpack_upload_path }}" "$label uploads proofpack via resolved upload path"
  assert_contains "$file" "path: \${{ steps.signum.outputs.artifact_upload_path }}" "$label uploads audit directory via resolved upload path"
  assert_not_contains "$file" 'if [ -f .signum/proofpack.json ]; then' "$label removes direct root proofpack probe"
  assert_not_contains "$file" "DECISION=\$(jq -r '.decision' .signum/proofpack.json)" "$label removes direct root decision read"
  assert_not_contains "$file" "path: \${{ steps.signum.outputs.proofpack_path || '.signum/proofpack.json' }}" "$label removes raw root proofpack fallback"
  assert_not_contains "$file" "path: \${{ steps.signum.outputs.artifact_root || '.signum/' }}" "$label removes raw root artifact-root fallback"
  printf '\n'
}

check_template "$ROOT_TEMPLATE" "root template"
check_template "$OVERLAY_TEMPLATE" "overlay template"

echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
