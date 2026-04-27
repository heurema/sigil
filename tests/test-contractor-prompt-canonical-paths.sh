#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_PROMPT="$ROOT_DIR/agents/contractor.md"
OVERLAY_PROMPT="$ROOT_DIR/platforms/claude-code/agents/contractor.md"

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: expected ${label} to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    echo "FAIL: expected ${label} to not contain: $needle" >&2
    exit 1
  fi
}

check_file() {
  local file="$1"
  local label="$2"

  assert_contains "$file" 'Write `contract.json` under the canonical active contract root provided by the orchestrator' "$label"
  assert_contains "$file" 'Use the canonical path under `.signum/contracts/<contractId>/` as the source of truth' "$label"
  assert_contains "$file" 'Do not write root `.signum/contract.json`; that path is only a legacy import signal' "$label"
  assert_contains "$file" 'you MUST call Write for canonical `contract.json` by turn 10' "$label"
  assert_not_contains "$file" 'Write `.signum/contract.json` following the schema' "$label"
  assert_not_contains "$file" 'you MUST call Write for `.signum/contract.json` by turn 10' "$label"
}

check_file "$ROOT_PROMPT" "root contractor prompt"
check_file "$OVERLAY_PROMPT" "overlay contractor prompt"

echo "ok: contractor prompts use canonical contract root language"
