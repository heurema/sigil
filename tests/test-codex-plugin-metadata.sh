#!/usr/bin/env bash
# test-codex-plugin-metadata.sh -- keep Codex App plugin metadata installable and aligned
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.codex-plugin/plugin.json"
CLAUDE_PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
CODEX_SKILL="$REPO_ROOT/platforms/codex/SKILL.md"

passed=0
failed=0

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

assert_json_eq() {
  local name="$1" file="$2" filter="$3" expected="$4" actual
  actual="$(jq -r "$filter" "$file")"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected $expected, got $actual"
  fi
}

assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -Fq "$expected" "$file"; then
    pass "$name"
  else
    fail "$name" "missing \"$expected\" in $file"
  fi
}

echo "=== Codex plugin metadata ==="

assert_file "Codex plugin manifest exists" "$PLUGIN_JSON"
assert_file "Codex skill entrypoint exists" "$CODEX_SKILL"

if [ -f "$PLUGIN_JSON" ]; then
  jq empty "$PLUGIN_JSON"
  pass "Codex plugin manifest is valid JSON"

  ROOT_VERSION="$(jq -r '.version' "$CLAUDE_PLUGIN_JSON")"
  assert_json_eq "plugin name is signum" "$PLUGIN_JSON" '.name' "signum"
  assert_json_eq "plugin version matches release metadata" "$PLUGIN_JSON" '.version' "$ROOT_VERSION"
  assert_json_eq "plugin points at Codex skill overlay" "$PLUGIN_JSON" '.skills' "./platforms/codex/"
  assert_json_eq "plugin display name is Signum" "$PLUGIN_JSON" '.interface.displayName' "Signum"
  assert_json_eq "plugin category is Coding" "$PLUGIN_JSON" '.interface.category' "Coding"
fi

if [ -f "$CODEX_SKILL" ]; then
  assert_contains "Codex skill declares Signum name" "$CODEX_SKILL" "name: signum"
  assert_contains "Codex skill uses contract-first pipeline" "$CODEX_SKILL" "CONTRACT -> EXECUTE -> AUDIT -> PACK"
  assert_contains "Codex skill uses canonical artifact root" "$CODEX_SKILL" ".signum/contracts/<contractId>/"
  assert_contains "Codex skill treats external reviewers as optional" "$CODEX_SKILL" "optional evidence sources"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
