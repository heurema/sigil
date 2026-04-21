#!/usr/bin/env bash
# test-reviewer-prompt-canonical-paths.sh -- keep reviewer prompts aligned with canonical contract-root storage
set -euo pipefail

ROOT_PROMPT="$(cd "$(dirname "$0")/.." && pwd)/agents/reviewer-claude.md"
OVERLAY_PROMPT="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/agents/reviewer-claude.md"

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
  assert_contains "$file" '.signum/contracts/<contractId>/combined.patch' "$label uses canonical diff path"
  assert_contains "$file" '.signum/contracts/<contractId>/mechanic_report.json' "$label uses canonical mechanic path"
  assert_contains "$file" '.signum/contracts/<contractId>/reviews/claude.json' "$label uses canonical review output path"

  assert_not_contains "$file" '`{contract_json}` = contents of `.signum/contract.json`' "$label removes root contract input"
  assert_not_contains "$file" '`{diff}` = contents of `.signum/combined.patch`' "$label removes root diff input"
  assert_not_contains "$file" 'Write your review result to `.signum/reviews/claude.json`' "$label removes root review output"
}

echo "=== Reviewer prompt canonical paths ==="
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
