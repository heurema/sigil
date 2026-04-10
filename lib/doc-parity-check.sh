#!/usr/bin/env bash
# doc-parity-check.sh -- detect documentation drift against canonical Signum sources
# Usage: doc-parity-check.sh [--repo-root <dir>]
# Output: {"check":"doc_parity","status":"ok|warn|error","summary":"...","findings":[...]}
# Exit 0: check completed (ok/warn)
# Exit 1: infra error

set -euo pipefail

REPO_ROOT="${PWD}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    -*) echo "{\"check\":\"doc_parity\",\"status\":\"error\",\"summary\":\"Unknown flag: $1\",\"findings\":[]}" >&2; exit 1 ;;
    *) echo "{\"check\":\"doc_parity\",\"status\":\"error\",\"summary\":\"Unexpected argument: $1\",\"findings\":[]}" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo '{"check":"doc_parity","status":"error","summary":"jq not found","findings":[]}' >&2
  exit 1
fi

ROOT_DOC="$REPO_ROOT/commands/signum.md"
OVERLAY_DOC="$REPO_ROOT/platforms/claude-code/commands/signum.md"
REFERENCE_DOC="$REPO_ROOT/docs/reference.md"
ROADMAP_DOC="$REPO_ROOT/docs/plans/2026-03-15-large-project-support-roadmap.md"
SCHEMA_DOC="$REPO_ROOT/lib/schemas/contract.schema.json"
OVERLAY_DEVIATIONS_DOC="$REPO_ROOT/docs/overlay-deviations.json"

for required in "$ROOT_DOC" "$OVERLAY_DOC" "$REFERENCE_DOC" "$ROADMAP_DOC" "$SCHEMA_DOC" "$OVERLAY_DEVIATIONS_DOC"; do
  if [ ! -f "$required" ]; then
    echo "{\"check\":\"doc_parity\",\"status\":\"error\",\"summary\":\"Required file not found: $required\",\"findings\":[]}" >&2
    exit 1
  fi
done

FINDINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/signum-doc-parity.XXXXXX")
trap 'rm -f "$FINDINGS_FILE"' EXIT

add_finding() {
  local code="$1" file="$2" message="$3" details="${4:-}"
  jq -cn \
    --arg code "$code" \
    --arg file "$file" \
    --arg message "$message" \
    --arg details "$details" \
    '{code:$code,severity:"warn",file:$file,message:$message,details:$details}' >> "$FINDINGS_FILE"
}

# 1. Canonical source policy exists in docs/reference.md
if ! grep -Fq 'Canonical pipeline behavior:' "$REFERENCE_DOC" || \
   ! grep -Fq 'root `commands/signum.md`' "$REFERENCE_DOC" || \
   ! grep -Fq 'Platform-specific overlays:' "$REFERENCE_DOC"; then
  add_finding \
    "canonical_source_policy_missing" \
    "docs/reference.md" \
    "Reference docs do not clearly declare canonical pipeline source and overlay policy" \
    "Expected canonical source policy pointing at root commands/signum.md and platform overlays"
fi

# 2. docs/reference.md schema range matches actual schema enum max
SCHEMA_MAX=$(jq -r '.properties.schemaVersion.enum[]' "$SCHEMA_DOC" | sort -V | tail -1)
SCHEMA_ROW=$(grep -F '| `schemaVersion` |' "$REFERENCE_DOC" | head -1 || true)
DOC_RANGE=$(echo "$SCHEMA_ROW" | sed -En 's/.*\| `schemaVersion` \| `\"([0-9.]+)\"`–`\"([0-9.]+)\"` \|.*/\1 \2/p')
DOC_MIN=$(echo "$DOC_RANGE" | awk '{print $1}')
DOC_MAX=$(echo "$DOC_RANGE" | awk '{print $2}')
if [ -z "$SCHEMA_ROW" ] || [ "$DOC_MIN" != "3.0" ] || [ "$DOC_MAX" != "$SCHEMA_MAX" ]; then
  add_finding \
    "schema_version_range_mismatch" \
    "docs/reference.md" \
    "Reference schemaVersion range does not match lib/schemas/contract.schema.json" \
    "Expected docs/reference.md to mention 3.0–$SCHEMA_MAX"
fi

# 3. Root vs overlay phase parity
ROOT_PHASES=$(grep '^## Phase [0-9][0-9]*:' "$ROOT_DOC" | sed -E 's/^## Phase [0-9]+: //')
OVERLAY_PHASES=$(grep '^## Phase [0-9][0-9]*:' "$OVERLAY_DOC" | sed -E 's/^## Phase [0-9]+: //')
ROOT_PHASES_JSON=$(printf '%s\n' "$ROOT_PHASES" | jq -R . | jq -s '.')
OVERLAY_PHASES_JSON=$(printf '%s\n' "$OVERLAY_PHASES" | jq -R . | jq -s '.')
EXTRA_PHASES=$(jq -n \
  --argjson root "$ROOT_PHASES_JSON" \
  --argjson overlay "$OVERLAY_PHASES_JSON" \
  '$overlay | map(select(. as $p | $root | index($p) | not))')
MISSING_PHASES=$(jq -n \
  --argjson root "$ROOT_PHASES_JSON" \
  --argjson overlay "$OVERLAY_PHASES_JSON" \
  '$root | map(select(. as $p | $overlay | index($p) | not))')

ALLOWED_EXTRA_PHASES=$(jq -c \
  '.overlays["platforms/claude-code/commands/signum.md"].allowedExtraPhases // [] | map(.name)' \
  "$OVERLAY_DEVIATIONS_DOC")

EXTRA_UNDOCUMENTED=$(jq -n \
  --argjson extra "$EXTRA_PHASES" \
  --argjson allowed "$ALLOWED_EXTRA_PHASES" \
  '$extra | map(select(. as $p | $allowed | index($p) | not))')

DOC_MENTIONS_RECONCILE="false"
if grep -Fq 'Phase 5: RECONCILE' "$REFERENCE_DOC" && grep -Fq 'docs/overlay-deviations.json' "$REFERENCE_DOC"; then
  DOC_MENTIONS_RECONCILE="true"
fi

if [ "$(echo "$MISSING_PHASES" | jq 'length')" -gt 0 ] || \
   [ "$(echo "$EXTRA_UNDOCUMENTED" | jq 'length')" -gt 0 ] || \
   { [ "$(echo "$EXTRA_PHASES" | jq 'length')" -gt 0 ] && [ "$DOC_MENTIONS_RECONCILE" != "true" ]; }; then
  add_finding \
    "phase_inventory_mismatch" \
    "platforms/claude-code/commands/signum.md" \
    "Overlay command phase inventory differs from canonical root command" \
    "root=[$(echo "$ROOT_PHASES" | paste -sd ',' -)] overlay=[$(echo "$OVERLAY_PHASES" | paste -sd ',' -)]"
fi

# 4. Large-project roadmap maintenance update exists
if ! grep -Fq '**2026-04-10 maintenance update**' "$ROADMAP_DOC"; then
  add_finding \
    "roadmap_maintenance_note_missing" \
    "docs/plans/2026-03-15-large-project-support-roadmap.md" \
    "Large-project roadmap is missing the maintenance note that explains shipped-vs-follow-up interpretation" \
    "Expected an explicit maintenance update near the top of the roadmap"
fi

# 5. Roadmap phases 1-5 are marked shipped in core
for phase in 1 2 3 4 5; do
  block=$(awk "/^### Phase $phase:/{flag=1;next}/^### Phase [0-9]+:/{flag=0}flag" "$ROADMAP_DOC" | head -n 5)
  if ! echo "$block" | grep -Fq '**Status:** shipped in core'; then
    add_finding \
      "roadmap_phase_status_mismatch" \
      "docs/plans/2026-03-15-large-project-support-roadmap.md" \
      "Roadmap Phase $phase is not marked shipped in core" \
      "Expected '**Status:** shipped in core' in the Phase $phase block"
  fi
done

FINDINGS=$(jq -s '.' "$FINDINGS_FILE")
COUNT=$(echo "$FINDINGS" | jq 'length')

if [ "$COUNT" -gt 0 ]; then
  echo "doc_parity_check: $COUNT warning(s) found" >&2
  echo "$FINDINGS" | jq -r '.[] | "  WARN [" + .code + "] " + .file + ": " + .message' >&2
  STATUS="warn"
  SUMMARY="$COUNT documentation/parity warning(s) found"
else
  echo "doc_parity_check: no documentation/parity drift found" >&2
  STATUS="ok"
  SUMMARY="No documentation/parity drift found"
fi

jq -n \
  --arg status "$STATUS" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  '{check:"doc_parity",status:$status,summary:$summary,findings:$findings}'
