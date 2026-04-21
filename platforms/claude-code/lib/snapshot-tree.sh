#!/usr/bin/env bash
# snapshot-tree.sh -- deterministic workspace tree snapshot for Signum receipt chain.
# Writes a sorted manifest and JSON summary under the active Signum artifact root snapshots/ dir.
#
# Usage:
#   snapshot-tree.sh [label] [--workspace-root PATH] [--signum-dir PATH]
#
# Example:
#   lib/snapshot-tree.sh execute-attempt-01
#   ARTIFACT_ROOT=".signum/contracts/<contractId>"
#   lib/snapshot-tree.sh lane-A --workspace-root "$ARTIFACT_ROOT/iterations/01/lanes/A" \
#       --signum-dir "$ARTIFACT_ROOT"
set -euo pipefail
export LC_ALL=C

LABEL="${1:-pre-execute}"
if [[ "$LABEL" == --* ]]; then
  LABEL="pre-execute"
else
  shift || true
fi

WORKSPACE_ROOT="${PWD}"
SIGNUM_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root)
      WORKSPACE_ROOT="$2"
      shift 2
      ;;
    --signum-dir)
      SIGNUM_DIR="$2"
      shift 2
      ;;
    *)
      echo "snapshot-tree.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$LABEL" ]]; then
  echo "snapshot-tree.sh: label is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "snapshot-tree.sh: jq not found" >&2
  exit 1
fi

resolve_default_signum_dir() {
  local workspace_root="$1"
  local index_path="$workspace_root/.signum/contracts/index.json"
  local active_id=""
  local contracts_root="$workspace_root/.signum/contracts"
  local dir_count=""
  local only_dir=""

  if [[ -f "$index_path" ]]; then
    active_id="$(jq -r '.activeContractId // empty' "$index_path" 2>/dev/null || true)"
    if [[ -n "$active_id" && -d "$workspace_root/.signum/contracts/$active_id" ]]; then
      printf '%s\n' "$workspace_root/.signum/contracts/$active_id"
      return 0
    fi
  fi

  if [[ -d "$contracts_root" ]]; then
    dir_count=$(find "$contracts_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "$dir_count" == "1" ]]; then
      only_dir=$(find "$contracts_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
      if [[ -n "$only_dir" && -d "$only_dir" ]]; then
        printf '%s\n' "$only_dir"
        return 0
      fi
    fi
  fi

  printf '%s\n' "$workspace_root/.signum"
}

hash_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "snapshot-tree.sh: no sha256 tool found" >&2
    exit 1
  fi
}

list_files_null() {
  if git -C "$WORKSPACE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$WORKSPACE_ROOT" ls-files -z --cached --others --exclude-standard -- .
  else
    local signum_name
    signum_name=$(basename "$SIGNUM_DIR")
    (
      CDPATH= cd "$WORKSPACE_ROOT"
      find . \
        -path './.git' -prune -o \
        -path "./${signum_name}" -prune -o \
        -type f -print0
    )
  fi
}

ABS_WORKSPACE=$(CDPATH= cd "$WORKSPACE_ROOT" && pwd)
if [[ -z "$SIGNUM_DIR" ]]; then
  SIGNUM_DIR="$(resolve_default_signum_dir "$ABS_WORKSPACE")"
fi
if [[ "$SIGNUM_DIR" = /* ]]; then
  ABS_SIGNUM_DIR="$SIGNUM_DIR"
else
  ABS_SIGNUM_DIR="$ABS_WORKSPACE/$SIGNUM_DIR"
fi
SNAPSHOT_DIR="$ABS_SIGNUM_DIR/snapshots"
mkdir -p "$SNAPSHOT_DIR"

MANIFEST_PATH="$SNAPSHOT_DIR/${LABEL}.manifest"
SUMMARY_PATH="$SNAPSHOT_DIR/${LABEL}.json"
TMP_MANIFEST=$(mktemp)
trap 'rm -f "$TMP_MANIFEST"' EXIT

while IFS= read -r -d '' rel_path; do
  [[ -z "$rel_path" ]] && continue
  rel_path="${rel_path#./}"
  [[ -z "$rel_path" ]] && continue
  [[ -f "$ABS_WORKSPACE/$rel_path" ]] || continue
  file_hash=$(hash_file "$ABS_WORKSPACE/$rel_path")
  printf '%s\tsha256:%s\n' "$rel_path" "$file_hash" >> "$TMP_MANIFEST"
done < <(list_files_null)

sort "$TMP_MANIFEST" > "$MANIFEST_PATH"
TREE_HASH="sha256:$(hash_file "$MANIFEST_PATH")"
FILE_COUNT=$(wc -l < "$MANIFEST_PATH" | tr -d '[:space:]')
CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg snapshot_type "workspace_tree" \
  --arg label "$LABEL" \
  --arg workspace_root "$ABS_WORKSPACE" \
  --arg signum_dir "$ABS_SIGNUM_DIR" \
  --arg manifest_path "$MANIFEST_PATH" \
  --arg tree_hash "$TREE_HASH" \
  --arg captured_at "$CAPTURED_AT" \
  --argjson file_count "$FILE_COUNT" \
  '{
    snapshot_type: $snapshot_type,
    label: $label,
    workspace_root: $workspace_root,
    signum_dir: $signum_dir,
    manifest_path: $manifest_path,
    tree_hash: $tree_hash,
    file_count: $file_count,
    captured_at: $captured_at
  }' > "$SUMMARY_PATH"

echo "$SUMMARY_PATH"
