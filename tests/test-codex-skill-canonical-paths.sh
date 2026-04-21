#!/usr/bin/env bash
# test-codex-skill-canonical-paths.sh -- keep Codex Signum skill instructions aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/platforms/codex/SKILL.md"

passed=0
failed=0

assert_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

echo "=== Codex skill canonical paths ==="

assert_contains '.signum/contracts/<contractId>/' "skill doc introduces canonical artifact root"
assert_contains '.signum/contracts/index.json.activeContractId' "skill doc mentions active contract registry"
assert_contains 'Record attempts and outcomes in `execute_log.json` under the active contract artifact root.' "skill doc uses canonical execute log wording"
assert_contains 'If `contracts/index.json.activeContractId` or other pipeline artifacts already exist:' "skill doc uses registry-first resume wording"

assert_not_contains 'Keep all pipeline artifacts in `.signum/`.' "old root artifact rule removed"
assert_not_contains '- `.signum/contract.json`' "old root contract path removed"
assert_not_contains 'Capture baseline checks into `.signum/baseline.json`' "old root baseline wording removed"
assert_not_contains 'Record attempts and outcomes in `.signum/execute_log.json`.' "old root execute log wording removed"
assert_not_contains 'If `.signum/contract.json` or other pipeline artifacts already exist:' "old root resume wording removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
