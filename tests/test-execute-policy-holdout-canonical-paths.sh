#!/usr/bin/env bash
set -euo pipefail

ROOT_CMD="/Users/vi/personal/heurema/signum/commands/signum.md"
OVERLAY_CMD="/Users/vi/personal/heurema/signum/platforms/claude-code/commands/signum.md"

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

  local scope_gate policy_gate scope_exists risk mechanic policy_scan holdout
  scope_gate="$(extract_section "$file" '^### Step 2\.4: Scope gate' '^If scope violation')"
  policy_gate="$(extract_section "$file" '^### Step 2\.4\.5: Policy compliance check' '^If output contains `AUTO_BLOCK`')"
  scope_exists="$(extract_section "$file" '^### Step 2\.4\.6: Scope existence gate' '^### Phase 3: AUDIT')"
  risk="$(extract_section "$file" '^Use the Bash tool to read the risk level and save it for conditional checks:' '^Save `RISK_LEVEL`')"
  mechanic="$(extract_section "$file" '^### Step 3\.1: Mechanic' '^If any check has a NEW regression')"
  policy_scan="$(extract_section "$file" '^### Step 3\.1\.3: Policy scanner' '^If `POLICY_CRITICAL` is greater than 0')"
  holdout="$(extract_section "$file" '^### Step 3\.1\.5: Holdout validation' '^### Step 3\.2\.0: Gather review context')"

  assert_contains "$scope_gate" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label scope gate"
  assert_not_contains "$scope_gate" '.signum/contract.json' "$label scope gate"

  assert_contains "$policy_gate" 'CONTRACT_POLICY_PATH="${ARTIFACT_ROOT}contract-policy.json"' "$label policy gate"
  assert_contains "$policy_gate" 'POLICY_VIOLATIONS_PATH="${ARTIFACT_ROOT}policy_violations.json"' "$label policy gate"
  assert_not_contains "$policy_gate" '.signum/contract-policy.json' "$label policy gate"
  assert_not_contains "$policy_gate" '.signum/policy_violations.json' "$label policy gate"

  assert_contains "$scope_exists" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label scope existence"
  assert_not_contains "$scope_exists" '.signum/contract.json' "$label scope existence"

  assert_contains "$risk" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label risk"
  assert_not_contains "$risk" '.signum/contract.json' "$label risk"

  assert_contains "$mechanic" 'BASELINE_PATH="${ARTIFACT_ROOT}baseline.json"' "$label mechanic"
  assert_not_contains "$mechanic" '.signum/baseline.json' "$label mechanic"

  assert_contains "$policy_scan" 'COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"' "$label policy scan"
  assert_contains "$policy_scan" 'POLICY_SCAN_PATH="${ARTIFACT_ROOT}policy_scan.json"' "$label policy scan"
  assert_not_contains "$policy_scan" '.signum/combined.patch' "$label policy scan"
  assert_not_contains "$policy_scan" '.signum/policy_scan.json' "$label policy scan"

  assert_contains "$holdout" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label holdout"
  assert_contains "$holdout" 'HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"' "$label holdout"
  assert_not_contains "$holdout" '.signum/contract.json' "$label holdout"
  assert_not_contains "$holdout" '.signum/holdout_report.json' "$label holdout"
}

check_file "$ROOT_CMD" "root"
check_file "$OVERLAY_CMD" "overlay"

echo "ok: execute policy and holdout flow use canonical artifact-root paths"
