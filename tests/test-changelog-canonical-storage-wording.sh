#!/usr/bin/env bash
# test-changelog-canonical-storage-wording.sh -- keep recent changelog entries aligned with canonical contract-root storage wording
set -euo pipefail

CHANGELOG="$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md"

passed=0
failed=0

assert_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$CHANGELOG"; then
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
  if grep -Fq -- "$needle" "$CHANGELOG"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

echo "=== Changelog canonical storage wording ==="

assert_contains 'anti_entropy_report.json` under the active contract artifact root' "anti-entropy changelog uses canonical root wording"
assert_contains 'writes append-only receipts under the active contract artifact root in `runs/<run_id>/`' "receipt-chain changelog uses canonical runs wording"
assert_contains 'receipt-chain paths (`receipts/`, `runs/`, `snapshots/`) under the active contract artifact root' "engineer prompt changelog uses canonical verifier-owned paths"
assert_contains 'Lane artifacts in `iterations/NN/lanes/A|B/` under the active contract artifact root' "parallel lanes changelog uses canonical iteration root"
assert_contains 'Per-iteration artifact storage in `iterations/NN/` under the active contract artifact root' "iterative audit changelog uses canonical iteration root"

assert_not_contains 'emits advisory `.signum/anti_entropy_report.json`' "changelog no longer teaches root anti-entropy artifact path"
assert_not_contains 'writes append-only receipt to `.signum/runs/<run_id>/`' "changelog no longer teaches root runs path"
assert_not_contains 'receipt-chain paths (`.signum/receipts/`, `.signum/runs/`, `.signum/snapshots/`)' "changelog no longer teaches root verifier-owned dirs"
assert_not_contains 'Lane artifacts in `.signum/iterations/NN/lanes/A|B/`' "changelog no longer teaches root lane paths"
assert_not_contains 'Per-iteration artifact storage in `.signum/iterations/NN/`' "changelog no longer teaches root iteration paths"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
