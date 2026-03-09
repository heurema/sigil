#!/usr/bin/env bash
# test-e2e.sh — end-to-end test: contract → DSL validation → execution → report
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/../../lib/dsl-runner.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
PROJECT_ROOT="$SCRIPT_DIR/../.."
CONTRACT="$FIXTURES/sample-contract.json"

passed=0
failed=0

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

printf 'dsl-runner end-to-end tests\n'
printf '===========================\n'

# Ensure dsl-runner.sh is executable (needed for AC02 holdout test)
chmod +x "$RUNNER"

# --- 1. Extract visible AC verify block, validate it ---
visible_verify=$(mktemp)
jq '.acceptanceCriteria[] | select(.visibility == "visible") | .verify' "$CONTRACT" > "$visible_verify"

output=$("$RUNNER" validate "$visible_verify" 2>&1) || true
assert_eq "1: validate visible AC verify block" "$output" "VALID"

# --- 2. Run visible AC (file exists) → should PASS ---
output=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$visible_verify" 2>&1) || true
status=$(printf '%s' "$output" | jq -r '.status' 2>/dev/null) || status=""
assert_eq "2: run visible AC (file exists)" "$status" "PASS"

rm -f "$visible_verify"

# --- 3. Extract holdout AC verify block, validate it ---
holdout_verify=$(mktemp)
jq '.acceptanceCriteria[] | select(.visibility == "holdout") | .verify' "$CONTRACT" > "$holdout_verify"

output=$("$RUNNER" validate "$holdout_verify" 2>&1) || true
assert_eq "3: validate holdout AC verify block" "$output" "VALID"

# --- 4. Run holdout AC (file is executable) → should PASS ---
output=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$holdout_verify" 2>&1) || true
status=$(printf '%s' "$output" | jq -r '.status' 2>/dev/null) || status=""
assert_eq "4: run holdout AC (file is executable)" "$status" "PASS"

rm -f "$holdout_verify"

# --- 5. Filter only visible ACs with jq → count should be 1 ---
visible_count=$(jq '[.acceptanceCriteria[] | select(.visibility == "visible")] | length' "$CONTRACT")
assert_eq "5: visible AC count" "$visible_count" "1"

# --- 6. Count holdout ACs with jq → count should be 1 ---
holdout_count=$(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' "$CONTRACT")
assert_eq "6: holdout AC count" "$holdout_count" "1"

# --- 7. Full holdout report: extract → run → verify JSON output ---
holdout_verify=$(mktemp)
jq '.acceptanceCriteria[] | select(.visibility == "holdout") | .verify' "$CONTRACT" > "$holdout_verify"

report=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$holdout_verify" 2>&1) || true
report_status=$(printf '%s' "$report" | jq -r '.status' 2>/dev/null) || report_status=""
report_error=$(printf '%s' "$report" | jq -r '.error' 2>/dev/null) || report_error=""

# Both status=PASS and error=null must be present in the JSON report
if [[ "$report_status" == "PASS" && "$report_error" == "null" ]]; then
  printf '  PASS: 7: full holdout report (status=PASS, error=null)\n'
  passed=$((passed + 1))
else
  printf '  FAIL: 7: full holdout report — status="%s", error="%s"\n' "$report_status" "$report_error"
  failed=$((failed + 1))
fi

rm -f "$holdout_verify"

printf '\n===========================\n'
printf 'Results: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]] || exit 1
