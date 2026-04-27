#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_CMD="$ROOT_DIR/commands/signum.md"
OVERLAY_CMD="$ROOT_DIR/platforms/claude-code/commands/signum.md"

extract_section() {
  local file="$1"
  local start="$2"
  local end="$3"
  awk -v start="$start" -v end="$end" '
    $0 ~ start { capture=1 }
    capture { print }
    $0 ~ end && capture { exit }
  ' "$file"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to not contain: $needle" >&2
    exit 1
  fi
}

check_file() {
  local file="$1"
  local label="$2"

  local open_questions spec_quality intent spec_validation clover summary hash engineer policy
  open_questions="$(extract_section "$file" '^### Step 1\.3: Check for open questions' '^### Step 1\.3\.5: Spec quality check')"
  spec_quality="$(extract_section "$file" '^### Step 1\.3\.5: Spec quality check' '^### Step 1\.3\.6: Intent alignment check')"
  intent="$(extract_section "$file" '^### Step 1\.3\.6: Intent alignment check' '^### Step 1\.3\.7: Multi-model spec validation')"
  spec_validation="$(extract_section "$file" '^### Step 1\.3\.7: Multi-model spec validation' '^### Step 1\.3\.8: Clover reconstruction test')"
  clover="$(extract_section "$file" '^### Step 1\.3\.8: Clover reconstruction test' '^### Step 1\.4: Display contract summary')"
  summary="$(extract_section "$file" '^### Step 1\.4: Display contract summary' '^### Step 1\.4\.5: Record approval timestamp')"
  hash="$(extract_section "$file" '^### Step 1\.4\.5: Record approval timestamp' '^### Step 1\.5: Prepare sanitized engineer contract')"
  engineer="$(extract_section "$file" '^### Step 1\.5: Prepare sanitized engineer contract' '^### Step 1\.6: Generate execution policy')"
  policy="$(extract_section "$file" '^### Step 1\.6: Generate execution policy' '^---$')"

  assert_contains "$open_questions" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label open questions"
  assert_not_contains "$open_questions" '.signum/contract.json' "$label open questions"

  assert_contains "$spec_quality" 'SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"' "$label spec quality"
  assert_contains "$spec_quality" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label spec quality"
  assert_not_contains "$spec_quality" '.signum/contract.json' "$label spec quality"
  assert_not_contains "$spec_quality" '.signum/spec_quality.json' "$label spec quality"

  assert_contains "$intent" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label intent"
  assert_contains "$intent" 'intent_check.json` under the canonical artifact root' "$label intent"
  assert_not_contains "$intent" '.signum/contract.json' "$label intent"
  assert_not_contains "$intent" '.signum/intent_check.json' "$label intent"

  assert_contains "$spec_validation" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label spec validation"
  assert_contains "$spec_validation" 'SPEC_VALIDATION_PATH="${ARTIFACT_ROOT}spec_validation.json"' "$label spec validation"
  assert_not_contains "$spec_validation" '.signum/contract.json' "$label spec validation"
  assert_not_contains "$spec_validation" '.signum/spec_validation.json' "$label spec validation"

  assert_contains "$clover" 'CLOVER_REPORT_PATH="${ARTIFACT_ROOT}clover_report.json"' "$label clover"
  assert_contains "$clover" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label clover"
  assert_not_contains "$clover" '.signum/contract.json' "$label clover"
  assert_not_contains "$clover" '.signum/clover_report.json' "$label clover"

  assert_contains "$summary" 'SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"' "$label summary"
  assert_contains "$summary" 'CLOVER_REPORT_PATH="${ARTIFACT_ROOT}clover_report.json"' "$label summary"
  assert_contains "$summary" 'INTENT_CHECK_PATH="${ARTIFACT_ROOT}intent_check.json"' "$label summary"
  assert_contains "$summary" 'APPROVAL_PATH="${ARTIFACT_ROOT}approval.json"' "$label summary"
  assert_not_contains "$summary" '.signum/contract.json' "$label summary"
  assert_not_contains "$summary" '.signum/spec_quality.json' "$label summary"
  assert_not_contains "$summary" '.signum/clover_report.json' "$label summary"
  assert_not_contains "$summary" '.signum/intent_check.json' "$label summary"
  assert_not_contains "$summary" '.signum/approval.json' "$label summary"

  assert_contains "$hash" 'CONTRACT_HASH_PATH="${ARTIFACT_ROOT}contract-hash.txt"' "$label hash"
  assert_contains "$hash" 'contract_file: $CONTRACT_PATH' "$label hash"
  assert_not_contains "$hash" '.signum/contract.json' "$label hash"
  assert_not_contains "$hash" '.signum/contract-hash.txt' "$label hash"

  assert_contains "$engineer" 'CONTRACT_ENGINEER_PATH="${ARTIFACT_ROOT}contract-engineer.json"' "$label engineer"
  assert_contains "$engineer" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label engineer"
  assert_not_contains "$engineer" '.signum/contract.json' "$label engineer"
  assert_not_contains "$engineer" '.signum/contract-engineer.json' "$label engineer"

  assert_contains "$policy" 'CONTRACT_POLICY_PATH="${ARTIFACT_ROOT}contract-policy.json"' "$label policy"
  assert_contains "$policy" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label policy"
  assert_not_contains "$policy" '.signum/contract.json' "$label policy"
  assert_not_contains "$policy" '.signum/contract-policy.json' "$label policy"
}

check_file "$ROOT_CMD" "root"
check_file "$OVERLAY_CMD" "overlay"

echo "ok: contract phase post-promotion flow uses canonical artifact-root paths"
