#!/usr/bin/env bash
# test-intentional-root-compatibility-mentions.sh -- keep remaining root-path mentions explicit and intentional
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"

passed=0
failed=0

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_no_matches() {
  local label="$1"
  shift
  if "$@" >/tmp/test_out.$$ 2>&1; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s\n' "$label"
    sed 's/^/    /' /tmp/test_out.$$
    failed=$((failed + 1))
  fi
  rm -f /tmp/test_out.$$
}

assert_exact_file_set() {
  local label="$1"
  local actual expected
  actual="$2"
  expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s\n' "$label"
    printf '    expected:\n%s\n' "$expected"
    printf '    actual:\n%s\n' "$actual"
    failed=$((failed + 1))
  fi
}

echo "=== Intentional root compatibility mentions ==="

CONTRACT_HITS="$(
  cd "$ROOT_DIR" && \
  rg -l '\.signum/contract\.json' \
    --glob '!**/tests/**' \
    --glob '!commands/signum.md' \
    --glob '!platforms/claude-code/commands/signum.md' \
    --glob '!lib/contract-injection-scan.sh' \
    --glob '!platforms/claude-code/lib/signum-ci.sh' \
    --glob '!lib/signum-ci.sh' \
    --glob '!lib/snapshot-tree.sh' \
    --glob '!lib/proofpack-index.sh' \
    . | sort
)"

EXPECTED_CONTRACT_HITS=$'./README.md\n./agents/contractor.md\n./docs/reference.md\n./platforms/claude-code/agents/contractor.md'

assert_exact_file_set \
  "only intentional non-test root contract mentions remain" \
  "$CONTRACT_HITS" \
  "$EXPECTED_CONTRACT_HITS"

assert_contains "$ROOT_DIR/README.md" \
  'resume checks should use the registry first, not root `.signum/contract.json`' \
  "README frames root contract path as non-primary resume fallback"
assert_contains "$ROOT_DIR/docs/reference.md" \
  'with a root `.signum/contract.json` compatibility path during the migration' \
  "reference doc frames root contract path as compatibility path"
assert_contains "$ROOT_DIR/agents/contractor.md" \
  '`.signum/contract.json` is only a compatibility view pointing at that canonical file' \
  "root contractor prompt frames root contract path as compatibility view"
assert_contains "$ROOT_DIR/platforms/claude-code/agents/contractor.md" \
  '`.signum/contract.json` is only a compatibility view pointing at that canonical file' \
  "overlay contractor prompt frames root contract path as compatibility view"

assert_no_matches \
  "no stray root proofpack path remains outside legacy helpers and tests" \
  bash -lc "cd '$ROOT_DIR' && ! rg -n '\\.signum/proofpack\\.json' \
    --glob '!**/tests/**' \
    --glob '!commands/signum.md' \
    --glob '!platforms/claude-code/commands/signum.md' \
    --glob '!lib/signum-ci.sh' \
    --glob '!platforms/claude-code/lib/signum-ci.sh' \
    --glob '!lib/proofpack-index.sh' \
    ."

assert_no_matches \
  "no stray root audit-summary path remains outside commands and tests" \
  bash -lc "cd '$ROOT_DIR' && ! rg -n '\\.signum/audit_summary\\.json' \
    --glob '!**/tests/**' \
    --glob '!commands/signum.md' \
    --glob '!platforms/claude-code/commands/signum.md' \
    ."

assert_no_matches \
  "no stray root baseline path remains outside commands and tests" \
  bash -lc "cd '$ROOT_DIR' && ! rg -n '\\.signum/baseline\\.json' \
    --glob '!**/tests/**' \
    --glob '!commands/signum.md' \
    --glob '!platforms/claude-code/commands/signum.md' \
    ."

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [[ "$failed" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
