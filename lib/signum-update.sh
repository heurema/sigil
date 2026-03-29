#!/usr/bin/env bash
# signum-update.sh — reliable plugin update across all scopes and profiles
#
# Workaround for Claude Code bugs:
#   #29071: plugin update doesn't fast-forward marketplace clone
#   #14061: plugin cache not invalidated on update
#   #15642: CLAUDE_PLUGIN_ROOT points to stale cache
#
# Usage: lib/signum-update.sh [version]
#   version defaults to .claude-plugin/plugin.json version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-$(jq -r .version "$PLUGIN_ROOT/.claude-plugin/plugin.json")}"
PLUGIN_NAME="signum"
MARKETPLACE="emporium"

echo "Updating $PLUGIN_NAME to v$VERSION..."
echo ""

# ---------------------------------------------------------------------------
# Step 0: Safety checks
# ---------------------------------------------------------------------------
if pgrep -qf "claude.*code" 2>/dev/null || pgrep -qf "claude-code" 2>/dev/null; then
  echo "WARNING: Claude Code appears to be running."
  echo "  Changes will only take effect after restart."
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 1: Fast-forward ALL marketplace clones (fix for #29071)
# ---------------------------------------------------------------------------
echo "Step 1: Updating marketplace clones..."
UPDATED_MPS=0
for mp_dir in \
  "$HOME/.claude/plugins/marketplaces/$MARKETPLACE" \
  "$HOME/.claude-profiles"/*/config/plugins/marketplaces/"$MARKETPLACE"; do
  [ -d "$mp_dir/.git" ] || continue

  CURRENT_REF=$(cd "$mp_dir" && jq -r ".plugins[] | select(.name==\"$PLUGIN_NAME\") | .source.ref // empty" .claude-plugin/marketplace.json 2>/dev/null || true)

  (cd "$mp_dir" && git fetch origin --quiet && git reset --hard origin/main --quiet) 2>/dev/null || {
    echo "  WARN: failed to update $mp_dir"
    continue
  }

  NEW_REF=$(cd "$mp_dir" && jq -r ".plugins[] | select(.name==\"$PLUGIN_NAME\") | .source.ref // empty" .claude-plugin/marketplace.json 2>/dev/null || true)
  echo "  $mp_dir"
  echo "    ref: ${CURRENT_REF:-unset} → ${NEW_REF:-unset}"
  UPDATED_MPS=$((UPDATED_MPS + 1))
done
echo "  Updated $UPDATED_MPS marketplace(s)"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Uninstall BEFORE clearing cache (Gemini review: uninstall needs cache)
# ---------------------------------------------------------------------------
echo "Step 2: CLI uninstall (before cache clear)..."
claude plugin uninstall "$PLUGIN_NAME@$MARKETPLACE" --scope user 2>/dev/null || true

# Also clean up orphan entries from other marketplaces (e.g., signum@nex-devtools)
for settings_file in \
  "$HOME/.claude/settings.json" \
  "$HOME/.claude-profiles"/*/config/settings.json; do
  [ -f "$settings_file" ] || continue
  # Find signum entries NOT from our target marketplace
  ORPHANS=$(python3 - "$settings_file" "$PLUGIN_NAME" "$MARKETPLACE" <<'PYEOF' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
plugins = s.get('enabledPlugins', {})
target = sys.argv[2] + '@' + sys.argv[3]
orphans = [k for k in plugins if k.startswith(sys.argv[2] + '@') and k != target]
for o in orphans: print(o)
PYEOF
)

  if [ -n "$ORPHANS" ]; then
    for orphan in $ORPHANS; do
      echo "  Removing orphan: $orphan from $settings_file"
      python3 - "$settings_file" "$orphan" <<'PYEOF' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
s.get('enabledPlugins', {}).pop(sys.argv[2], None)
with open(sys.argv[1], 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
PYEOF
    done
  fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 3: Clear ALL stale caches (fix for #14061)
# ---------------------------------------------------------------------------
echo "Step 3: Clearing stale caches..."
CLEARED=0
for cache_dir in \
  "$HOME/.claude/plugins/cache"/*/"$PLUGIN_NAME" \
  "$HOME/.claude-profiles"/*/config/plugins/cache/*/"$PLUGIN_NAME"; do
  [ -d "$cache_dir" ] || continue

  VERSIONS=$(ls "$cache_dir/" 2>/dev/null | tr '\n' ' ')
  echo "  Removing: $cache_dir ($VERSIONS)"
  rm -rf "$cache_dir"
  CLEARED=$((CLEARED + 1))
done
echo "  Cleared $CLEARED cache(s)"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Sync fresh copy from source to ALL profile caches
# ---------------------------------------------------------------------------
echo "Step 4: Syncing v$VERSION to profile caches..."
SYNCED=0
for profile_dir in "$HOME/.claude-profiles"/*/config; do
  [ -d "$profile_dir" ] || continue

  PROFILE_NAME=$(basename "$(dirname "$profile_dir")")
  TARGET="$profile_dir/plugins/cache/$MARKETPLACE/$PLUGIN_NAME/$VERSION"
  mkdir -p "$TARGET"

  for dir in .claude-plugin agents commands lib platforms docs tests skills; do
    [ -d "$PLUGIN_ROOT/$dir" ] && cp -R "$PLUGIN_ROOT/$dir" "$TARGET/"
  done
  for file in README.md CHANGELOG.md QUICKSTART.md SKILL.md; do
    [ -f "$PLUGIN_ROOT/$file" ] && cp "$PLUGIN_ROOT/$file" "$TARGET/"
  done

  CACHED_VER=$(jq -r '.version' "$TARGET/.claude-plugin/plugin.json" 2>/dev/null || echo "FAILED")
  if [ "$CACHED_VER" = "$VERSION" ]; then
    echo "  profile=$PROFILE_NAME → $TARGET (OK)"
    SYNCED=$((SYNCED + 1))
  else
    echo "  profile=$PROFILE_NAME → FAILED (version mismatch: $CACHED_VER)"
  fi
done
echo "  Synced to $SYNCED profile(s)"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Reinstall via CLI (cache is clean, marketplace is fresh)
# ---------------------------------------------------------------------------
echo "Step 5: CLI reinstall..."
claude plugin install "$PLUGIN_NAME@$MARKETPLACE" --scope user 2>&1 || true
echo ""

# ---------------------------------------------------------------------------
# Step 6: Verify
# ---------------------------------------------------------------------------
echo "Step 6: Verification..."

ERRORS=0

# Check marketplace refs
for mp_dir in \
  "$HOME/.claude/plugins/marketplaces/$MARKETPLACE" \
  "$HOME/.claude-profiles"/*/config/plugins/marketplaces/"$MARKETPLACE"; do
  [ -f "$mp_dir/.claude-plugin/marketplace.json" ] || continue
  REF=$(jq -r ".plugins[] | select(.name==\"$PLUGIN_NAME\") | .source.ref // empty" "$mp_dir/.claude-plugin/marketplace.json" 2>/dev/null)
  if [ "$REF" = "v$VERSION" ]; then
    echo "  marketplace $mp_dir: v$VERSION OK"
  else
    echo "  marketplace $mp_dir: MISMATCH (expected v$VERSION, got $REF)"
    ERRORS=$((ERRORS + 1))
  fi
done

# Check profile caches
for profile_dir in "$HOME/.claude-profiles"/*/config; do
  [ -d "$profile_dir" ] || continue
  PROFILE_NAME=$(basename "$(dirname "$profile_dir")")
  CACHED="$profile_dir/plugins/cache/$MARKETPLACE/$PLUGIN_NAME/$VERSION"
  if [ -d "$CACHED" ]; then
    CMDS=$(ls "$CACHED/commands/" 2>/dev/null | tr '\n' ' ')
    echo "  profile=$PROFILE_NAME cache: v$VERSION OK (commands: $CMDS)"
  else
    echo "  profile=$PROFILE_NAME cache: MISSING"
    ERRORS=$((ERRORS + 1))
  fi
done

# Check no orphan settings entries remain
for settings_file in \
  "$HOME/.claude/settings.json" \
  "$HOME/.claude-profiles"/*/config/settings.json; do
  [ -f "$settings_file" ] || continue
  ORPHAN_COUNT=$(python3 - "$settings_file" "$PLUGIN_NAME" "$MARKETPLACE" <<'PYEOF' 2>/dev/null || echo 0
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
plugins = s.get('enabledPlugins', {})
target = sys.argv[2] + '@' + sys.argv[3]
orphans = [k for k in plugins if k.startswith(sys.argv[2] + '@') and k != target]
print(len(orphans))
PYEOF
)
  if [ "$ORPHAN_COUNT" -gt 0 ]; then
    echo "  WARN: $ORPHAN_COUNT orphan entries in $settings_file"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
if [ $ERRORS -eq 0 ]; then
  echo "All checks passed. Restart Claude Code to apply v$VERSION."
else
  echo "WARN: $ERRORS check(s) failed. Manual review needed."
fi
