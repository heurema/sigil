#!/usr/bin/env bash
# test-validate.sh — tests for dsl-runner.sh validate subcommand
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/../../lib/dsl-runner.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

passed=0
failed=0

assert_pass() {
  local name="$1" file="$2"
  local output
  if output=$("$RUNNER" validate "$file" 2>&1); then
    if [[ "$output" == "VALID" ]]; then
      printf '  PASS: %s\n' "$name"
      passed=$((passed + 1))
    else
      printf '  FAIL: %s — expected VALID, got: %s\n' "$name" "$output"
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
  if output=$("$RUNNER" validate "$file" 2>&1); then
    printf '  FAIL: %s — expected failure, but got exit 0: %s\n' "$name" "$output"
    failed=$((failed + 1))
  else
    if [[ -n "$expected_substr" && "$output" != *"$expected_substr"* ]]; then
      printf '  FAIL: %s — error message missing "%s": %s\n' "$name" "$expected_substr" "$output"
      failed=$((failed + 1))
    else
      printf '  PASS: %s\n' "$name"
      passed=$((passed + 1))
    fi
  fi
}

printf 'dsl-runner validate tests\n'
printf '=========================\n'

# Valid fixtures
assert_pass "valid http block" "$FIXTURES/valid-http.json"
assert_pass "valid exec block" "$FIXTURES/valid-exec.json"
assert_pass "exec file exists" "$FIXTURES/exec-file-exists.json"
assert_pass "exec with expect" "$FIXTURES/exec-with-expect.json"

# Invalid fixtures
assert_fail "invalid exec (bash)" "$FIXTURES/invalid-exec.json" "not in whitelist"

# Missing file
assert_fail "missing file" "$FIXTURES/nonexistent.json" "file not found"

# Inline: external URL rejected
tmp=$(mktemp)
printf '{"steps":[{"http":{"method":"GET","url":"evil.com/steal"}}],"timeout_ms":5000}' > "$tmp"
assert_fail "external URL rejected" "$tmp" "localhost"
rm -f "$tmp"

# Inline: too many steps
tmp=$(mktemp)
steps=""
for i in $(seq 1 21); do
  [[ -n "$steps" ]] && steps="$steps,"
  steps="$steps{\"exec\":{\"argv\":[\"test\",\"-f\",\"QUICKSTART.md\"]}}"
done
printf '{"steps":[%s],"timeout_ms":5000}' "$steps" > "$tmp"
assert_fail "too many steps (21)" "$tmp" "too many steps"
rm -f "$tmp"

# Inline: timeout too large
tmp=$(mktemp)
printf '{"steps":[{"exec":{"argv":["test","-f","QUICKSTART.md"]}}],"timeout_ms":999999}' > "$tmp"
assert_fail "timeout too large" "$tmp" "too large"
rm -f "$tmp"

# Inline: unknown capture reference
tmp=$(mktemp)
printf '{"steps":[{"expect":{"stdout_contains":"x","source":"ghost"}}],"timeout_ms":5000}' > "$tmp"
assert_fail "unknown capture reference" "$tmp" "unknown capture"
rm -f "$tmp"

# Inline: exec with python3 (not whitelisted)
tmp=$(mktemp)
printf '{"steps":[{"exec":{"argv":["python3","-c","print(1)"]}}],"timeout_ms":5000}' > "$tmp"
assert_fail "python3 not whitelisted" "$tmp" "not in whitelist"
rm -f "$tmp"

# Inline: exec with curl (not whitelisted)
tmp=$(mktemp)
printf '{"steps":[{"exec":{"argv":["curl","http://localhost"]}}],"timeout_ms":5000}' > "$tmp"
assert_fail "curl not whitelisted" "$tmp" "not in whitelist"
rm -f "$tmp"

# Inline: exec with sh (not whitelisted)
tmp=$(mktemp)
printf '{"steps":[{"exec":{"argv":["sh","-c","echo hi"]}}],"timeout_ms":5000}' > "$tmp"
assert_fail "sh not whitelisted" "$tmp" "not in whitelist"
rm -f "$tmp"

printf '\n=========================\n'
printf 'Results: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]] || exit 1
