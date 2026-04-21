#!/usr/bin/env bash
set -euo pipefail

ROOT_CMD="/Users/vi/personal/heurema/signum/commands/signum.md"
OVERLAY_CMD="/Users/vi/personal/heurema/signum/platforms/claude-code/commands/signum.md"

extract_section() {
  local file="$1"
  local start="$2"
  local end="$3"
  awk -v start="$start" -v end="$end" '
    $0 ~ start { capture=1 }
    capture { print }
    $0 ~ end && capture { exit }
  ' "$file"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to not contain: $needle" >&2
    exit 1
  fi
}

ROOT_SNAPSHOT="$(extract_section "$ROOT_CMD" '^\\*\\*Capture pre-repair snapshot \\(receipt chain\\):\\*\\*$' '^\\*\\*Clear stale engineer artifacts before launching repair:\\*\\*$')"
ROOT_SEED="$(extract_section "$ROOT_CMD" '^\\*\\*Clear stale engineer artifacts before launching repair:\\*\\*$' '^\\*\\*Launch repair engineer \\(parallel lanes\\):\\*\\*$')"
OVERLAY_SEED="$(extract_section "$OVERLAY_CMD" '^\\*\\*Clear stale engineer artifacts before launching repair:\\*\\*$' '^\\*\\*Launch repair engineer \\(parallel lanes\\):\\*\\*$')"
OVERLAY_SNAPSHOT="$(extract_section "$OVERLAY_CMD" '^\\*\\*Capture pre-repair snapshot \\(receipt chain\\):\\*\\*$' '^If `WORKTREE_OK` is `false`')"

for label in ROOT_SNAPSHOT OVERLAY_SNAPSHOT; do
  section="${!label}"
  assert_contains "$section" 'ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"' "$label"
  assert_contains "$section" '--workspace-root "$PWD" --signum-dir "$ARTIFACT_ROOT"' "$label"
done

for label in ROOT_SEED OVERLAY_SEED; do
  section="${!label}"
  assert_contains "$section" 'COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"' "$label"
  assert_contains "$section" 'cp "$COMBINED_PATCH_PATH" "$_SEED_PATCH"' "$label"
  assert_not_contains "$section" '.signum/combined.patch' "$label"
done

echo "ok: repair snapshot and seed patch flow use canonical artifact-root paths"
