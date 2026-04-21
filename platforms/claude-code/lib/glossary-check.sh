#!/usr/bin/env bash
# glossary-check.sh -- scan contract goal/inScope/ACs for forbidden synonyms
# Usage: glossary-check.sh <contract.json> --glossary <path/to/project.glossary.json>
# Output: {"check":"glossary","status":"ok|warn|skip|error","summary":"...","findings":[...]}
# Exit 0: check completed (any status)
# Exit 1: infra error (bad args, missing jq, corrupt input)

set -euo pipefail

CONTRACT=""
GLOSSARY_PATH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --glossary) GLOSSARY_PATH="$2"; shift 2 ;;
    -*) echo "{\"check\":\"glossary\",\"status\":\"error\",\"summary\":\"Unknown flag: $1\",\"findings\":[]}" >&2; exit 1 ;;
    *) CONTRACT="$1"; shift ;;
  esac
done

if [ -z "$CONTRACT" ]; then
  echo '{"check":"glossary","status":"error","summary":"Usage: glossary-check.sh <contract.json> --glossary <path>","findings":[]}' >&2
  exit 1
fi

if [ ! -f "$CONTRACT" ]; then
  echo "{\"check\":\"glossary\",\"status\":\"error\",\"summary\":\"File not found: $CONTRACT\",\"findings\":[]}" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo '{"check":"glossary","status":"error","summary":"jq not found","findings":[]}' >&2
  exit 1
fi

# Skip if no glossary provided or not found
if [ -z "$GLOSSARY_PATH" ] || [ ! -f "$GLOSSARY_PATH" ]; then
  echo '{"check":"glossary","status":"skip","summary":"Glossary not found — skipping glossary check","findings":[]}'
  exit 0
fi

GLOSSARY_VERSION=$(jq -r '.version // ""' "$GLOSSARY_PATH")
GLOSSARY_TERMS=$(jq -r '.canonicalTerms | length' "$GLOSSARY_PATH" 2>/dev/null || echo 0)
echo "Glossary: loaded (version $GLOSSARY_VERSION, $GLOSSARY_TERMS terms)" >&2

# Build text to scan: goal + inScope items + AC descriptions
SCAN_TEXT=$(jq -r '
  .goal,
  (.inScope // [] | .[]),
  (.acceptanceCriteria // [] | .[].description)
' "$CONTRACT" | tr '\n' ' ')

# Temp file for findings JSONL
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/signum-glossary.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

# Read aliases map and scan for forbidden synonyms
jq -r '.aliases | to_entries[] | .key + "|" + .value' "$GLOSSARY_PATH" | \
while IFS='|' read -r synonym canonical; do
  [ -z "$synonym" ] && continue
  matched=$(echo "$SCAN_TEXT" | grep -Foiw -- "$synonym" 2>/dev/null | head -1 || true)
  if [ -n "$matched" ]; then
    jq -n --arg term "$matched" --arg canonical "$canonical" \
      '{"term":$term,"canonical":$canonical,"message":("WARN: use canonical term \"" + $canonical + "\" instead of synonym \"" + $term + "\"")}' \
      >> "$TMPFILE"
  fi
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
  SUMMARY="$WARN_COUNT forbidden synonym(s) found"
  echo "Glossary check: $WARN_COUNT forbidden synonym(s) found (WARN only)" >&2
  echo "$FINDINGS" | jq -r '.[] | "  WARN: use canonical term \"" + .canonical + "\" instead of synonym \"" + .term + "\""' >&2
else
  STATUS="ok"
  SUMMARY="No forbidden synonyms found"
  echo "Glossary check: no forbidden synonyms found" >&2
fi

jq -n \
  --arg status "$STATUS" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  --arg gver "$GLOSSARY_VERSION" \
  --argjson gterms "$GLOSSARY_TERMS" \
  '{
    check: "glossary",
    status: $status,
    summary: $summary,
    glossary_version: $gver,
    glossary_terms: $gterms,
    findings: $findings
  }'
