#!/usr/bin/env bash
# terminology-check.sh -- detect synonym proliferation across active contracts
# Usage: terminology-check.sh <contract.json> --index <path/to/contracts/index.json> [--glossary <path/to/project.glossary.json>]
# Output: {"check":"terminology","status":"ok|warn|skip|error","summary":"...","findings":[...]}
# Exit 0: check completed (any status)
# Exit 1: infra error (bad args, missing jq, corrupt input)

set -euo pipefail

CONTRACT=""
INDEX_PATH=""
GLOSSARY_PATH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --index)    INDEX_PATH="$2";    shift 2 ;;
    --glossary) GLOSSARY_PATH="$2"; shift 2 ;;
    -*) echo "{\"check\":\"terminology\",\"status\":\"error\",\"summary\":\"Unknown flag: $1\",\"findings\":[]}" >&2; exit 1 ;;
    *) CONTRACT="$1"; shift ;;
  esac
done

if [ -z "$CONTRACT" ]; then
  echo '{"check":"terminology","status":"error","summary":"Usage: terminology-check.sh <contract.json> --index <path>","findings":[]}' >&2
  exit 1
fi

if [ ! -f "$CONTRACT" ]; then
  echo "{\"check\":\"terminology\",\"status\":\"error\",\"summary\":\"File not found: $CONTRACT\",\"findings\":[]}" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo '{"check":"terminology","status":"error","summary":"jq not found","findings":[]}' >&2
  exit 1
fi

if [ -z "$INDEX_PATH" ] || [ ! -f "$INDEX_PATH" ]; then
  echo '{"check":"terminology","status":"skip","summary":"No contracts index found — skipping terminology check","findings":[]}'
  exit 0
fi

ACTIVE_GOALS=$(jq -r '
  (.contracts // []) |
  map(select(.status == "active")) |
  if length == 0 then empty
  else .[].goal // empty
  end
' "$INDEX_PATH" 2>/dev/null || true)

if [ -z "$ACTIVE_GOALS" ]; then
  echo '{"check":"terminology","status":"skip","summary":"No active contracts — skipping terminology check","findings":[]}'
  exit 0
fi

ALL_GOALS=$(echo "$ACTIVE_GOALS" | tr '\n' ' ')

# Temp file for findings JSONL
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/signum-terminology.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

# Built-in synonym pairs
_tc_check() {
  local a="$1" b="$2"
  local has_a has_b
  has_a=$(echo "$ALL_GOALS" | grep -Fciw -- "$a" 2>/dev/null || echo 0)
  has_b=$(echo "$ALL_GOALS" | grep -Fciw -- "$b" 2>/dev/null || echo 0)
  if [ "$has_a" -gt 0 ] && [ "$has_b" -gt 0 ]; then
    jq -n --arg a "$a" --arg b "$b" \
      '{"term1":$a,"term2":$b,"message":("WARN: synonym proliferation — \"" + $a + "\" and \"" + $b + "\" used for the same concept across active contracts")}' \
      >> "$TMPFILE"
  fi
}

_tc_check "endpoint" "route"
_tc_check "function" "method"
_tc_check "test" "spec"
_tc_check "error" "exception"
_tc_check "config" "configuration"
_tc_check "config" "settings"
_tc_check "user" "client"
_tc_check "file" "document"

# If project.glossary.json is present, also check glossary aliases across active contracts
if [ -n "$GLOSSARY_PATH" ] && [ -f "$GLOSSARY_PATH" ]; then
  jq -r '.aliases | to_entries[] | .key + "|" + .value' "$GLOSSARY_PATH" | \
  while IFS='|' read -r synonym canonical; do
    [ -z "$synonym" ] && continue
    has_syn=$(echo "$ALL_GOALS" | grep -Fciw -- "$synonym" 2>/dev/null || echo 0)
    has_can=$(echo "$ALL_GOALS" | grep -Fciw -- "$canonical" 2>/dev/null || echo 0)
    if [ "$has_syn" -gt 0 ] && [ "$has_can" -gt 0 ]; then
      jq -n --arg syn "$synonym" --arg can "$canonical" \
        '{"term1":$syn,"term2":$can,"message":("WARN: glossary synonym \"" + $syn + "\" and canonical \"" + $can + "\" both appear in active contract goals")}' \
        >> "$TMPFILE"
    fi
  done
fi

# Collect findings array
if [ -s "$TMPFILE" ]; then
  FINDINGS=$(jq -s '.' "$TMPFILE")
else
  FINDINGS="[]"
fi

WARN_COUNT=$(echo "$FINDINGS" | jq 'length')

if [ "$WARN_COUNT" -gt 0 ]; then
  STATUS="warn"
  SUMMARY="$WARN_COUNT synonym proliferation warning(s) found"
  echo "terminology_consistency_check: $WARN_COUNT warning(s) found (WARN only)" >&2
  echo "$FINDINGS" | jq -r '.[] | "  " + .message' >&2
else
  STATUS="ok"
  SUMMARY="No synonym proliferation found"
  echo "terminology_consistency_check: no synonym proliferation found" >&2
fi

jq -n \
  --arg status "$STATUS" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  '{check:"terminology",status:$status,summary:$summary,findings:$findings}'
