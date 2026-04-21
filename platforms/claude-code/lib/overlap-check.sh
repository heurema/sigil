#!/usr/bin/env bash
# overlap-check.sh -- detect inScope overlap between active contracts
# Usage: overlap-check.sh <contract.json> --index <path/to/contracts/index.json>
# Output: {"check":"overlap","status":"ok|warn|skip|error","summary":"...","findings":[...]}
# Exit 0: check completed (any status)
# Exit 1: infra error (bad args, missing jq, corrupt input)

set -euo pipefail

CONTRACT=""
INDEX_PATH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --index) INDEX_PATH="$2"; shift 2 ;;
    -*) echo "{\"check\":\"overlap\",\"status\":\"error\",\"summary\":\"Unknown flag: $1\",\"findings\":[]}" >&2; exit 1 ;;
    *) CONTRACT="$1"; shift ;;
  esac
done

if [ -z "$CONTRACT" ]; then
  echo '{"check":"overlap","status":"error","summary":"Usage: overlap-check.sh <contract.json> --index <path>","findings":[]}' >&2
  exit 1
fi

if [ ! -f "$CONTRACT" ]; then
  echo "{\"check\":\"overlap\",\"status\":\"error\",\"summary\":\"File not found: $CONTRACT\",\"findings\":[]}" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo '{"check":"overlap","status":"error","summary":"jq not found","findings":[]}' >&2
  exit 1
fi

if [ -z "$INDEX_PATH" ] || [ ! -f "$INDEX_PATH" ]; then
  echo '{"check":"overlap","status":"skip","summary":"No contracts index found — skipping overlap check","findings":[]}'
  exit 0
fi

NEW_CONTRACT_ID=$(jq -r '.contractId // ""' "$CONTRACT")
ACTIVE_CONTRACTS=$(jq -c '
  (.contracts // []) |
  map(select(.status == "active"))
' "$INDEX_PATH" 2>/dev/null || echo "[]")
ACTIVE_COUNT=$(echo "$ACTIVE_CONTRACTS" | jq 'length')

if [ "$ACTIVE_COUNT" -eq 0 ]; then
  echo '{"check":"overlap","status":"skip","summary":"No active contracts in index — skipped","findings":[]}'
  exit 0
fi

NEW_INSCOPE=$(jq -c '.inScope // []' "$CONTRACT")

FINDINGS=$(echo "$ACTIVE_CONTRACTS" | jq -c \
  --argjson new_scope "$NEW_INSCOPE" \
  --arg self_id "$NEW_CONTRACT_ID" '
  [.[] |
    select(.contractId != $self_id) |
    . as $other |
    ($other.inScope // []) as $other_scope |
    ($new_scope | map(select(. as $f | $other_scope | index($f) != null))) as $overlaps |
    select($overlaps | length > 0) |
    {
      contractId: $other.contractId,
      overlappingFiles: $overlaps,
      message: ("WARN: inScope overlap with active contract " + $other.contractId + " on files: " + ($overlaps | join(", ")))
    }
  ]
' 2>/dev/null || echo "[]")

OVERLAP_COUNT=$(echo "$FINDINGS" | jq 'length')

if [ "$OVERLAP_COUNT" -gt 0 ]; then
  STATUS="warn"
  SUMMARY="$OVERLAP_COUNT overlapping active contract(s) found"
  echo "cross_contract_overlap_check: $OVERLAP_COUNT overlapping active contract(s) found (WARN only)" >&2
  echo "$FINDINGS" | jq -r '.[] | "  WARN: " + .message' >&2
else
  STATUS="ok"
  SUMMARY="No inScope overlaps found"
  echo "cross_contract_overlap_check: no inScope overlaps found" >&2
fi

jq -n \
  --arg status "$STATUS" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  '{check:"overlap",status:$status,summary:$summary,findings:$findings}'
