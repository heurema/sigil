#!/usr/bin/env bash
# adr-check.sh -- check for relevant ADRs not referenced in contract
# Usage: adr-check.sh <contract.json> --project-root <dir>
# Output: {"check":"adr","status":"ok|warn|skip|error","summary":"...","findings":[...]}
# Exit 0: check completed (any status)
# Exit 1: infra error (bad args, missing jq, corrupt input)

set -euo pipefail

CONTRACT=""
PROJECT_ROOT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    -*) echo "{\"check\":\"adr\",\"status\":\"error\",\"summary\":\"Unknown flag: $1\",\"findings\":[]}" >&2; exit 1 ;;
    *) CONTRACT="$1"; shift ;;
  esac
done

if [ -z "$CONTRACT" ]; then
  echo '{"check":"adr","status":"error","summary":"Usage: adr-check.sh <contract.json> --project-root <dir>","findings":[]}' >&2
  exit 1
fi

if [ ! -f "$CONTRACT" ]; then
  echo "{\"check\":\"adr\",\"status\":\"error\",\"summary\":\"File not found: $CONTRACT\",\"findings\":[]}" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo '{"check":"adr","status":"error","summary":"jq not found","findings":[]}' >&2
  exit 1
fi

ROOT="${PROJECT_ROOT:-$PWD}"

ADR_DIR_1=""
ADR_DIR_2=""
[ -d "$ROOT/docs/adr" ]       && ADR_DIR_1="$ROOT/docs/adr"
[ -d "$ROOT/docs/decisions" ] && ADR_DIR_2="$ROOT/docs/decisions"

if [ -z "$ADR_DIR_1" ] && [ -z "$ADR_DIR_2" ]; then
  echo '{"check":"adr","status":"skip","summary":"No docs/adr or docs/decisions directory found — skipped","findings":[]}'
  exit 0
fi

ADR_FIND_ARGS=()
[ -n "$ADR_DIR_1" ] && ADR_FIND_ARGS+=("$ADR_DIR_1")
[ -n "$ADR_DIR_2" ] && ADR_FIND_ARGS+=("$ADR_DIR_2")
ADR_FILES=$(find "${ADR_FIND_ARGS[@]}" -maxdepth 1 -name "*.md" 2>/dev/null | sort || true)

if [ -z "$ADR_FILES" ]; then
  echo '{"check":"adr","status":"skip","summary":"No ADR files found — skipped","findings":[]}'
  exit 0
fi

INSCOPE_LIST=$(jq -r '.inScope // [] | .[]' "$CONTRACT" 2>/dev/null || true)
ADR_REFS=$(jq -r '(.adrRefs // []) | length' "$CONTRACT" 2>/dev/null || echo 0)

RELEVANT_ADRS=""
while IFS= read -r adr_file; do
  [ -z "$adr_file" ] && continue
  adr_base=$(basename "$adr_file" .md)
  while IFS= read -r scope_path; do
    [ -z "$scope_path" ] && continue
    scope_base=$(basename "$scope_path" | sed 's/\.[^.]*$//')
    if echo "$scope_base" | grep -Fqi -- "$adr_base" 2>/dev/null || \
       echo "$adr_base"   | grep -Fqi -- "$scope_base" 2>/dev/null || \
       echo "$scope_path" | grep -Fqi -- "$adr_base" 2>/dev/null; then
      RELEVANT_ADRS="$RELEVANT_ADRS $adr_file"
      break
    fi
  done <<< "$INSCOPE_LIST"
done <<< "$ADR_FILES"

if [ -n "$RELEVANT_ADRS" ] && [ "$ADR_REFS" -eq 0 ]; then
  RELEVANT_LIST=$(echo "$RELEVANT_ADRS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
  FINDINGS=$(echo "$RELEVANT_LIST" | jq -R -s '
    split("\n") | map(select(length > 0)) |
    map({"file": ., "message": ("WARN: relevant ADR found but adrRefs field is absent or empty: " + .)})
  ')
  STATUS="warn"
  SUMMARY="Relevant ADR(s) found but adrRefs is absent or empty"
  echo "adr_relevance_check: relevant ADRs found but adrRefs is empty (WARN only)" >&2
  echo "$RELEVANT_LIST" | while read -r f; do [ -n "$f" ] && echo "  WARN: consider referencing ADR: $f" >&2; done
else
  FINDINGS="[]"
  STATUS="ok"
  SUMMARY="Relevant ADRs referenced or none found"
  echo "adr_relevance_check: OK (relevant ADRs referenced or none found)" >&2
fi

jq -n \
  --arg status "$STATUS" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  '{check:"adr",status:$status,summary:$summary,findings:$findings}'
