#!/usr/bin/env bash
# update-emporium-marketplace.sh -- sync Emporium marketplace entry to local Signum release metadata
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_JSON_PATH="${SIGNUM_PLUGIN_JSON_PATH:-$REPO_ROOT/.claude-plugin/plugin.json}"
EMPORIUM_MARKETPLACE_PATH="${EMPORIUM_MARKETPLACE_PATH:-}"

if [ ! -f "$PLUGIN_JSON_PATH" ]; then
  echo "ERROR: Signum plugin metadata not found: $PLUGIN_JSON_PATH" >&2
  exit 1
fi

if [ -z "$EMPORIUM_MARKETPLACE_PATH" ]; then
  echo "ERROR: EMPORIUM_MARKETPLACE_PATH is required." >&2
  exit 1
fi

if [ ! -f "$EMPORIUM_MARKETPLACE_PATH" ]; then
  echo "ERROR: Emporium marketplace file not found: $EMPORIUM_MARKETPLACE_PATH" >&2
  exit 1
fi

python3 - "$PLUGIN_JSON_PATH" "$EMPORIUM_MARKETPLACE_PATH" <<'PY'
import json
import sys
from pathlib import Path

plugin_path = Path(sys.argv[1])
marketplace_path = Path(sys.argv[2])

plugin = json.loads(plugin_path.read_text())
marketplace = json.loads(marketplace_path.read_text())

plugin_name = plugin.get("name")
plugin_version = plugin.get("version")
expected_ref = f"v{plugin_version}" if plugin_version else ""

if not plugin_name:
    raise SystemExit(f"ERROR: missing plugin name in {plugin_path}")
if not plugin_version:
    raise SystemExit(f"ERROR: missing plugin version in {plugin_path}")

plugins = marketplace.get("plugins")
if not isinstance(plugins, list):
    raise SystemExit(f"ERROR: invalid plugins array in {marketplace_path}")

entry = next((item for item in plugins if item.get("name") == plugin_name), None)
if entry is None:
    raise SystemExit(f"ERROR: Emporium marketplace entry for {plugin_name} not found in {marketplace_path}")

source = entry.get("source")
if source is None:
    source = {}
    entry["source"] = source
elif not isinstance(source, dict):
    raise SystemExit(f"ERROR: invalid source object for {plugin_name} in {marketplace_path}")

before_version = entry.get("version")
before_ref = source.get("ref")

changed = False
if before_version != plugin_version:
    entry["version"] = plugin_version
    changed = True
if before_ref != expected_ref:
    source["ref"] = expected_ref
    changed = True

if changed:
    marketplace_path.write_text(json.dumps(marketplace, indent=4, ensure_ascii=False) + "\n")
    print(f"UPDATED: {plugin_name} -> version {plugin_version}, ref {expected_ref}")
else:
    print(f"UNCHANGED: {plugin_name} already points to version {plugin_version}, ref {expected_ref}")
PY
