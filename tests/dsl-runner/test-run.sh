#!/usr/bin/env bash
# test-run.sh — tests for dsl-runner.sh run subcommand
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/../../lib/dsl-runner.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
PROJECT_ROOT="$SCRIPT_DIR/../.."

passed=0
failed=0

assert_pass() {
  local name="$1" file="$2"
  local output
  if output=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$file" 2>&1); then
    local status
    status=$(printf '%s' "$output" | jq -r '.status' 2>/dev/null) || status=""
    if [[ "$status" == "PASS" ]]; then
      printf '  PASS: %s\n' "$name"
      passed=$((passed + 1))
    else
      printf '  FAIL: %s — expected PASS status, got: %s\n' "$name" "$output"
      failed=$((failed + 1))
    fi
  else
    printf '  FAIL: %s — exited non-zero: %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_fail() {
  local name="$1" file="$2" expected_substr="${3:-}"
  local output
  if output=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$file" 2>&1); then
    printf '  FAIL: %s — expected failure, but got exit 0: %s\n' "$name" "$output"
    failed=$((failed + 1))
  else
    local status error_msg
    # Output may be on stdout or stderr — combine
    status=$(printf '%s' "$output" | jq -r '.status' 2>/dev/null) || status=""
    error_msg=$(printf '%s' "$output" | jq -r '.error' 2>/dev/null) || error_msg=""
    if [[ -n "$expected_substr" && "$output" != *"$expected_substr"* ]]; then
      printf '  FAIL: %s — output missing "%s": %s\n' "$name" "$expected_substr" "$output"
      failed=$((failed + 1))
    else
      printf '  PASS: %s\n' "$name"
      passed=$((passed + 1))
    fi
  fi
}

printf 'dsl-runner run tests\n'
printf '====================\n'

# exec file exists (QUICKSTART.md exists in project root)
assert_pass "exec file exists" "$FIXTURES/exec-file-exists.json"

# Inline: allowed exec completes before timeout
tmp=$(mktemp)
printf '{"steps":[{"exec":{"argv":["test","-f","QUICKSTART.md"]},"expect":{"exit_code":0}}],"timeout_ms":500}' > "$tmp"
assert_pass "exec completes before timeout" "$tmp"
rm -f "$tmp"

# Inline: allowed exec times out with deterministic code 124
timeout_dir=$(mktemp -d)
timeout_fifo="$timeout_dir/hang.fifo"
mkfifo "$timeout_fifo"
tmp=$(mktemp)
jq -n --arg fifo "$timeout_fifo" '{steps:[{exec:{argv:["cat", $fifo]}, expect:{exit_code:124}}], timeout_ms:500}' > "$tmp"
assert_pass "exec timeout returns 124" "$tmp"
rm -f "$tmp"
rm -rf "$timeout_dir"

# Inline: forbidden exec is blocked before execution
tmp=$(mktemp)
printf '{"steps":[{"exec":{"argv":["sh","-c","echo should-not-run"]}}],"timeout_ms":5000}' > "$tmp"
assert_fail "exec forbidden command remains blocked" "$tmp" "not in whitelist"
rm -f "$tmp"

# exec with capture + expect (cat QUICKSTART.md contains "Signum")
assert_pass "exec with capture + expect" "$FIXTURES/exec-with-expect.json"

# exec fail (nonexistent file)
assert_fail "exec fail (nonexistent)" "$FIXTURES/exec-fail.json" "exited with code"

# JSON report structure — verify PASS output is valid JSON
output=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$FIXTURES/exec-file-exists.json" 2>&1)
status=$(printf '%s' "$output" | jq -r '.status' 2>/dev/null) || status=""
error_val=$(printf '%s' "$output" | jq -r '.error' 2>/dev/null) || error_val=""
if [[ "$status" == "PASS" && "$error_val" == "null" ]]; then
  printf '  PASS: JSON report structure (PASS)\n'
  passed=$((passed + 1))
else
  printf '  FAIL: JSON report structure — got: %s\n' "$output"
  failed=$((failed + 1))
fi

# JSON report structure — verify FAIL output
output=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$FIXTURES/exec-fail.json" 2>&1) || true
status=$(printf '%s' "$output" | jq -r '.status' 2>/dev/null) || status=""
if [[ "$status" == "FAIL" ]]; then
  printf '  PASS: JSON report structure (FAIL)\n'
  passed=$((passed + 1))
else
  printf '  FAIL: JSON report structure (FAIL) — got: %s\n' "$output"
  failed=$((failed + 1))
fi

# exec with jq (whitelisted) — parse JSON + json_path expect
assert_pass "exec jq + json_path expect" "$FIXTURES/exec-jq-jsonpath.json"

# Inline: stdout_matches (regex)
tmp=$(mktemp)
printf '{"steps":[{"exec":{"argv":["cat","QUICKSTART.md"]},"capture":"out"},{"expect":{"stdout_matches":"verified code change","source":"out"}}],"timeout_ms":5000}' > "$tmp"
assert_pass "stdout_matches regex" "$tmp"
rm -f "$tmp"

# Inline: file_exists assertion
tmp=$(mktemp)
printf '{"steps":[{"expect":{"file_exists":"QUICKSTART.md"}}],"timeout_ms":5000}' > "$tmp"
assert_pass "file_exists assertion" "$tmp"
rm -f "$tmp"

# Inline: file_exists fails for missing file
tmp=$(mktemp)
printf '{"steps":[{"expect":{"file_exists":"NONEXISTENT_FILE_12345"}}],"timeout_ms":5000}' > "$tmp"
assert_fail "file_exists fails" "$tmp" "does not exist"
rm -f "$tmp"

printf '\n====================\n'
printf 'Results: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]] || exit 1
