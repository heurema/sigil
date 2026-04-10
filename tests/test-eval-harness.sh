#!/usr/bin/env bash
# test-eval-harness.sh -- tests for evals/run.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/../evals/run.py"

passed=0
failed=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_pass() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — exited non-zero: %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_equals() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

echo "=== Harness existence ==="
assert_pass "runner file exists" test -f "$RUNNER"
assert_pass "runner is executable after chmod" chmod +x "$RUNNER"
assert_pass "checks file exists" test -f "$SCRIPT_DIR/../evals/checks.py"
assert_pass "fixtures directory exists" test -d "$SCRIPT_DIR/../evals/fixtures"
assert_pass "snapshots directory exists" test -d "$SCRIPT_DIR/../evals/snapshots"

echo ""
echo "=== Success path ==="
SUCCESS_OUTPUT="$(python3 "$RUNNER")"
assert_equals "success status ok" "$(echo "$SUCCESS_OUTPUT" | jq -r '.status')" "ok"
assert_equals "fixture count is 6" "$(echo "$SUCCESS_OUTPUT" | jq -r '.fixtureCount')" "6"
assert_equals "no harness failures" "$(echo "$SUCCESS_OUTPUT" | jq -r '.failed')" "0"
assert_equals "malformed case stays pinned" "$(echo "$SUCCESS_OUTPUT" | jq -r '.results[] | select(.caseId=="06-malformed-artifact-shape") | .invariantStatus')" "violated"

echo ""
echo "=== Broken snapshot path ==="
cp -R "$SCRIPT_DIR/../evals" "$WORK/evals"
python3 - "$WORK/evals/snapshots/01-low-risk-happy-path.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data['observedVerdict'] = 'HUMAN_REVIEW'
path.write_text(json.dumps(data, indent=2) + '\n')
PY

set +e
BROKEN_OUTPUT="$(python3 "$RUNNER" --fixtures-dir "$WORK/evals/fixtures" --snapshots-dir "$WORK/evals/snapshots" 2>&1)"
BROKEN_RC=$?
set -e
assert_equals "broken snapshot exits non-zero" "$BROKEN_RC" "1"
assert_equals "broken snapshot status error" "$(echo "$BROKEN_OUTPUT" | jq -r '.status')" "error"
assert_equals "broken snapshot mismatch count" "$(echo "$BROKEN_OUTPUT" | jq '[.results[] | select(.snapshotStatus=="mismatch")] | length')" "1"
assert_equals "broken snapshot case id" "$(echo "$BROKEN_OUTPUT" | jq -r '.results[] | select(.snapshotStatus=="mismatch") | .caseId')" "01-low-risk-happy-path"

echo ""
echo "=== Results ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
