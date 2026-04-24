#!/usr/bin/env bash
# test-doc-canonical-artifact-root.sh -- ensure core docs describe canonical contract artifact root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
README="$SCRIPT_DIR/../README.md"
REFERENCE="$SCRIPT_DIR/../docs/reference.md"
HOW_IT_WORKS="$SCRIPT_DIR/../docs/how-it-works.md"

passed=0
failed=0

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

assert_absent() {
  local name="$1"; shift
  local pattern="$1"; shift
  local file="$1"
  if grep -Fq "$pattern" "$file"; then
    printf '  FAIL: %s — found forbidden pattern: %s\n' "$name" "$pattern"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== Doc canonical artifact root ==="

assert_pass "README mentions canonical contract artifact root" \
  grep -Fq '.signum/contracts/<contractId>/' "$README"
assert_pass "README describes root signum as registry/state/archive namespace" \
  grep -Fq 'registry/state/archive namespace' "$README"
assert_pass "README says normal runs do not create root artifacts" \
  grep -Fq 'normal runs do not create root artifact files or root runtime dirs' "$README"
assert_pass "reference doc mentions active contract artifact root" \
  grep -Fq 'active contract artifact root' "$REFERENCE"
assert_pass "how-it-works mentions active contract artifact root" \
  grep -Fq 'active contract artifact root' "$HOW_IT_WORKS"
assert_pass "reference doc says root artifact paths are legacy migration inputs" \
  grep -Fq 'root artifact paths are legacy migration inputs only' "$REFERENCE"
assert_pass "how-it-works says root artifact paths are legacy migration inputs" \
  grep -Fq 'root artifact paths are legacy migration inputs only' "$HOW_IT_WORKS"

assert_absent "README no longer says root signum is live working set" \
  '.signum/` remains the live working set for the current run' "$README"
assert_absent "reference doc no longer says contractor writes root contract.json" \
  'produces `.signum/contract.json`' "$REFERENCE"
assert_absent "reference doc no longer lists execute outputs as root paths" \
  'Outputs: `.signum/baseline.json`, `.signum/combined.patch`, `.signum/execute_log.json`.' "$REFERENCE"
assert_absent "reference doc no longer says pack assembles root proofpack" \
  'Assembles `.signum/proofpack.json`' "$REFERENCE"
assert_absent "reference doc no longer points provider status to root reviews dir" \
  'Check `.signum/reviews/` for provider status.' "$REFERENCE"
assert_absent "reference doc no longer says root signum is live working set" \
  'Live working-set artifacts are written to `.signum/`' "$REFERENCE"
assert_absent "how-it-works no longer says baseline saved to root path" \
  'saves exit codes to `.signum/baseline.json`' "$HOW_IT_WORKS"
assert_absent "how-it-works no longer says root signum is live working set" \
  'Live working-set artifacts are written to `.signum/`' "$HOW_IT_WORKS"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
