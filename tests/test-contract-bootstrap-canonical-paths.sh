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

  local launch validate bootstrap
  launch="$(extract_section "$file" '^### Step 1\.1: Launch Contractor' '^### Step 1\.2: Validate contract')"
  validate="$(extract_section "$file" '^### Step 1\.2: Validate contract' '^### Step 1\.2\.3: Contract injection scan|^### Step 1\.2\.5: Finalize canonical contract bootstrap')"
  bootstrap="$(extract_section "$file" '^### Step 1\.2\.5: Finalize canonical contract bootstrap' '^### Step 1\.2\.7: Module lifecycle check|^### Step 1\.3: Check for open questions')"

  assert_contains "$launch" 'FILE_CONTRACT_ID=""' "$label launch"
  assert_contains "$launch" 'SIGNUM_CONTRACT_PATH' "$label launch"
  assert_contains "$launch" 'new_contract_id' "$label launch"
  assert_contains "$launch" 'CONTRACT_ID="${FILE_CONTRACT_ID:-$(new_contract_id)}"' "$label launch"
  assert_contains "$launch" 'init_contract_dir "$CONTRACT_ID"' "$label launch"
  assert_contains "$launch" 'register_contract "$CONTRACT_ID" "draft"' "$label launch"
  assert_contains "$launch" 'set_active_contract "$CONTRACT_ID"' "$label launch"
  assert_contains "$launch" 'ARTIFACT_ROOT="$(active_artifact_root)"' "$label launch"
  assert_contains "$launch" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label launch"
  assert_contains "$launch" 'link_active_artifact "contract.json"' "$label launch"
  assert_contains "$launch" 'cp "$SIGNUM_CONTRACT_PATH" "$CONTRACT_PATH"' "$label launch"
  assert_contains "$launch" 'skip contractor launch and continue to Step 1.2' "$label launch"
  assert_contains "$launch" 'CANONICAL_ARTIFACT_ROOT: <value emitted above>' "$label launch"
  assert_contains "$launch" 'write `contract.json` to the canonical artifact root above' "$label launch"
  assert_not_contains "$launch" 'write .signum/contract.json' "$label launch"

  assert_contains "$validate" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label validate"
  assert_contains "$validate" 'Pre-approved contract file is missing or invalid' "$label validate"
  assert_not_contains "$validate" '.signum/contract.json' "$label validate"

  assert_contains "$bootstrap" 'CONTRACT_ID="$(get_active_contract)"' "$label bootstrap"
  assert_contains "$bootstrap" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label bootstrap"
  assert_contains "$bootstrap" 'register_contract "$CONTRACT_ID" "draft"' "$label bootstrap"
  assert_contains "$bootstrap" 'link_active_artifact "contract.json"' "$label bootstrap"
  assert_not_contains "$bootstrap" 'sync_contract_artifacts "$CONTRACT_ID" "contract.json"' "$label bootstrap"
  assert_not_contains "$bootstrap" 'promote_root_artifact_to_active "contract.json"' "$label bootstrap"
  assert_not_contains "$bootstrap" '.signum/contract.json' "$label bootstrap"
}

check_file "$ROOT_CMD" "root"
check_file "$OVERLAY_CMD" "overlay"

echo "ok: contract bootstrap uses canonical active contract root from the start"
