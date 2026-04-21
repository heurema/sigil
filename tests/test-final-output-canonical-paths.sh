#!/usr/bin/env bash
# test-final-output-canonical-paths.sh -- ensure final output references canonical artifact root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_COMMAND="$SCRIPT_DIR/../commands/signum.md"
OVERLAY_COMMAND="$SCRIPT_DIR/../platforms/claude-code/commands/signum.md"

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

echo "=== Final output canonical paths ==="

for command in "$ROOT_COMMAND" "$OVERLAY_COMMAND"; do
  label="$(basename "$(dirname "$command")")"
  assert_pass "command exists for ${label}" test -f "$command"
  assert_pass "final output uses active_artifact_root for ${label}" \
    grep -Fq 'ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"' "$command"
  assert_pass "final output shows canonical artifact root banner for ${label}" \
    grep -Fq 'echo "=== Canonical artifact root ==="' "$command"
  assert_pass "final output instructs users to use canonical artifact root for ${label}" \
    grep -Fq 'canonical artifact root shown above' "$command"
done

assert_absent "root command removed old .signum artifact banner" \
  'echo "=== Artifacts in .signum/ ==="' "$ROOT_COMMAND"
assert_absent "overlay command removed old .signum artifact banner" \
  'echo "=== Artifacts in .signum/ ==="' "$OVERLAY_COMMAND"
assert_absent "root next steps no longer point at .signum/combined.patch" \
  'Review `.signum/combined.patch`' "$ROOT_COMMAND"
assert_absent "root next steps no longer point at .signum/audit_summary.json" \
  'Review `.signum/audit_summary.json`' "$ROOT_COMMAND"
assert_absent "overlay next steps no longer point at .signum/combined.patch" \
  'Review `.signum/combined.patch`' "$OVERLAY_COMMAND"
assert_absent "overlay next steps no longer point at .signum/audit_summary.json" \
  'Review `.signum/audit_summary.json`' "$OVERLAY_COMMAND"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
