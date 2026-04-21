#!/usr/bin/env bash
# test-overlay-how-it-works-canonical-paths.sh -- ensure Claude overlay how-it-works doc teaches canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/platforms/claude-code/docs/how-it-works.md"

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

echo "=== Overlay how-it-works canonical paths ==="

assert_contains 'saves exit codes to `baseline.json` under the active contract artifact root' "overlay how-it-works uses canonical baseline wording"
assert_contains 'Canonical run artifacts live under the active contract artifact root `.signum/contracts/<contractId>/`.' "overlay how-it-works mentions canonical contract root"
assert_contains '`anti_entropy_report.json`' "overlay how-it-works includes anti-entropy artifact"
assert_contains '`reviews/`' "overlay how-it-works lists canonical reviews dir in durable snapshots"
assert_contains '`iterations/`' "overlay how-it-works lists canonical iterations dir in durable snapshots"

assert_not_contains 'saves exit codes to `.signum/baseline.json`' "overlay how-it-works no longer teaches root baseline path"
assert_not_contains 'Live working-set artifacts are written to `.signum/`' "overlay how-it-works no longer teaches root live-working-set model"
assert_not_contains 'mirrors durable per-contract snapshots into `.signum/contracts/<contractId>/` for history/archive flows. That per-contract directory is not the active workspace while a run is in flight.' "overlay how-it-works no longer teaches mirror-only contract dir model"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
