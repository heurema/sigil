#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_CMD="$ROOT_DIR/commands/signum.md"
OVERLAY_CMD="$ROOT_DIR/platforms/claude-code/commands/signum.md"

extract_receipt_chain_section() {
  local file="$1"
  awk '
    /\*\*Launch repair engineer \(parallel lanes\):\*\*/ { capture=1 }
    capture { print }
    /\*\*Clean up worktrees after boundary verification:\*\*/ && capture { exit }
  ' "$file"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to not contain: $needle" >&2
    exit 1
  fi
}

ROOT_SECTION="$(extract_receipt_chain_section "$ROOT_CMD")"
OVERLAY_SECTION="$(extract_receipt_chain_section "$OVERLAY_CMD")"

for label in ROOT_SECTION OVERLAY_SECTION; do
  section="${!label}"
  assert_contains "$section" 'ITERATIONS_DIR="${ARTIFACT_ROOT}iterations"' "$label"
  assert_contains "$section" 'EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"' "$label"
  assert_contains "$section" 'LANE_SELECTED_DIR="${ITERATIONS_DIR}/${ITER_PAD}/lanes"' "$label"
  assert_contains "$section" 'SNAPSHOTS_DIR="${ARTIFACT_ROOT}snapshots"' "$label"
  assert_contains "$section" 'RECEIPTS_DIR="${ARTIFACT_ROOT}receipts"' "$label"
  assert_contains "$section" 'RUNS_DIR="${ARTIFACT_ROOT}runs"' "$label"
  assert_contains "$section" 'WINNER_ARTIFACT_ROOT="${WINNER_SIGNUM_DIR}/contracts/${WINNER_ACTIVE_CONTRACT_ID}/"' "$label"
  assert_not_contains "$section" '.signum/execution_context.json' "$label"
  assert_not_contains "$section" '.signum/iterations/$ITER_PAD/lanes' "$label"
  assert_not_contains "$section" '.signum/snapshots/execute-attempt-' "$label"
  assert_not_contains "$section" '.signum/receipts' "$label"
  assert_not_contains "$section" '.signum/runs/' "$label"
  assert_not_contains "$section" '$WINNER_DIR/.signum/contract-engineer.json' "$label"
  assert_not_contains "$section" '$WINNER_DIR/.signum/contract.json' "$label"
done

echo "ok: repair receipt-chain flow uses canonical artifact-root paths"
