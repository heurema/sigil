#!/usr/bin/env bash
# test-pack-canonical-paths.sh -- ensure PACK phase reads and writes via canonical artifact root
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
    printf '  FAIL: %s | %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_section_absent() {
  local name="$1"
  local pattern="$2"
  local file="$3"
  local section
  section=$(awk '
    /^## Phase 4: PACK$/ { in_pack=1 }
    /^## Final Output$/ { in_pack=0 }
    /^## Phase 5:/ { in_pack=0 }
    in_pack { print }
  ' "$file")
  if grep -Fq "$pattern" <<<"$section"; then
    printf '  FAIL: %s | found forbidden pattern: %s\n' "$name" "$pattern"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== PACK canonical paths ==="

for command in "$ROOT_COMMAND" "$OVERLAY_COMMAND"; do
  if [[ "$command" == *"/platforms/claude-code/"* ]]; then
    label="claude-overlay"
  else
    label="root"
  fi
  assert_pass "command exists for ${label}" test -f "$command"
  assert_pass "PACK Step 4.0 uses active_artifact_root for ${label}" \
    grep -Fq 'ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"' "$command"
  assert_pass "PACK defines CONTRACT_PATH for ${label}" \
    grep -Fq 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$command"
  assert_pass "PACK defines PROOFPACK_PATH for ${label}" \
    grep -Fq 'PROOFPACK_PATH="${ARTIFACT_ROOT}proofpack.json"' "$command"
  assert_pass "PACK writes proofpack via canonical path for ${label}" \
    grep -Fq "' > \"\$PROOFPACK_PATH\"" "$command"
  assert_pass "PACK anti-entropy reads canonical proofpack for ${label}" \
    grep -Fq -- '--proofpack "$PROOFPACK_PATH"' "$command"
  assert_section_absent "PACK no root contract.json path for ${label}" '.signum/contract.json' "$command"
  assert_section_absent "PACK no root proofpack.json path for ${label}" '.signum/proofpack.json' "$command"
  assert_section_absent "PACK no root anti_entropy_report.json path for ${label}" '.signum/anti_entropy_report.json' "$command"
  assert_section_absent "PACK no root audit_summary.json path for ${label}" '.signum/audit_summary.json' "$command"
  assert_section_absent "PACK no root execute_log.json path for ${label}" '.signum/execute_log.json' "$command"
  assert_section_absent "PACK no root audit_iteration_log.json path for ${label}" '.signum/audit_iteration_log.json' "$command"
  assert_section_absent "PACK no root reviews dir path for ${label}" '.signum/reviews/' "$command"
  assert_section_absent "PACK no root receipts execute path for ${label}" '.signum/receipts/execute.json' "$command"
done

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
