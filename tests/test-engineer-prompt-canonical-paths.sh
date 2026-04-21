#!/usr/bin/env bash
# test-engineer-prompt-canonical-paths.sh -- keep engineer prompts aligned with canonical contract-root storage
set -euo pipefail

ROOT_PROMPT="$(cd "$(dirname "$0")/.." && pwd)/agents/engineer.md"
OVERLAY_PROMPT="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/agents/engineer.md"

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

check_prompt() {
  local file="$1"
  local label="$2"

  assert_contains "$file" '.signum/contracts/<contractId>/' "$label mentions canonical artifact root"
  assert_contains "$file" '.signum/contracts/<contractId>/contract-engineer.json' "$label uses canonical contract-engineer path"
  assert_contains "$file" '.signum/contracts/<contractId>/baseline.json' "$label uses canonical baseline path"
  assert_contains "$file" '.signum/contracts/<contractId>/execute_log.json' "$label uses canonical execute log path"
  assert_contains "$file" '.signum/contracts/<contractId>/combined.patch' "$label uses canonical combined patch path"

  assert_not_contains "$file" '- `.signum/contract-engineer.json`' "$label removes root contract-engineer input"
  assert_not_contains "$file" 'Read `.signum/baseline.json`' "$label removes root baseline read"
  assert_not_contains "$file" 'Generate `.signum/combined.patch` via `git diff`' "$label removes root combined patch output"
  assert_not_contains "$file" 'Write `.signum/execute_log.json`' "$label removes root execute log output"
}

echo "=== Engineer prompt canonical paths ==="
check_prompt "$ROOT_PROMPT" "root prompt"
check_prompt "$OVERLAY_PROMPT" "overlay prompt"

assert_contains "$OVERLAY_PROMPT" '.signum/contracts/<contractId>/receipts/**' "overlay prompt uses canonical forbidden receipt path"
assert_not_contains "$OVERLAY_PROMPT" '.signum/receipts/**' "overlay prompt removes root forbidden receipt path"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
