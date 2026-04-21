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
# Default: active contract root from .signum/contracts/index.json, then a single canonical contract dir, then legacy .signum/contract.json
# Exit 0: clean (no injection found)
# Exit 1: blocked (invisible Unicode detected)
# Exit 2: usage error (missing file, missing tools)

set -euo pipefail

resolve_default_contract_file() {
  local index_path=".signum/contracts/index.json"
  local contracts_root=".signum/contracts"
  local active_id=""
  local canonical_path=""
  local dir_count=""
  local only_dir=""

  if [ -f "$index_path" ]; then
    active_id="$(jq -r '.activeContractId // empty' "$index_path" 2>/dev/null || true)"
    if [ -n "$active_id" ]; then
      canonical_path=".signum/contracts/${active_id}/contract.json"
      if [ -f "$canonical_path" ]; then
        printf '%s\n' "$canonical_path"
        return 0
      fi
    fi
  fi

  if [ -d "$contracts_root" ]; then
    dir_count=$(find "$contracts_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$dir_count" = "1" ]; then
      only_dir=$(find "$contracts_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
      canonical_path="${only_dir}/contract.json"
      if [ -f "$canonical_path" ]; then
        printf '%s\n' "$canonical_path"
        return 0
      fi
    fi
  fi

  printf '%s\n' ".signum/contract.json"
}

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq not found" >&2
  exit 2
fi

if ! command -v python3 > /dev/null 2>&1; then
  echo "ERROR: python3 not found" >&2
  exit 2
fi

CONTRACT_FILE="${1:-}"

if [ -z "$CONTRACT_FILE" ]; then
  CONTRACT_FILE="$(resolve_default_contract_file)"
fi

if [ ! -f "$CONTRACT_FILE" ]; then
  echo "ERROR: contract file not found: $CONTRACT_FILE" >&2
  exit 2
fi

# Extract all human-readable text fields from contract.json
# These are the injection surfaces: goal, scope items, AC descriptions, assumptions
jq -r '
  [
    (.goal // empty),
    ((.inScope // [])[]?),
    ((.outOfScope // [])[]?),
    ((.acceptanceCriteria // [])[]? | .description // empty),
    ((.acceptanceCriteria // [])[]? | .verify // empty | tostring),
    ((.assumptions // [])[]? | if type == "object" then (.text // empty) else . end),
    ((.openQuestions // [])[]?),
    ((.removals // [])[]? | .reason // empty),
    ((.cleanupObligations // [])[]? | .description // empty),
    (.implementationStrategy // empty),
    ((.allowNewFilesUnder // [])[]?),
    ((.riskSignals // [])[]?),
    ((.contextInheritance // {}) | .. | strings)
  ] | .[] | select(. != "")
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
