#!/usr/bin/env bash
# proofpack-index.sh -- append-only hash-linked proofpack index
# Each entry references the previous entry's hash, creating a tamper-evident chain.
# This is the signum equivalent of specpunk's receipts/index.jsonl.
#
# Usage:
#   source lib/proofpack-index.sh
#   proofpack_index_append .signum/contracts/<contractId>/proofpack.json  # append after PACK
#   proofpack_index_verify                            # verify chain integrity
#   proofpack_index_query --since 7d                  # query recent entries
#
# Storage: project-level .signum/proofpack-index.jsonl (one JSON object per line)

set -euo pipefail

INDEX_FILE="${SIGNUM_INDEX_FILE:-}"

_proofpack_index_project_root_from_path() {
  local input_path="${1:-}"
  local abs_path=""

  if [[ -z "$input_path" ]]; then
    return 1
  fi

  if [[ "$input_path" = /* ]]; then
    abs_path="${input_path%/}"
  else
    abs_path="${PWD}/${input_path}"
    abs_path="${abs_path%/}"
  fi

  case "$abs_path" in
    */.signum/contracts/*/proofpack.json)
      printf '%s\n' "${abs_path%/.signum/contracts/*/proofpack.json}"
      return 0
      ;;
    */.signum/contracts/*)
      printf '%s\n' "${abs_path%/.signum/contracts/*}"
      return 0
      ;;
    */.signum/proofpack.json)
      printf '%s\n' "${abs_path%/.signum/proofpack.json}"
      return 0
      ;;
    */.signum)
      printf '%s\n' "${abs_path%/.signum}"
      return 0
      ;;
  esac

  return 1
}

_proofpack_index_default_file() {
  local pp_path="${1:-}"
  local base_root="${SIGNUM_PROJECT_ROOT:-}"
  local abs_pp=""
  local inferred_root=""

  if [[ -n "$INDEX_FILE" ]]; then
    if [[ "$INDEX_FILE" = /* ]]; then
      printf '%s\n' "$INDEX_FILE"
    else
      if [[ -z "$base_root" ]]; then
        base_root="$(_proofpack_index_project_root_from_path "$PWD" 2>/dev/null || printf '%s\n' "$PWD")"
      fi
      printf '%s/%s\n' "$base_root" "$INDEX_FILE"
    fi
    return 0
  fi

  if [[ -n "$pp_path" ]]; then
    if [[ "$pp_path" = /* ]]; then
      abs_pp="$pp_path"
    else
      abs_pp="$PWD/$pp_path"
    fi

    inferred_root="$(_proofpack_index_project_root_from_path "$abs_pp" 2>/dev/null || true)"
    if [[ -n "$inferred_root" ]]; then
      printf '%s/.signum/proofpack-index.jsonl\n' "$inferred_root"
      return 0
    fi

    case "$abs_pp" in
      */.signum/contracts/*/proofpack.json)
        printf '%s/.signum/proofpack-index.jsonl\n' "${abs_pp%/.signum/contracts/*/proofpack.json}"
        return 0
        ;;
      */.signum/proofpack.json)
        printf '%s/.signum/proofpack-index.jsonl\n' "${abs_pp%/.signum/proofpack.json}"
        return 0
        ;;
    esac
  fi

  if [[ -z "$base_root" ]]; then
    base_root="$(_proofpack_index_project_root_from_path "$PWD" 2>/dev/null || printf '%s\n' "$PWD")"
  fi

  printf '%s/.signum/proofpack-index.jsonl\n' "$base_root"
}

# Cross-platform sha256
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "ERROR: no sha256 tool found" >&2
    return 1
  fi
}

# Append proofpack to index with hash chain
# Args: proofpack_path
proofpack_index_append() {
  local pp_path="${1:?proofpack path required}"
  local index_file=""

  if [ ! -f "$pp_path" ]; then
    echo "ERROR: proofpack not found: $pp_path" >&2
    return 1
  fi

  index_file="$(_proofpack_index_default_file "$pp_path")"
  mkdir -p "$(dirname "$index_file")"

  # Get previous chain hash (last line of index)
  local prev_hash="genesis"
  if [ -f "$index_file" ]; then
    prev_hash=$(tail -1 "$index_file" | jq -r '.chain_hash // "genesis"' 2>/dev/null || echo "genesis")
  fi

  # Extract key fields from proofpack
  local entry
  entry=$(jq -c --arg prev "$prev_hash" '{
    runId: .runId,
    contractId: (.contractId // null),
    createdAt: .createdAt,
    decision: .decision,
    releaseVerdict: (.releaseVerdict // "HOLD"),
    riskLevel: (.riskLevel // "low"),
    confidence: (.confidence.overall // 0),
    reviewCoverage: (.reviewCoverage.availableReviews // 0),
    schemaVersion: .schemaVersion,
    summary: (.summary // ""),
    proofpack_sha256: null,
    prev_hash: $prev,
    chain_hash: null
  }' "$pp_path" 2>/dev/null)

  if [ -z "$entry" ] || [ "$entry" = "null" ]; then
    echo "ERROR: failed to parse proofpack" >&2
    return 1
  fi

  # Compute proofpack hash
  local pp_hash
  pp_hash=$(cat "$pp_path" | _sha256)

  # Compute chain hash: sha256(prev_hash + proofpack_hash)
  local chain_hash
  chain_hash=$(printf '%s%s' "$prev_hash" "$pp_hash" | _sha256)

  # Finalize entry with hashes
  entry=$(echo "$entry" | jq -c --arg pph "$pp_hash" --arg ch "$chain_hash" \
    '.proofpack_sha256 = $pph | .chain_hash = $ch')

  # Atomic append
  echo "$entry" >> "$index_file"
}

# Verify chain integrity
proofpack_index_verify() {
  local index_file=""
  index_file="$(_proofpack_index_default_file)"

  if [ ! -f "$index_file" ]; then
    echo "No index file found"
    return 0
  fi

  python3 - "$index_file" <<'PYEOF'
import json, hashlib, sys

prev_hash = 'genesis'
line_num = 0
errors = 0

for line in open(sys.argv[1]):
    line_num += 1
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        print(f'ERROR line {line_num}: invalid JSON')
        errors += 1
        continue

    if entry.get('prev_hash') != prev_hash:
        print(f'ERROR line {line_num}: prev_hash mismatch (expected {prev_hash[:16]}..., got {entry.get("prev_hash", "missing")[:16]}...)')
        errors += 1

    # Verify chain_hash = sha256(prev_hash + proofpack_sha256)
    expected_chain = hashlib.sha256((prev_hash + entry.get('proofpack_sha256', '')).encode()).hexdigest()
    if entry.get('chain_hash') != expected_chain:
        print(f'ERROR line {line_num}: chain_hash mismatch')
        errors += 1

    prev_hash = entry.get('chain_hash', prev_hash)

if errors == 0:
    print(f'OK: {line_num} entries, chain intact')
else:
    print(f'FAILED: {errors} errors in {line_num} entries')
    sys.exit(1)
PYEOF
}

# Query recent entries
# Args: --since Nd (days) or --last N (entries)
proofpack_index_query() {
  local index_file=""
  index_file="$(_proofpack_index_default_file)"

  if [ ! -f "$index_file" ]; then
    echo "[]"
    return 0
  fi

  local mode="${1:---last}"
  local value="${2:-10}"

  case "$mode" in
    --since)
      local cutoff
      cutoff=$(date -u -v-${value} +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${value} ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      jq -sc --arg cutoff "$cutoff" '[.[] | select(.createdAt >= $cutoff)]' "$index_file" 2>/dev/null
      ;;
    --last)
      tail -"$value" "$index_file" | jq -sc '.' 2>/dev/null
      ;;
    *)
      echo "Usage: proofpack_index_query --since 7d | --last 10" >&2
      return 1
      ;;
  esac
}
