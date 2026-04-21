#!/usr/bin/env bash
# test-reconcile-canonical-paths.sh -- ensure Claude overlay RECONCILE uses canonical artifact root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMAND="$SCRIPT_DIR/../platforms/claude-code/commands/signum.md"

passed=0
failed=0

assert_pass() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s | %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_section_absent() {
  local name="$1"
  local pattern="$2"
  local section
  section=$(awk '
    /^## Phase 5: RECONCILE$/ { in_reconcile=1 }
    /^## Final Output$/ { in_reconcile=0 }
    in_reconcile { print }
  ' "$COMMAND")
  if grep -Fq "$pattern" <<<"$section"; then
    printf '  FAIL: %s | found forbidden pattern: %s\n' "$name" "$pattern"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== RECONCILE canonical paths ==="
assert_pass "overlay command exists" test -f "$COMMAND"
assert_pass "RECONCILE uses active_artifact_root" \
  grep -Fq 'ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"' "$COMMAND"
assert_pass "RECONCILE prompt mentions canonical artifact root" \
  grep -Fq 'The canonical artifact root for the active contract is `.signum/contracts/<activeContractId>/`.' "$COMMAND"
assert_pass "RECONCILE writes reconcile report via canonical path" \
  grep -Fq 'RECONCILE_REPORT_PATH="${ARTIFACT_ROOT}reconcile_report.json"' "$COMMAND"
assert_pass "RECONCILE writes retro via canonical path" \
  grep -Fq 'RETRO_PATH="${ARTIFACT_ROOT}retro.json"' "$COMMAND"
assert_section_absent "RECONCILE no root contract path" '.signum/contract.json'
assert_section_absent "RECONCILE no root proofpack path" '.signum/proofpack.json'
assert_section_absent "RECONCILE no root reconcile_report path" '.signum/reconcile_report.json'
assert_section_absent "RECONCILE no root audit_summary path" '.signum/audit_summary.json'
assert_section_absent "RECONCILE no root execute_log path" '.signum/execute_log.json'
assert_section_absent "RECONCILE no root retro path" '.signum/retro.json'

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
