#!/usr/bin/env bash
# mechanic-parser.sh -- run project checks and compare with baseline.json
# Detects and runs: pytest, npm test, cargo test, go test (tests);
#                   ruff, eslint (lint); mypy, tsc (typecheck).
# Structured JSON output for ruff (--output-format json) and eslint (-f json).
# Parseable text patterns for pytest/cargo test (origin:stable_text).
# Usage: mechanic-parser.sh <baseline_json_path>
# Output: <baseline_dir>/mechanic_report.json
# Exit 0: report written (checks may have regressions — that is not a fatal error)
# Exit 1: fatal error (missing jq, missing baseline file)

set -uo pipefail

BASELINE_FILE="${1:-}"
OUTPUT_DIR=""
MECHANIC_REPORT_PATH=""
FLAKY_TESTS_PATH=""

if [ -z "$BASELINE_FILE" ]; then
  echo "Usage: mechanic-parser.sh <baseline_json_path>" >&2
  exit 1
fi

OUTPUT_DIR=$(dirname "$BASELINE_FILE")
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="."
MECHANIC_REPORT_PATH="${OUTPUT_DIR}/mechanic_report.json"
FLAKY_TESTS_PATH="${OUTPUT_DIR}/flaky_tests.json"

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq not found" >&2
  exit 1
fi

if [ ! -f "$BASELINE_FILE" ]; then
  echo "ERROR: mechanic-parser.sh: baseline file not found: $BASELINE_FILE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Read baseline exit codes
# ---------------------------------------------------------------------------
BL_LINT=$(jq -r '.lint' "$BASELINE_FILE")
BL_TYPE=$(jq -r '.typecheck' "$BASELINE_FILE")
BL_TEST=$(jq -r '.tests.exit_code // .tests' "$BASELINE_FILE")
BL_TEST_FAILING=$(jq -c '.tests.failing // []' "$BASELINE_FILE")

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------
LINT_EXIT=0
LINT_OUT=""
LINT_ID=""
LINT_FINDINGS_JSON=""
LINT_FINDINGS_AVAILABLE=false

if [ -f "pyproject.toml" ] && grep -q "ruff" pyproject.toml 2>/dev/null; then
  LINT_ID="ruff"
  LINT_OUT=$(ruff check . --output-format json 2>&1)
  LINT_EXIT=$?
  # ruff --output-format json exits non-zero when there are findings; also try to parse JSON
  if echo "$LINT_OUT" | jq 'type == "array"' > /dev/null 2>&1 && [ "$(echo "$LINT_OUT" | jq 'type')" = '"array"' ]; then
    LINT_FINDINGS_AVAILABLE=true
    LINT_FINDINGS_JSON=$(echo "$LINT_OUT" | jq '[.[] | {
      file: .filename,
      line: (.location.row // 0),
      column: (.location.column // 0),
      code: .code,
      message: .message,
      origin: "structured"
    }]')
  else
    # Fallback: re-run without json format to get readable output for LINT_EXIT
    LINT_OUT=$(ruff check . 2>&1)
    LINT_EXIT=$?
    LINT_FINDINGS_AVAILABLE=false
  fi
elif [ -f "package.json" ] && grep -q "eslint" package.json 2>/dev/null; then
  LINT_ID="eslint"
  LINT_OUT=$(npx eslint . -f json 2>&1)
  LINT_EXIT=$?
  if echo "$LINT_OUT" | jq 'type == "array"' > /dev/null 2>&1 && [ "$(echo "$LINT_OUT" | jq 'type')" = '"array"' ]; then
    LINT_FINDINGS_AVAILABLE=true
    LINT_FINDINGS_JSON=$(echo "$LINT_OUT" | jq '[.[] | .filePath as $f | .messages[] | {
      file: $f,
      line: (.line // 0),
      column: (.column // 0),
      code: (.ruleId // "unknown"),
      message: .message,
      origin: "structured"
    }]')
  else
    LINT_OUT=$(npx eslint . 2>&1)
    LINT_EXIT=$?
    LINT_FINDINGS_AVAILABLE=false
  fi
else
  LINT_ID="none"
  LINT_OUT="no linter found, skipped"
  LINT_EXIT=0
fi

# ---------------------------------------------------------------------------
# Typecheck
# ---------------------------------------------------------------------------
TYPE_EXIT=0
TYPE_OUT=""
TYPE_ID=""
TYPE_FINDINGS_JSON=""
TYPE_FINDINGS_AVAILABLE=false

if [ -f "pyproject.toml" ] && grep -q "mypy" pyproject.toml 2>/dev/null; then
  TYPE_ID="mypy"
  TYPE_OUT=$(mypy . 2>&1)
  TYPE_EXIT=$?
  # mypy text output: parse "file:line: error: message [code]" lines
  if [ $TYPE_EXIT -ne 0 ] && echo "$TYPE_OUT" | grep -qE '^.*:[0-9]+: error:'; then
    TYPE_FINDINGS_AVAILABLE=true
    TYPE_FINDINGS_JSON=$(echo "$TYPE_OUT" | grep -E '^.*:[0-9]+: error:' | while IFS= read -r line; do
      f=$(echo "$line" | sed 's/:\([0-9]*\): error:.*//')
      ln=$(echo "$line" | sed 's/^[^:]*:\([0-9]*\): error:.*/\1/')
      msg=$(echo "$line" | sed 's/^[^:]*:[0-9]*: error: //')
      code=$(echo "$msg" | grep -oE '\[[A-Za-z0-9_-]+\]$' | tr -d '[]' || echo "")
      jq -n --arg f "$f" --argjson ln "${ln:-0}" --arg msg "$msg" --arg code "$code" \
        '{file: $f, line: $ln, column: 0, code: $code, message: $msg, origin: "stable_text"}'
    done | jq -s '.')
  fi
elif [ -f "tsconfig.json" ]; then
  TYPE_ID="tsc"
  TYPE_OUT=$(npx tsc --noEmit 2>&1)
  TYPE_EXIT=$?
  # tsc text output: parse "file(line,col): error TSxxxx: message"
  if [ $TYPE_EXIT -ne 0 ] && echo "$TYPE_OUT" | grep -qE '\([0-9]+,[0-9]+\): error TS'; then
    TYPE_FINDINGS_AVAILABLE=true
    TYPE_FINDINGS_JSON=$(echo "$TYPE_OUT" | grep -E '\([0-9]+,[0-9]+\): error TS' | while IFS= read -r line; do
      f=$(echo "$line" | sed 's/(\([0-9]*\),[0-9]*): error.*//' | sed 's/^.*: //')
      ln=$(echo "$line" | grep -oE '\([0-9]+,' | tr -d '(,' || echo "0")
      col=$(echo "$line" | grep -oE ',[0-9]+\)' | tr -d ',)' || echo "0")
      code=$(echo "$line" | grep -oE 'error TS[0-9]+' | sed 's/error //' || echo "")
      msg=$(echo "$line" | sed 's/^.*: error TS[0-9]*: //')
      jq -n --arg f "$f" --argjson ln "${ln:-0}" --argjson col "${col:-0}" \
        --arg code "$code" --arg msg "$msg" \
        '{file: $f, line: $ln, column: $col, code: $code, message: $msg, origin: "stable_text"}'
    done | jq -s '.')
  fi
else
  TYPE_ID="none"
  TYPE_OUT="no typecheck found, skipped"
  TYPE_EXIT=0
fi

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
TEST_EXIT=0
TEST_OUT=""
TEST_ID=""
TEST_FAILING='[]'
NEW_FAILURES='[]'
TEST_FINDINGS_JSON=""
TEST_FINDINGS_AVAILABLE=false

if [ -f "pyproject.toml" ] && grep -q "pytest" pyproject.toml 2>/dev/null; then
  TEST_ID="pytest"
  TEST_OUT=$(pytest --tb=short -q 2>&1)
  TEST_EXIT=$?
  TEST_FAILING=$(echo "$TEST_OUT" | grep -E '^FAILED ' | sed 's/^FAILED //' | sed 's/ - .*//' | jq -R . | jq -s .)
  [ -z "$TEST_FAILING" ] && TEST_FAILING='[]'
  NEW_FAILURES=$(jq -n --argjson curr "$TEST_FAILING" --argjson base "$BL_TEST_FAILING" \
    '[$curr[] | select(. as $t | $base | index($t) | not)]')

  # Flaky test retry: for each new failure, run it twice more; mixed results → flaky
  FLAKY_TESTS='[]'
  CONFIRMED_FAILURES='[]'
  if [ "$(echo "$NEW_FAILURES" | jq 'length')" -gt 0 ]; then
    while IFS= read -r TEST_NAME; do
      R1=$(pytest "$TEST_NAME" --tb=no -q 2>&1; echo "EXIT:$?")
      R2=$(pytest "$TEST_NAME" --tb=no -q 2>&1; echo "EXIT:$?")
      E1=$(echo "$R1" | grep "EXIT:" | sed 's/EXIT://')
      E2=$(echo "$R2" | grep "EXIT:" | sed 's/EXIT://')
      if [ "$E1" != "$E2" ] || ([ "$E1" = "0" ] && [ "$E2" = "0" ]); then
        FLAKY_TESTS=$(echo "$FLAKY_TESTS" | jq --arg t "$TEST_NAME" '. + [$t]')
      else
        CONFIRMED_FAILURES=$(echo "$CONFIRMED_FAILURES" | jq --arg t "$TEST_NAME" '. + [$t]')
      fi
    done < <(echo "$NEW_FAILURES" | jq -r '.[]')
    NEW_FAILURES="$CONFIRMED_FAILURES"
  fi

  # Persist flaky tests
  jq -n --argjson flaky "$FLAKY_TESTS" \
    '{"detectedAt": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'", "flakyTests": $flaky}' \
    > "$FLAKY_TESTS_PATH"
  if [ "$(echo "$FLAKY_TESTS" | jq 'length')" -gt 0 ]; then
    echo "Flaky tests detected (removed from NEW_FAILURES): $(echo "$FLAKY_TESTS" | jq -r '.[]' | tr '\n' ' ')"
  fi

  # stable_text findings: FAILED lines from pytest output
  if [ "$(echo "$NEW_FAILURES" | jq 'length')" -gt 0 ]; then
    TEST_FINDINGS_AVAILABLE=true
    TEST_FINDINGS_JSON=$(echo "$NEW_FAILURES" | jq '[.[] | {
      file: (split("::")[0] // .),
      line: 0,
      column: 0,
      code: "FAILED",
      message: .,
      origin: "stable_text"
    }]')
  fi

elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
  TEST_ID="npm_test"
  TEST_OUT=$(npm test 2>&1)
  TEST_EXIT=$?

elif [ -f "Cargo.toml" ]; then
  TEST_ID="cargo_test"
  TEST_OUT=$(cargo test 2>&1)
  TEST_EXIT=$?
  # stable_text: parse "test <name> ... FAILED" lines
  if [ $TEST_EXIT -ne 0 ]; then
    CARGO_FAILS=$(echo "$TEST_OUT" | grep -E '^test .+ \.\.\. FAILED$' | sed 's/^test //' | sed 's/ \.\.\. FAILED$//' || true)
    if [ -n "$CARGO_FAILS" ]; then
      TEST_FINDINGS_AVAILABLE=true
      TEST_FINDINGS_JSON=$(echo "$CARGO_FAILS" | while IFS= read -r tname; do
        jq -n --arg t "$tname" '{file: "", line: 0, column: 0, code: "FAILED", message: $t, origin: "stable_text"}'
      done | jq -s '.')
      NEW_FAILURES=$(echo "$CARGO_FAILS" | jq -R . | jq -s .)
    fi
  fi

elif [ -f "go.mod" ]; then
  TEST_ID="go_test"
  TEST_OUT=$(go test ./... 2>&1)
  TEST_EXIT=$?
  # stable_text: parse "--- FAIL: TestName" lines
  if [ $TEST_EXIT -ne 0 ]; then
    GO_FAILS=$(echo "$TEST_OUT" | grep -E '^--- FAIL: ' | sed 's/^--- FAIL: //' | sed 's/ (.*//' || true)
    if [ -n "$GO_FAILS" ]; then
      TEST_FINDINGS_AVAILABLE=true
      TEST_FINDINGS_JSON=$(echo "$GO_FAILS" | while IFS= read -r tname; do
        jq -n --arg t "$tname" '{file: "", line: 0, column: 0, code: "FAILED", message: $t, origin: "stable_text"}'
      done | jq -s '.')
      NEW_FAILURES=$(echo "$GO_FAILS" | jq -R . | jq -s '.')
    fi
  fi

else
  TEST_ID="none"
  TEST_OUT="no test runner found, skipped"
  TEST_EXIT=0
fi

# ---------------------------------------------------------------------------
# Compute statuses and regression flags
# ---------------------------------------------------------------------------
lint_status=$([ $LINT_EXIT -eq 0 ] && echo "pass" || echo "fail")
type_status=$([ $TYPE_EXIT -eq 0 ] && echo "pass" || echo "fail")
test_status=$([ $TEST_EXIT -eq 0 ] && echo "pass" || echo "fail")

bl_lint_status=$([ "$BL_LINT" = "0" ] && echo "pass" || echo "fail")
bl_type_status=$([ "$BL_TYPE" = "0" ] && echo "pass" || echo "fail")
bl_test_status=$([ "$BL_TEST" = "0" ] && echo "pass" || echo "fail")

lint_regression=false
type_regression=false
test_regression=false

[ "$bl_lint_status" = "pass" ] && [ "$lint_status" = "fail" ] && lint_regression=true
[ "$bl_type_status" = "pass" ] && [ "$type_status" = "fail" ] && type_regression=true
if [ "$(echo "$NEW_FAILURES" | jq 'length')" -gt 0 ]; then
  test_regression=true
elif [ "$bl_test_status" = "pass" ] && [ "$test_status" = "fail" ]; then
  test_regression=true
fi

has_regressions=false
( $lint_regression || $type_regression || $test_regression ) && has_regressions=true

# ---------------------------------------------------------------------------
# Build checks array and per-check findings
# ---------------------------------------------------------------------------

# Helper: determine skip vs pass/fail based on runner id
_lint_skip=false
_type_skip=false
_test_skip=false
[ "$LINT_ID" = "none" ] && _lint_skip=true
[ "$TYPE_ID" = "none" ] && _type_skip=true
[ "$TEST_ID" = "none" ] && _test_skip=true

_lint_status_final="$lint_status"
_type_status_final="$type_status"
_test_status_final="$test_status"
$_lint_skip && _lint_status_final="skip"
$_type_skip && _type_status_final="skip"
$_test_skip && _test_status_final="skip"

_bl_lint_final="$bl_lint_status"
_bl_type_final="$bl_type_status"
_bl_test_final="$bl_test_status"
$_lint_skip && _bl_lint_final="skip"
$_type_skip && _bl_type_final="skip"
$_test_skip && _bl_test_final="skip"

# Lint count
lint_count=0
if $LINT_FINDINGS_AVAILABLE && [ -n "$LINT_FINDINGS_JSON" ]; then
  lint_count=$(echo "$LINT_FINDINGS_JSON" | jq 'length')
fi

# Type count
type_count=0
if $TYPE_FINDINGS_AVAILABLE && [ -n "$TYPE_FINDINGS_JSON" ]; then
  type_count=$(echo "$TYPE_FINDINGS_JSON" | jq 'length')
fi

# Test count
test_count=$(echo "$NEW_FAILURES" | jq 'length')

# ---------------------------------------------------------------------------
# Write mechanic_report.json
# ---------------------------------------------------------------------------

# Build checks array via jq
CHECKS_JSON=$(jq -n \
  --arg lint_id "${LINT_ID:-lint}" \
  --arg lint_status "$_lint_status_final" \
  --arg lint_bl "$_bl_lint_final" \
  --argjson lint_reg "$lint_regression" \
  --argjson lint_count "$lint_count" \
  --argjson lint_fa "$LINT_FINDINGS_AVAILABLE" \
  --arg type_id "${TYPE_ID:-typecheck}" \
  --arg type_status "$_type_status_final" \
  --arg type_bl "$_bl_type_final" \
  --argjson type_reg "$type_regression" \
  --argjson type_count "$type_count" \
  --argjson type_fa "$TYPE_FINDINGS_AVAILABLE" \
  --arg test_id "${TEST_ID:-tests}" \
  --arg test_status "$_test_status_final" \
  --arg test_bl "$_bl_test_final" \
  --argjson test_reg "$test_regression" \
  --argjson test_count "$test_count" \
  --argjson test_fa "$TEST_FINDINGS_AVAILABLE" \
  '[
    {id: $lint_id, category: "lint",      status: $lint_status, baseline_status: $lint_bl, regression: $lint_reg, count: $lint_count, findings_available: $lint_fa},
    {id: $type_id, category: "typecheck", status: $type_status, baseline_status: $type_bl, regression: $type_reg, count: $type_count, findings_available: $type_fa},
    {id: $test_id, category: "test",      status: $test_status, baseline_status: $test_bl, regression: $test_reg, count: $test_count, findings_available: $test_fa}
  ]')

# Build per-check findings arrays
FINDINGS_LINT_JSON='[]'
FINDINGS_TYPE_JSON='[]'
FINDINGS_TEST_JSON='[]'

if $LINT_FINDINGS_AVAILABLE && [ -n "$LINT_FINDINGS_JSON" ]; then
  _lint_id_val="${LINT_ID:-lint}"
  FINDINGS_LINT_JSON=$(echo "$LINT_FINDINGS_JSON" | jq --arg cid "$_lint_id_val" '[.[] | {check_id: $cid} + .]')
fi
if $TYPE_FINDINGS_AVAILABLE && [ -n "$TYPE_FINDINGS_JSON" ]; then
  _type_id_val="${TYPE_ID:-typecheck}"
  FINDINGS_TYPE_JSON=$(echo "$TYPE_FINDINGS_JSON" | jq --arg cid "$_type_id_val" '[.[] | {check_id: $cid} + .]')
fi
if $TEST_FINDINGS_AVAILABLE && [ -n "$TEST_FINDINGS_JSON" ]; then
  _test_id_val="${TEST_ID:-tests}"
  FINDINGS_TEST_JSON=$(echo "$TEST_FINDINGS_JSON" | jq --arg cid "$_test_id_val" '[.[] | {check_id: $cid} + .]')
fi

ALL_FINDINGS=$(jq -n \
  --argjson lint "$FINDINGS_LINT_JSON" \
  --argjson type "$FINDINGS_TYPE_JSON" \
  --argjson test "$FINDINGS_TEST_JSON" \
  '$lint + $type + $test')

# Write legacy fields too for backward compat with existing synthesizer
jq -n \
  --argjson checks "$CHECKS_JSON" \
  --argjson findings "$ALL_FINDINGS" \
  --argjson lint_exit "$LINT_EXIT" \
  --argjson type_exit "$TYPE_EXIT" \
  --argjson test_exit "$TEST_EXIT" \
  --argjson bl_lint "$BL_LINT" \
  --argjson bl_type "$BL_TYPE" \
  --argjson bl_test "$BL_TEST" \
  --argjson new_failures "$NEW_FAILURES" \
  --argjson test_failing "$TEST_FAILING" \
  --argjson has_regressions "$has_regressions" \
  '{
    checks: $checks,
    findings: $findings,
    hasRegressions: $has_regressions,
    lint:      { status: (if $bl_lint == 0 and $lint_exit == 0 then "pass" elif $lint_exit != 0 then "fail" else "pass" end),
                 exitCode: $lint_exit, baseline: $bl_lint,
                 regression: ($bl_lint == 0 and $lint_exit != 0) },
    typecheck: { status: (if $bl_type == 0 and $type_exit == 0 then "pass" elif $type_exit != 0 then "fail" else "pass" end),
                 exitCode: $type_exit, baseline: $bl_type,
                 regression: ($bl_type == 0 and $type_exit != 0) },
    tests:     { status: (if $test_exit == 0 then "pass" else "fail" end),
                 exitCode: $test_exit, baseline: $bl_test,
                 failing: $test_failing, newFailures: $new_failures,
                 regression: (if ($new_failures | length) > 0 then true
                              elif $bl_test == 0 and $test_exit != 0 then true
                              else false end) }
  }' > "$MECHANIC_REPORT_PATH"

echo "Mechanic done. Lint=${LINT_ID}:${LINT_EXIT}(bl:${BL_LINT}) Typecheck=${TYPE_ID}:${TYPE_EXIT}(bl:${BL_TYPE}) Tests=${TEST_ID}:${TEST_EXIT}(bl:${BL_TEST})"
