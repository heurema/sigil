#!/usr/bin/env bash
# assumption-check.sh -- detect contradictions between assumptions in related contracts
# Usage: assumption-check.sh <contract.json> --index <path/to/contracts/index.json>
# Output: {"check":"assumption","status":"ok|warn|skip|error","summary":"...","findings":[...]}
# Exit 0: check completed (any status)
# Exit 1: infra error (bad args, missing jq, corrupt input)

set -euo pipefail

CONTRACT=""
INDEX_PATH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --index) INDEX_PATH="$2"; shift 2 ;;
    -*) echo "{\"check\":\"assumption\",\"status\":\"error\",\"summary\":\"Unknown flag: $1\",\"findings\":[]}" >&2; exit 1 ;;
    *) CONTRACT="$1"; shift ;;
  esac
done

if [ -z "$CONTRACT" ]; then
  echo '{"check":"assumption","status":"error","summary":"Usage: assumption-check.sh <contract.json> --index <path>","findings":[]}' >&2
  exit 1
fi

if [ ! -f "$CONTRACT" ]; then
  echo "{\"check\":\"assumption\",\"status\":\"error\",\"summary\":\"File not found: $CONTRACT\",\"findings\":[]}" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo '{"check":"assumption","status":"error","summary":"jq not found","findings":[]}' >&2
  exit 1
fi

PARENT_ID=$(jq -r '.parentContractId // ""' "$CONTRACT")
RELATED_IDS=$(jq -r '(.relatedContractIds // []) | .[]' "$CONTRACT" 2>/dev/null || true)
NEW_ASSUMPTIONS=$(jq -r '(.assumptions // []) | .[].text' "$CONTRACT" 2>/dev/null || true)

if [ -z "$INDEX_PATH" ] || [ ! -f "$INDEX_PATH" ] || ( [ -z "$PARENT_ID" ] && [ -z "$RELATED_IDS" ] ); then
  echo '{"check":"assumption","status":"skip","summary":"No related contracts — skipping assumption check","findings":[]}'
  exit 0
fi

# Temp file for findings JSONL
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/signum-assumption.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

ALL_RELATED_IDS="$PARENT_ID $RELATED_IDS"

for REL_ID in $ALL_RELATED_IDS; do
  [ -z "$REL_ID" ] && continue
  REL_ASSUMPTIONS=$(jq -r --arg id "$REL_ID" \
    '(.contracts // []) | map(select(.contractId == $id)) | .[0].assumptions // [] | .[].text' \
    "$INDEX_PATH" 2>/dev/null || true)
  [ -z "$REL_ASSUMPTIONS" ] && continue

  while IFS= read -r rel_text; do
    [ -z "$rel_text" ] && continue
    while IFS= read -r new_text; do
      [ -z "$new_text" ] && continue
      CONTR=0
      # Check: "must X" in new vs "must not X"/"never X"/"prevent X" in rel
      pos_word=$(echo "$new_text" | grep -oiE "\bmust [a-z]+\b" | grep -viE "must not" | head -1 || true)
      if [ -n "$pos_word" ]; then
        verb=$(echo "$pos_word" | awk '{print $2}')
        echo "$rel_text" | grep -Fqi -- "must not $verb" && CONTR=1 || true
        [ "$CONTR" -eq 0 ] && echo "$rel_text" | grep -Fqi -- "never $verb"   && CONTR=1 || true
        [ "$CONTR" -eq 0 ] && echo "$rel_text" | grep -Fqi -- "prevent $verb" && CONTR=1 || true
      fi
      # Check: "must not X"/"never X" in new vs "must X"/"always X"/"require X" in rel
      neg_word=$(echo "$new_text" | grep -oiE "\bmust not [a-z]+\b|\bnever [a-z]+\b" | head -1 || true)
      if [ -n "$neg_word" ]; then
        verb=$(echo "$neg_word" | awk '{print $NF}')
        [ "$CONTR" -eq 0 ] && echo "$rel_text" | grep -Fqi -- "must $verb"    && CONTR=1 || true
        [ "$CONTR" -eq 0 ] && echo "$rel_text" | grep -Fqi -- "always $verb"  && CONTR=1 || true
        [ "$CONTR" -eq 0 ] && echo "$rel_text" | grep -Fqi -- "require $verb" && CONTR=1 || true
      fi
      if [ "$CONTR" -eq 1 ]; then
        jq -n --arg rel "$REL_ID" --arg a1 "$new_text" --arg a2 "$rel_text" \
          '{"contractId":$rel,"assumption1":$a1,"assumption2":$a2,"message":("WARN: possible assumption contradiction between current contract and " + $rel)}' \
          >> "$TMPFILE"
      fi
    done <<< "$NEW_ASSUMPTIONS"
  done <<< "$REL_ASSUMPTIONS"
done

# Collect findings array
if [ -s "$TMPFILE" ]; then
  FINDINGS=$(jq -s '.' "$TMPFILE")
else
  FINDINGS="[]"
fi

WARN_COUNT=$(echo "$FINDINGS" | jq 'length')

if [ "$WARN_COUNT" -gt 0 ]; then
  STATUS="warn"
  SUMMARY="$WARN_COUNT assumption contradiction(s) found"
  echo "assumption_contradiction_check: $WARN_COUNT contradiction(s) found (WARN only)" >&2
  echo "$FINDINGS" | jq -r '.[] | "  " + .message' >&2
else
  STATUS="ok"
  SUMMARY="No assumption contradictions found"
  echo "assumption_contradiction_check: no contradictions found" >&2
fi

jq -n \
  --arg status "$STATUS" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  '{check:"assumption",status:$status,summary:$summary,findings:$findings}'
