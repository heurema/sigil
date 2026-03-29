#!/usr/bin/env bash
# sync-cache.sh — sync current plugin to emporium cache
# Usage: lib/sync-cache.sh
# Ensures subagents use the latest version of agents/commands/schemas.

set -euo pipefail

PLUGIN_VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
if [[ -z "$PLUGIN_VERSION" || "$PLUGIN_VERSION" == "null" || "$PLUGIN_VERSION" =~ [/\\] || "$PLUGIN_VERSION" == *..* || "$PLUGIN_VERSION" == "." ]]; then
  echo "ERROR: invalid version from .claude-plugin/plugin.json: $PLUGIN_VERSION" >&2
  exit 1
fi
CACHE_BASE="${HOME}/.claude-profiles/work/config/plugins/cache/emporium/signum"
CACHE_DIR="${CACHE_BASE}/${PLUGIN_VERSION}"

if [ -d "$CACHE_DIR" ]; then
  echo "Cache $PLUGIN_VERSION already exists — updating in place"
  rm -rf "$CACHE_DIR"
fi

mkdir -p "$CACHE_DIR"

# Copy essential plugin structure
for dir in .claude-plugin agents commands lib platforms docs tests skills; do
  [ -d "$dir" ] && cp -R "$dir" "$CACHE_DIR/"
done

for file in README.md CHANGELOG.md QUICKSTART.md SKILL.md; do
  [ -f "$file" ] && cp "$file" "$CACHE_DIR/"
done

# Verify
CACHED_VER=$(jq -r '.version' "$CACHE_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo "FAILED")
if [ "$CACHED_VER" = "$PLUGIN_VERSION" ]; then
  echo "Synced: signum v${PLUGIN_VERSION} → ${CACHE_DIR}"
else
  echo "ERROR: version mismatch after sync (expected $PLUGIN_VERSION, got $CACHED_VER)" >&2
  exit 1
fi
