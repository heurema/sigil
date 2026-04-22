#!/usr/bin/env bash
# test-release-smoke.sh -- verifies release smoke path and docs stay wired
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SMOKE_SCRIPT="$REPO_ROOT/lib/release-smoke.sh"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/release-guardrails.yml"
README_FILE="$REPO_ROOT/README.md"
RELIABILITY_FILE="$REPO_ROOT/docs/RELIABILITY.md"

passed=0
failed=0

assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -Fq "$expected" "$file"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — missing "%s" in %s\n' "$name" "$expected" "$file"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local name="$1" file="$2" unexpected="$3"
  if grep -Fq "$unexpected" "$file"; then
    printf '  FAIL: %s — unexpected "%s" in %s\n' "$name" "$unexpected" "$file"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== Release smoke wiring ==="
assert_contains "smoke runs Emporium sync check" "$SMOKE_SCRIPT" 'bash lib/check-emporium-sync.sh'
assert_contains "smoke covers init command surface" "$SMOKE_SCRIPT" 'bash tests/test-init-command-surface.sh'
assert_contains "smoke covers init harness scaffold" "$SMOKE_SCRIPT" 'bash tests/test-init-harness-scaffold.sh'
assert_contains "smoke covers brownfield harness flow" "$SMOKE_SCRIPT" 'bash tests/test-brownfield-harness-flow.sh'

echo ""
echo "=== Workflow wiring ==="
assert_contains "workflow runs release smoke path" "$WORKFLOW_FILE" 'run: bash lib/release-smoke.sh'
assert_contains "workflow injects Emporium marketplace path" "$WORKFLOW_FILE" 'EMPORIUM_MARKETPLACE_PATH:'
assert_contains "workflow checks out Emporium" "$WORKFLOW_FILE" "repository: \${{ github.event.inputs.emporium_repo || 'heurema/emporium' }}"
assert_contains "workflow supports manual dispatch" "$WORKFLOW_FILE" 'workflow_dispatch:'
assert_contains "workflow runs on release publish" "$WORKFLOW_FILE" 'published'
assert_contains "workflow limits push scope" "$WORKFLOW_FILE" 'paths:'
assert_contains "workflow is canonical-repo only" "$WORKFLOW_FILE" "if: github.repository == 'heurema/signum'"
assert_contains "workflow parameterizes Emporium git ref" "$WORKFLOW_FILE" 'EMPORIUM_GIT_REF:'
assert_contains "workflow parameterizes Emporium path" "$WORKFLOW_FILE" 'EMPORIUM_PATH:'
assert_not_contains "workflow no longer runs on every pull request" "$WORKFLOW_FILE" 'pull_request:'

echo ""
echo "=== Documentation wiring ==="
assert_contains "README documents Emporium release step" "$README_FILE" 'heurema/emporium/.claude-plugin/marketplace.json'
assert_contains "README documents release smoke command" "$README_FILE" 'bash lib/release-smoke.sh'
assert_contains "README documents harness smoke coverage" "$README_FILE" '/signum:init --harness'
assert_contains "README documents trigger rationale" "$README_FILE" 'workflow_dispatch'
assert_contains "Reliability doc includes release smoke" "$RELIABILITY_FILE" 'bash lib/release-smoke.sh'
assert_contains "Reliability doc mentions marketplace install journey" "$RELIABILITY_FILE" 'Fresh marketplace install resolves current Signum release'

echo ""
echo "=== Results ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
