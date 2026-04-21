#!/usr/bin/env bash
# test-canonical-archive-cleanup-paths.sh -- ensure archive/close/finalize use canonical helpers
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

section_between() {
  local file="$1"
  local start_pat="$2"
  local end_pat="$3"
  awk -v start_pat="$start_pat" -v end_pat="$end_pat" '
    $0 ~ start_pat { in_section=1 }
    in_section { print }
    in_section && $0 ~ end_pat { exit }
  ' "$file"
}

assert_section_absent() {
  local name="$1"
  local pattern="$2"
  local section="$3"
  if grep -Fq "$pattern" <<<"$section"; then
    printf '  FAIL: %s | found forbidden pattern: %s\n' "$name" "$pattern"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== Canonical archive/cleanup paths ==="

ROOT_ARCHIVE_SECTION=$(section_between "$ROOT_COMMAND" '^If the user.*`archive`' '^## Close Mode$')
ROOT_CLOSE_SECTION=$(section_between "$ROOT_COMMAND" '^## Close Mode$' '^## Project Resolution$')
ROOT_FINALIZE_SECTION=$(section_between "$ROOT_COMMAND" '^### Step 4\.5: Finalize run' '^## Error Handling$')
OVERLAY_ARCHIVE_SECTION=$(section_between "$OVERLAY_COMMAND" '^If the user.*`archive`' '^## Close Mode$')
OVERLAY_CLOSE_SECTION=$(section_between "$OVERLAY_COMMAND" '^## Close Mode$' '^## Project Resolution$')

assert_pass "root archive uses archive_contract_artifacts" \
  grep -Fq 'archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_DIR"' <<<"$ROOT_ARCHIVE_SECTION"
assert_pass "overlay archive uses archive_contract_artifacts" \
  grep -Fq 'archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_DIR"' <<<"$OVERLAY_ARCHIVE_SECTION"
assert_pass "root archive cleans root compatibility views" \
  grep -Fq 'purge_root_working_set_views >/dev/null 2>&1 || true' <<<"$ROOT_ARCHIVE_SECTION"
assert_pass "overlay archive cleans root compatibility views" \
  grep -Fq 'purge_root_working_set_views >/dev/null 2>&1 || true' <<<"$OVERLAY_ARCHIVE_SECTION"
assert_pass "root close cleans root compatibility views" \
  grep -Fq 'purge_root_working_set_views >/dev/null 2>&1 || true' <<<"$ROOT_CLOSE_SECTION"
assert_pass "overlay close cleans root compatibility views" \
  grep -Fq 'purge_root_working_set_views >/dev/null 2>&1 || true' <<<"$OVERLAY_CLOSE_SECTION"
assert_pass "root finalize archives from canonical contract dir" \
  grep -Fq 'archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_TMP"' <<<"$ROOT_FINALIZE_SECTION"
assert_pass "root finalize purges root views via helper" \
  grep -Fq 'purge_root_working_set_views >/dev/null 2>&1 || true' <<<"$ROOT_FINALIZE_SECTION"
assert_pass "root finalize copies archive tmp recursively" \
  grep -Fq 'cp -R "$ARCHIVE_TMP"/. "$ARCHIVE_FINAL"/' <<<"$ROOT_FINALIZE_SECTION"

assert_section_absent "root finalize no direct root contract copy" 'cp .signum/contract.json "$ARCHIVE_TMP/"' "$ROOT_FINALIZE_SECTION"
assert_section_absent "root finalize no direct root receipts copy" 'cp -R .signum/receipts/. "$ARCHIVE_TMP/receipts/"' "$ROOT_FINALIZE_SECTION"
assert_section_absent "root finalize no manual rm file list" 'rm -f .signum/contract.json' "$ROOT_FINALIZE_SECTION"
assert_section_absent "root archive no direct canonical file copies in command doc" 'cp "${DIR}contract.json" "$ARCHIVE_DIR"' "$ROOT_ARCHIVE_SECTION"
assert_section_absent "overlay archive no direct canonical file copies in command doc" 'cp "${DIR}contract.json" "$ARCHIVE_DIR"' "$OVERLAY_ARCHIVE_SECTION"


echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
