#!/usr/bin/env bash
# check-emporium-sync.sh -- fail loudly when Signum release metadata drifts from Emporium
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_JSON_PATH="${SIGNUM_PLUGIN_JSON_PATH:-$REPO_ROOT/.claude-plugin/plugin.json}"
EMPORIUM_REPO="${EMPORIUM_REPO:-heurema/emporium}"
EMPORIUM_GIT_REF="${EMPORIUM_GIT_REF:-main}"
EMPORIUM_PATH="${EMPORIUM_PATH:-.claude-plugin/marketplace.json}"
EMPORIUM_MARKETPLACE_PATH="${EMPORIUM_MARKETPLACE_PATH:-}"
EMPORIUM_MARKETPLACE_URL="${EMPORIUM_MARKETPLACE_URL:-https://raw.githubusercontent.com/${EMPORIUM_REPO}/${EMPORIUM_GIT_REF}/${EMPORIUM_PATH}}"

if [ ! -f "$PLUGIN_JSON_PATH" ]; then
  echo "ERROR: Signum plugin metadata not found: $PLUGIN_JSON_PATH" >&2
  exit 1
fi

PLUGIN_NAME="$(jq -r '.name // empty' "$PLUGIN_JSON_PATH")"
LOCAL_VERSION="$(jq -r '.version // empty' "$PLUGIN_JSON_PATH")"

if [ -z "$PLUGIN_NAME" ] || [ "$PLUGIN_NAME" = "null" ]; then
  echo "ERROR: missing plugin name in $PLUGIN_JSON_PATH" >&2
  exit 1
fi

if [ -z "$LOCAL_VERSION" ] || [ "$LOCAL_VERSION" = "null" ]; then
  echo "ERROR: missing plugin version in $PLUGIN_JSON_PATH" >&2
  exit 1
fi

EXPECTED_REF="v$LOCAL_VERSION"

TMP_MARKETPLACE="$(mktemp)"
trap 'rm -f "$TMP_MARKETPLACE"' EXIT

if [ -n "$EMPORIUM_MARKETPLACE_PATH" ]; then
  if [ ! -f "$EMPORIUM_MARKETPLACE_PATH" ]; then
    echo "ERROR: Emporium marketplace file not found: $EMPORIUM_MARKETPLACE_PATH" >&2
    exit 1
  fi
  cp "$EMPORIUM_MARKETPLACE_PATH" "$TMP_MARKETPLACE"
else
  python3 - "$EMPORIUM_MARKETPLACE_URL" "$TMP_MARKETPLACE" <<'PY'
import sys
import urllib.request

url, out_path = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=20) as response:
    body = response.read()
with open(out_path, "wb") as handle:
    handle.write(body)
PY
fi

ENTRY_JSON="$(jq -c --arg name "$PLUGIN_NAME" '.plugins[]? | select(.name == $name)' "$TMP_MARKETPLACE")"

if [ -z "$ENTRY_JSON" ]; then
  echo "ERROR: Emporium marketplace entry for $PLUGIN_NAME not found." >&2
  echo "Update ${EMPORIUM_REPO}/${EMPORIUM_PATH} at ref ${EMPORIUM_GIT_REF} before shipping this release." >&2
  exit 1
fi

EMPORIUM_VERSION="$(printf '%s\n' "$ENTRY_JSON" | jq -r '.version // empty')"
EMPORIUM_ENTRY_REF="$(printf '%s\n' "$ENTRY_JSON" | jq -r '.source.ref // empty')"

echo "Local $PLUGIN_NAME version: $LOCAL_VERSION"
echo "Emporium source repo: $EMPORIUM_REPO"
echo "Emporium source git ref: $EMPORIUM_GIT_REF"
echo "Emporium source path: $EMPORIUM_PATH"
echo "Emporium $PLUGIN_NAME version: ${EMPORIUM_VERSION:-missing}"
echo "Emporium $PLUGIN_NAME ref: ${EMPORIUM_ENTRY_REF:-missing}"

if [ "$EMPORIUM_VERSION" != "$LOCAL_VERSION" ] || [ "$EMPORIUM_ENTRY_REF" != "$EXPECTED_REF" ]; then
  echo "ERROR: Emporium drift detected for $PLUGIN_NAME." >&2
  echo "  Expected version: $LOCAL_VERSION" >&2
  echo "  Expected ref:     $EXPECTED_REF" >&2
  echo "  Emporium version: ${EMPORIUM_VERSION:-missing}" >&2
  echo "  Emporium ref:     ${EMPORIUM_ENTRY_REF:-missing}" >&2
  echo "Update ${EMPORIUM_REPO}/${EMPORIUM_PATH} at ref ${EMPORIUM_GIT_REF} before shipping this release." >&2
  exit 1
fi

echo "OK: Emporium entry matches local Signum release metadata."
