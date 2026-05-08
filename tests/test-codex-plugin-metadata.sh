#!/usr/bin/env bash
# test-codex-plugin-metadata.sh -- keep Codex App plugin metadata installable and aligned
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.codex-plugin/plugin.json"
MARKETPLACE_PLUGIN_JSON="$REPO_ROOT/platforms/codex/.codex-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.agents/plugins/marketplace.json"
CLAUDE_PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
CODEX_SKILL="$REPO_ROOT/platforms/codex/SKILL.md"
CODEX_ICON="$REPO_ROOT/platforms/codex/assets/signum-icon.png"

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
assert_file "Codex marketplace plugin manifest exists" "$MARKETPLACE_PLUGIN_JSON"
assert_file "Codex marketplace exists" "$MARKETPLACE_JSON"
assert_file "Codex skill entrypoint exists" "$CODEX_SKILL"
assert_file "Codex icon asset exists" "$CODEX_ICON"

if [ -f "$PLUGIN_JSON" ]; then
  jq empty "$PLUGIN_JSON"
  pass "Codex plugin manifest is valid JSON"

  ROOT_VERSION="$(jq -r '.version' "$CLAUDE_PLUGIN_JSON")"
  assert_json_eq "plugin name is signum" "$PLUGIN_JSON" '.name' "signum"
  assert_json_eq "plugin version matches release metadata" "$PLUGIN_JSON" '.version' "$ROOT_VERSION"
  assert_json_eq "plugin points at Codex skill overlay" "$PLUGIN_JSON" '.skills' "./platforms/codex/"
  assert_json_eq "plugin display name is Signum" "$PLUGIN_JSON" '.interface.displayName' "Signum"
  assert_json_eq "plugin category is Coding" "$PLUGIN_JSON" '.interface.category' "Coding"
  assert_json_eq "plugin composer icon points at Signum icon" "$PLUGIN_JSON" '.interface.composerIcon' "./platforms/codex/assets/signum-icon.png"
  assert_json_eq "plugin logo points at Signum icon" "$PLUGIN_JSON" '.interface.logo' "./platforms/codex/assets/signum-icon.png"
fi

if [ -f "$MARKETPLACE_PLUGIN_JSON" ]; then
  jq empty "$MARKETPLACE_PLUGIN_JSON"
  pass "Codex marketplace plugin manifest is valid JSON"

  ROOT_VERSION="$(jq -r '.version' "$CLAUDE_PLUGIN_JSON")"
  assert_json_eq "marketplace plugin name is signum" "$MARKETPLACE_PLUGIN_JSON" '.name' "signum"
  assert_json_eq "marketplace plugin version matches release metadata" "$MARKETPLACE_PLUGIN_JSON" '.version' "$ROOT_VERSION"
  assert_json_eq "marketplace plugin points at local Codex skill" "$MARKETPLACE_PLUGIN_JSON" '.skills' "./"
  assert_json_eq "marketplace plugin display name is Signum" "$MARKETPLACE_PLUGIN_JSON" '.interface.displayName' "Signum"
  assert_json_eq "marketplace plugin category is Coding" "$MARKETPLACE_PLUGIN_JSON" '.interface.category' "Coding"
  assert_json_eq "marketplace plugin composer icon points at local Signum icon" "$MARKETPLACE_PLUGIN_JSON" '.interface.composerIcon' "./assets/signum-icon.png"
  assert_json_eq "marketplace plugin logo points at local Signum icon" "$MARKETPLACE_PLUGIN_JSON" '.interface.logo' "./assets/signum-icon.png"
fi

if [ -f "$MARKETPLACE_JSON" ]; then
  jq empty "$MARKETPLACE_JSON"
  pass "Codex marketplace is valid JSON"

  assert_json_eq "marketplace name is heurema" "$MARKETPLACE_JSON" '.name' "heurema"
  assert_json_eq "marketplace display name is Heurema" "$MARKETPLACE_JSON" '.interface.displayName' "Heurema"
  assert_json_eq "marketplace logo points at Signum icon" "$MARKETPLACE_JSON" '.interface.logo' "./platforms/codex/assets/signum-icon.png"
  assert_json_eq "marketplace has one Signum plugin" "$MARKETPLACE_JSON" '[.plugins[] | select(.name == "signum")] | length' "1"
  assert_json_eq "marketplace plugin source is local" "$MARKETPLACE_JSON" '.plugins[] | select(.name == "signum") | .source.source' "local"
  assert_json_eq "marketplace plugin points at Codex platform root" "$MARKETPLACE_JSON" '.plugins[] | select(.name == "signum") | .source.path' "./platforms/codex"
  assert_json_eq "marketplace plugin path is non-empty" "$MARKETPLACE_JSON" '.plugins[] | select(.name == "signum") | (.source.path != "." and .source.path != "./" and .source.path != "")' "true"
  assert_json_eq "marketplace plugin install is available" "$MARKETPLACE_JSON" '.plugins[] | select(.name == "signum") | .policy.installation' "AVAILABLE"
  assert_json_eq "marketplace plugin auth is on install" "$MARKETPLACE_JSON" '.plugins[] | select(.name == "signum") | .policy.authentication' "ON_INSTALL"
  assert_json_eq "marketplace plugin category is Coding" "$MARKETPLACE_JSON" '.plugins[] | select(.name == "signum") | .category' "Coding"

  MARKETPLACE_PLUGIN_ROOT="$REPO_ROOT/$(jq -r '.plugins[] | select(.name == "signum") | .source.path' "$MARKETPLACE_JSON")"
  if [ -f "$MARKETPLACE_PLUGIN_ROOT/.codex-plugin/plugin.json" ]; then
    pass "marketplace plugin path resolves to Codex manifest"
  else
    fail "marketplace plugin path resolves to Codex manifest" "missing $MARKETPLACE_PLUGIN_ROOT/.codex-plugin/plugin.json"
  fi
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
