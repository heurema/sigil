#!/usr/bin/env bash
set -euo pipefail

ROOT_PROMPT="/Users/vi/personal/heurema/signum/agents/contractor.md"
OVERLAY_PROMPT="/Users/vi/personal/heurema/signum/platforms/claude-code/agents/contractor.md"

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
  assert_contains "$file" 'canonical path under `.signum/contracts/<contractId>/` is the source of truth' "$label"
  assert_contains "$file" '`.signum/contract.json` is only a compatibility view pointing at that canonical file' "$label"
  assert_contains "$file" 'you MUST call Write for canonical `contract.json` by turn 10' "$label"
  assert_not_contains "$file" 'Write `.signum/contract.json` following the schema' "$label"
  assert_not_contains "$file" 'you MUST call Write for `.signum/contract.json` by turn 10' "$label"
}

check_file "$ROOT_PROMPT" "root contractor prompt"
check_file "$OVERLAY_PROMPT" "overlay contractor prompt"

echo "ok: contractor prompts use canonical contract root language"
