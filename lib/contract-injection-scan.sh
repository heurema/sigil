#!/usr/bin/env bash
# contract-injection-scan.sh -- scan contract.json for invisible Unicode injection
# Defense against MINJA-class attacks (NeurIPS 2025: 95% injection success rate).
# Scans text fields in contract.json for invisible Unicode characters that could
# carry prompt injection payloads from contractor agent to engineer agent.
#
# Based on Hermes defense (10 regex patterns + Unicode NFKC) and
# Glassworm research (variation selectors, bidi overrides, tag characters).
#
# Usage: contract-injection-scan.sh [contract_file]
# Default: .signum/contract.json
# Exit 0: clean (no injection found)
# Exit 1: blocked (invisible Unicode detected)
# Exit 2: usage error (missing file, missing tools)

set -euo pipefail

CONTRACT_FILE="${1:-.signum/contract.json}"

if [ ! -f "$CONTRACT_FILE" ]; then
  echo "ERROR: contract file not found: $CONTRACT_FILE" >&2
  exit 2
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq not found" >&2
  exit 2
fi

if ! command -v python3 > /dev/null 2>&1; then
  echo "ERROR: python3 not found" >&2
  exit 2
fi

# Extract all human-readable text fields from contract.json
# These are the injection surfaces: goal, scope items, AC descriptions, assumptions
jq -r '
  [
    .goal // empty,
    (.inScope // [])[] // empty,
    (.outOfScope // [])[] // empty,
    (.acceptanceCriteria // [])[].description // empty,
    (.acceptanceCriteria // [])[].verify // empty | tostring,
    ((.assumptions // [])[] | if type == "object" then .text else . end) // empty,
    (.openQuestions // [])[] // empty,
    (.removals // [])[].reason // empty,
    (.cleanupObligations // [])[].description // empty,
    .implementationStrategy // empty,
    (.allowNewFilesUnder // [])[] // empty,
    (.riskSignals // [])[] // empty,
    (.contextInheritance // {} | .. | strings) // empty
  ] | .[]
' "$CONTRACT_FILE" 2>/dev/null | python3 -c "
import re, sys

# Invisible Unicode ranges (from Glassworm + Hermes research)
DANGER = re.compile(
    r'[\uFE00-\uFE0F'           # Variation Selectors (Glassworm primary vector)
    r'\U000E0100-\U000E01EF'    # Variation Selectors Supplement
    r'\u202A-\u202E'            # LTR/RTL bidi overrides (Trojan Source)
    r'\u2066-\u2069'            # Directional isolates
    r'\u200B-\u200D'            # Zero-width space/joiner/non-joiner
    r'\uFEFF'                   # BOM / ZWNBSP
    r'\U000E0000-\U000E007F'    # Tag characters (MCP injection)
    r'\u00AD'                   # Soft hyphen (invisible in most renders)
    r'\u034F'                   # Combining grapheme joiner
    r'\u2060-\u2064'            # Word joiner, invisible times/separator/plus
    r']'
)

found = False
for i, line in enumerate(sys.stdin, 1):
    for m in DANGER.finditer(line):
        cp = ord(m.group())
        ctx = line.strip()[:80]
        print(f'BLOCKED: invisible Unicode U+{cp:04X} in field {i}: {ctx}', file=sys.stderr)
        found = True

if found:
    sys.exit(1)
sys.exit(0)
"
