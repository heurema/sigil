#!/usr/bin/env bash
# staleness-check.sh -- recompute SHA-256 over staleIfChanged files and compare to stored hash
# Usage: staleness-check.sh <contract.json> --project-root <dir>
# Output: {"check":"staleness","status":"fresh|warn|block|skip|error","summary":"...",
#          "current_hash":"...","stored_hash":"...","missing_files":[],"findings":[]}
# NOTE: This script does NOT mutate contract.json.
#       The orchestrator applies the mutation based on the returned status.
# Exit 0: check completed (any status including block)
# Exit 1: infra error (bad args, missing jq, path traversal rejected)

set -euo pipefail

CONTRACT=""
PROJECT_ROOT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    -*) echo "{\"check\":\"staleness\",\"status\":\"error\",\"summary\":\"Unknown flag: $1\",\"current_hash\":\"\",\"stored_hash\":\"\",\"missing_files\":[],\"findings\":[]}" >&2; exit 1 ;;
    *) CONTRACT="$1"; shift ;;
  esac
done

if [ -z "$CONTRACT" ]; then
  echo '{"check":"staleness","status":"error","summary":"Usage: staleness-check.sh <contract.json> --project-root <dir>","current_hash":"","stored_hash":"","missing_files":[],"findings":[]}' >&2
  exit 1
fi

if [ ! -f "$CONTRACT" ]; then
  echo "{\"check\":\"staleness\",\"status\":\"error\",\"summary\":\"File not found: $CONTRACT\",\"current_hash\":\"\",\"stored_hash\":\"\",\"missing_files\":[],\"findings\":[]}" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo '{"check":"staleness","status":"error","summary":"jq not found","current_hash":"","stored_hash":"","missing_files":[],"findings":[]}' >&2
  exit 1
fi

ROOT="${PROJECT_ROOT:-$PWD}"

STALE_COUNT=$(jq '(.contextInheritance.staleIfChanged // []) | length' "$CONTRACT" 2>/dev/null || echo 0)
STALE_FILES=$(jq -r '(.contextInheritance.staleIfChanged // []) | .[]' "$CONTRACT" 2>/dev/null || true)

if [ "$STALE_COUNT" -eq 0 ] || [ -z "$STALE_FILES" ]; then
  echo "upstream_staleness_check: skipped (staleIfChanged is absent or empty)" >&2
  echo '{"check":"staleness","status":"skip","summary":"staleIfChanged is absent or empty","current_hash":"","stored_hash":"","missing_files":[],"findings":[]}'
  exit 0
fi

STORED_HASH=$(jq -r '.contextInheritance.contextSnapshotHash // ""' "$CONTRACT")
STALENESS_POLICY=$(jq -r '.contextInheritance.stalenessPolicy // "warn"' "$CONTRACT")

if [ -z "$STORED_HASH" ]; then
  echo "upstream_staleness_check: skipped (contextSnapshotHash not set)" >&2
  echo '{"check":"staleness","status":"skip","summary":"contextSnapshotHash not set","current_hash":"","stored_hash":"","missing_files":[],"findings":[]}'
  exit 0
fi

TMPFILE=$(mktemp "${TMPDIR:-/tmp}/signum-staleness.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

MISSING_FILES_ARR="[]"
TRAVERSAL_REJECTED=""

while IFS= read -r sf; do
  [ -z "$sf" ] && continue
  # Reject path traversal
  case "$sf" in
    *../*|../*|*/..)
      TRAVERSAL_REJECTED="$TRAVERSAL_REJECTED $sf"
      continue
      ;;
  esac
  RESOLVED_PATH="$ROOT/$sf"
  if [ -f "$RESOLVED_PATH" ]; then
    printf '%s\0' "$sf" >> "$TMPFILE"
    cat "$RESOLVED_PATH" >> "$TMPFILE"
  else
    MISSING_FILES_ARR=$(echo "$MISSING_FILES_ARR" | jq --arg f "$sf" '. + [$f]')
  fi
done <<< "$STALE_FILES"

if [ -n "$TRAVERSAL_REJECTED" ]; then
  echo "upstream_staleness_check: BLOCK — path traversal rejected:$TRAVERSAL_REJECTED" >&2
  echo "{\"check\":\"staleness\",\"status\":\"error\",\"summary\":\"Path traversal rejected: $TRAVERSAL_REJECTED\",\"current_hash\":\"\",\"stored_hash\":\"$STORED_HASH\",\"missing_files\":[],\"findings\":[]}"
  exit 1
fi

MISSING_COUNT=$(echo "$MISSING_FILES_ARR" | jq 'length')

if [ "$MISSING_COUNT" -gt 0 ]; then
  echo "upstream_staleness_check: missing upstream files" >&2
  echo "$MISSING_FILES_ARR" | jq -r '.[] | "  missing: " + .' >&2

  if [ "$STALENESS_POLICY" = "block" ]; then
    NEW_STATUS="block"
    SUMMARY="Upstream files missing and stalenessPolicy=block"
    echo "BLOCK: upstream files missing and stalenessPolicy=block." >&2
  else
    NEW_STATUS="warn"
    SUMMARY="Upstream files missing (stalenessPolicy=warn)"
    echo "WARN: upstream files missing (stalenessPolicy=warn)." >&2
  fi

  jq -n \
    --arg status "$NEW_STATUS" \
    --arg summary "$SUMMARY" \
    --arg stored "$STORED_HASH" \
    --argjson missing "$MISSING_FILES_ARR" \
    '{check:"staleness",status:$status,summary:$summary,current_hash:"",stored_hash:$stored,missing_files:$missing,findings:[]}'
  exit 0
fi

# Compute SHA-256 of concatenated content
if command -v sha256sum > /dev/null 2>&1; then
  CURRENT_HASH=$(sha256sum "$TMPFILE" | awk '{print $1}')
elif command -v shasum > /dev/null 2>&1; then
  CURRENT_HASH=$(shasum -a 256 "$TMPFILE" | awk '{print $1}')
else
  echo '{"check":"staleness","status":"error","summary":"No sha256 tool found (need sha256sum or shasum)","current_hash":"","stored_hash":"","missing_files":[],"findings":[]}' >&2
  exit 1
fi

if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
  echo "upstream_staleness_check: fresh (hash matches: ${STORED_HASH:0:16}...)" >&2
  NEW_STATUS="fresh"
  SUMMARY="Hash matches — upstream context is fresh"
else
  echo "upstream_staleness_check: hash mismatch" >&2
  echo "  stored:  $STORED_HASH" >&2
  echo "  current: $CURRENT_HASH" >&2
  echo "  staleIfChanged files: $(echo "$STALE_FILES" | tr '\n' ' ')" >&2

  if [ "$STALENESS_POLICY" = "block" ]; then
    NEW_STATUS="block"
    SUMMARY="Upstream artifacts changed since contract was created (stalenessPolicy=block)"
    echo "BLOCK: upstream artifacts have changed since contract was created (stalenessPolicy=block)." >&2
    echo "Re-run the Contractor agent to refresh the contract against current upstream artifacts." >&2
  else
    NEW_STATUS="warn"
    SUMMARY="Upstream artifacts changed since contract was created (stalenessPolicy=warn)"
    echo "WARN: upstream artifacts have changed since contract was created (stalenessPolicy=warn)." >&2
    echo "Consider re-running the Contractor agent to refresh the contract." >&2
  fi
fi

jq -n \
  --arg status "$NEW_STATUS" \
  --arg summary "$SUMMARY" \
  --arg current "$CURRENT_HASH" \
  --arg stored "$STORED_HASH" \
  '{check:"staleness",status:$status,summary:$summary,current_hash:$current,stored_hash:$stored,missing_files:[],findings:[]}'
