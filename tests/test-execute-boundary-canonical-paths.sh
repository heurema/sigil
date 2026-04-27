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

  local baseline snapshot execute boundary
  baseline="$(extract_section "$file" '^### Step 2\.0: Capture baseline' '^If `repo-contract\.json` exists')"
  snapshot="$(extract_section "$file" '^### Step 2\.0\.5: Capture pre-execute snapshot' '^### Step 2\.1: Launch Engineer')"
  execute="$(extract_section "$file" '^### Step 2\.1: Launch Engineer' '^### Step 2\.4: Scope gate')"
  boundary="$(extract_section "$file" '^### Step 2\.5: Boundary verification' '^If transition verifier exits non-zero')"

  assert_contains "$baseline" 'EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"' "$label baseline"
  assert_contains "$baseline" 'BASELINE_PATH="${ARTIFACT_ROOT}baseline.json"' "$label baseline"
  assert_contains "$baseline" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label baseline"
  assert_not_contains "$baseline" '> .signum/execution_context.json' "$label baseline"
  assert_not_contains "$baseline" '> .signum/baseline.json' "$label baseline"

  assert_contains "$snapshot" 'SNAPSHOT_PATH="${ARTIFACT_ROOT}snapshots/execute-attempt-01.json"' "$label snapshot"
  assert_contains "$snapshot" '--signum-dir "$ARTIFACT_ROOT"' "$label snapshot"
  assert_not_contains "$snapshot" '.signum/snapshots/execute-attempt-01.json' "$label snapshot"

  assert_contains "$execute" 'The canonical artifact root for this execute phase is `.signum/contracts/<activeContractId>/`.' "$label execute"
  assert_contains "$execute" 'EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"' "$label execute"
  assert_contains "$execute" 'COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"' "$label execute"
  assert_not_contains "$execute" 'Read .signum/contract-engineer.json' "$label execute"
  assert_not_contains "$execute" '.signum/execute_log.json' "$label execute"
  assert_not_contains "$execute" '.signum/combined.patch' "$label execute"

  assert_contains "$boundary" '--signum-dir "$ARTIFACT_ROOT"' "$label boundary"
  assert_contains "$boundary" '--execution-context "$EXECUTION_CONTEXT_PATH"' "$label boundary"
  assert_contains "$boundary" '--snapshot "$SNAPSHOT_PATH"' "$label boundary"
  assert_not_contains "$boundary" '.signum/snapshots/execute-attempt-01.json' "$label boundary"
}

check_file "$ROOT_CMD" "root"
check_file "$OVERLAY_CMD" "overlay"

echo "ok: early execute and boundary flow use canonical artifact-root paths"
