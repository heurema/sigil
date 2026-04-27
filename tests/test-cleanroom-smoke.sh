#!/usr/bin/env bash
# test-cleanroom-smoke.sh -- behavioral guard for local clean-room release/package smoke
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SMOKE_SCRIPT="$REPO_ROOT/scripts/run-cleanroom-smoke.sh"

passed=0
failed=0

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "missing '$needle'"
  fi
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

assert_file "clean-room smoke script exists" "$SMOKE_SCRIPT"

set +e
OUTPUT="$(env SIGNUM_CLEANROOM_FULL=0 SIGNUM_KEEP_CLEANROOM=0 bash "$SMOKE_SCRIPT" 2>&1)"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  pass "clean-room smoke exits 0"
else
  fail "clean-room smoke exits 0" "exit $RC"
  printf '%s\n' "$OUTPUT"
fi

assert_contains "prints source root" "$OUTPUT" "Source root:"
assert_contains "prints clean-room path" "$OUTPUT" "Clean-room path:"
assert_contains "uses git source inventory" "$OUTPUT" "git ls-files --cached --others --exclude-standard"
assert_contains "includes untracked non-ignored files" "$OUTPUT" "tracked files + untracked non-ignored files"
assert_contains "excludes git directory" "$OUTPUT" "No .git directory copied"
assert_contains "documents no secrets" "$OUTPUT" "Secrets: not required"
assert_contains "documents local no-network release smoke" "$OUTPUT" "Network: not used by release smoke"
assert_contains "documents no external AI CLIs" "$OUTPUT" "External AI CLIs: not invoked"
assert_contains "uses targeted non-recursive mode" "$OUTPUT" "Full deterministic suite: skipped"
assert_contains "runs renderer check" "$OUTPUT" "== Command renderer =="
assert_contains "renderer passes" "$OUTPUT" "root --check matches checked-in command"
assert_contains "runs fragment parity check" "$OUTPUT" "== Fragment parity =="
assert_contains "fragment parity passes" "$OUTPUT" "fragment parity fixture exists"
assert_contains "runs stabilization summary check" "$OUTPUT" "== Stabilization summary =="
assert_contains "stabilization summary passes" "$OUTPUT" "summary doc exists"
assert_contains "runs local release smoke" "$OUTPUT" "== Release smoke (local dry run) =="
assert_contains "release smoke passes" "$OUTPUT" "Release smoke passed."
assert_contains "overall smoke passes" "$OUTPUT" "Clean-room smoke passed."

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
