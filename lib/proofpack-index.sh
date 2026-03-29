#!/usr/bin/env bash
# proofpack-index.sh -- append-only hash-linked proofpack index
# Each entry references the previous entry's hash, creating a tamper-evident chain.
# This is the signum equivalent of specpunk's receipts/index.jsonl.
#
# Usage:
#   source lib/proofpack-index.sh
#   proofpack_index_append .signum/proofpack.json    # append after PACK
#   proofpack_index_verify                            # verify chain integrity
#   proofpack_index_query --since 7d                  # query recent entries
#
# Storage: .signum/proofpack-index.jsonl (one JSON object per line)

set -euo pipefail

INDEX_FILE="${SIGNUM_INDEX_FILE:-.signum/proofpack-index.jsonl}"

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

  if [ ! -f "$pp_path" ]; then
    echo "ERROR: proofpack not found: $pp_path" >&2
    return 1
  fi

  # Get previous chain hash (last line of index)
  local prev_hash="genesis"
  if [ -f "$INDEX_FILE" ]; then
    prev_hash=$(tail -1 "$INDEX_FILE" | jq -r '.chain_hash // "genesis"' 2>/dev/null || echo "genesis")
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
  echo "$entry" >> "$INDEX_FILE"
}

# Verify chain integrity
proofpack_index_verify() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "No index file found"
    return 0
  fi

  python3 - "$INDEX_FILE" <<'PYEOF'
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
  if [ ! -f "$INDEX_FILE" ]; then
    echo "[]"
    return 0
  fi

  local mode="${1:---last}"
  local value="${2:-10}"

  case "$mode" in
    --since)
      local cutoff
      cutoff=$(date -v-${value} +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "${value} ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      jq -sc --arg cutoff "$cutoff" '[.[] | select(.createdAt >= $cutoff)]' "$INDEX_FILE" 2>/dev/null
      ;;
    --last)
      tail -"$value" "$INDEX_FILE" | jq -sc '.' 2>/dev/null
      ;;
    *)
      echo "Usage: proofpack_index_query --since 7d | --last 10" >&2
      return 1
      ;;
  esac
}
