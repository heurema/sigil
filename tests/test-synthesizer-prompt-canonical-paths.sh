#!/usr/bin/env bash
# test-synthesizer-prompt-canonical-paths.sh -- keep synthesizer prompts aligned with canonical contract-root storage
set -euo pipefail

ROOT_PROMPT="$(cd "$(dirname "$0")/.." && pwd)/agents/synthesizer.md"
OVERLAY_PROMPT="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/agents/synthesizer.md"

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
  assert_contains "$file" '.signum/contracts/<contractId>/contract.json' "$label uses canonical contract path"
  assert_contains "$file" '.signum/contracts/<contractId>/mechanic_report.json' "$label uses canonical mechanic path"
  assert_contains "$file" '.signum/contracts/<contractId>/receipts/execute.json' "$label uses canonical receipt path"
  assert_contains "$file" '.signum/contracts/<contractId>/audit_summary.json' "$label uses canonical audit summary output"

  assert_not_contains "$file" '- `.signum/contract.json` -- contract' "$label removes root contract input"
  assert_not_contains "$file" 'Read from `.signum/execute_log.json`' "$label removes root execute log reference"
  assert_not_contains "$file" 'Write `.signum/audit_summary.json`:' "$label removes root audit summary output"
}

echo "=== Synthesizer prompt canonical paths ==="
check_prompt "$ROOT_PROMPT" "root prompt"
check_prompt "$OVERLAY_PROMPT" "overlay prompt"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
