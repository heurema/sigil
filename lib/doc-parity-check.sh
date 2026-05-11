#!/usr/bin/env bash
# doc-parity-check.sh -- detect documentation drift against canonical Signum sources
# Usage: doc-parity-check.sh [--repo-root <dir>]
# Output: {"check":"doc_parity","status":"ok|warn|error","summary":"...","findings":[...]}
# Exit 0: check completed with no blocking drift (ok/warn)
# Exit 1: infra error or blocking documentation drift

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
SKILL_DOC="$REPO_ROOT/SKILL.md"
ARCHITECTURE_DOC="$REPO_ROOT/ARCHITECTURE.md"
ROADMAP_DOC="$REPO_ROOT/docs/plans/2026-03-15-large-project-support-roadmap.md"
SCHEMA_DOC="$REPO_ROOT/lib/schemas/contract.schema.json"
OVERLAY_DEVIATIONS_DOC="$REPO_ROOT/docs/overlay-deviations.json"

for required in "$ROOT_DOC" "$OVERLAY_DOC" "$REFERENCE_DOC" "$SKILL_DOC" "$ARCHITECTURE_DOC" "$ROADMAP_DOC" "$SCHEMA_DOC" "$OVERLAY_DEVIATIONS_DOC"; do
  if [ ! -f "$required" ]; then
    echo "{\"check\":\"doc_parity\",\"status\":\"error\",\"summary\":\"Required file not found: $required\",\"findings\":[]}" >&2
    exit 1
  fi
done

FINDINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/signum-doc-parity.XXXXXX")
trap 'rm -f "$FINDINGS_FILE"' EXIT

add_finding() {
  local severity="$1" code="$2" file="$3" message="$4" details="${5:-}"
  jq -cn \
    --arg severity "$severity" \
    --arg code "$code" \
    --arg file "$file" \
    --arg message "$message" \
    --arg details "$details" \
    '{code:$code,severity:$severity,file:$file,message:$message,details:$details}' >> "$FINDINGS_FILE"
}

add_warning() {
  add_finding "warn" "$@"
}

add_error() {
  add_finding "error" "$@"
}

require_contains() {
  local file="$1" display_file="$2" needle="$3" code="$4" message="$5" details="${6:-}"
  if ! grep -Fq -- "$needle" "$file"; then
    add_error "$code" "$display_file" "$message" "$details"
  fi
}

require_not_contains() {
  local file="$1" display_file="$2" needle="$3" code="$4" message="$5" details="${6:-}"
  if grep -Fq -- "$needle" "$file"; then
    add_error "$code" "$display_file" "$message" "$details"
  fi
}

check_current_proofpack_reference() {
  local field

  require_contains \
    "$REFERENCE_DOC" \
    "docs/reference.md" \
    "lib/schemas/proofpack.schema.json" \
    "reference_proofpack_schema_missing" \
    "Reference docs do not name the current proofpack schema source" \
    "Expected docs/reference.md to reference lib/schemas/proofpack.schema.json"

  require_contains \
    "$REFERENCE_DOC" \
    "docs/reference.md" \
    "scripts/validate_proofpack.py" \
    "reference_proofpack_validator_missing" \
    "Reference docs do not name the current proofpack validator source" \
    "Expected docs/reference.md to reference scripts/validate_proofpack.py"

  require_contains \
    "$REFERENCE_DOC" \
    "docs/reference.md" \
    ".signum/contracts/<contractId>/proofpack.json" \
    "reference_proofpack_target_missing" \
    "Reference docs do not document the active contract proofpack path" \
    "Expected docs/reference.md to mention .signum/contracts/<contractId>/proofpack.json"

  require_not_contains \
    "$REFERENCE_DOC" \
    "docs/reference.md" \
    "proofpack.json fields (v4.6)" \
    "reference_proofpack_v46_stale" \
    "Reference docs still contain stale proofpack v4.6 wording" \
    "Remove the stale heading/string 'proofpack.json fields (v4.6)'"

  for field in \
    "schemaVersion" \
    "contractId" \
    "decision" \
    "releaseVerdict" \
    "riskLevel" \
    "timing" \
    "reviewCoverage" \
    "contractSource" \
    "ciContext" \
    "baselineComparison" \
    "approval" \
    "checks.policy_scan" \
    "removalEvidence"
  do
    require_contains \
      "$REFERENCE_DOC" \
      "docs/reference.md" \
      "\`$field\`" \
      "reference_proofpack_field_missing" \
      "Reference docs do not document proofpack field $field" \
      "Expected docs/reference.md to contain \`$field\` in the proofpack field documentation"
  done
}

check_current_skill_artifact_root() {
  require_contains \
    "$SKILL_DOC" \
    "SKILL.md" \
    ".signum/contracts/<contractId>/" \
    "skill_contract_root_missing" \
    "Root skill does not document the active contract artifact root" \
    "Expected SKILL.md to mention .signum/contracts/<contractId>/"

  require_not_contains \
    "$SKILL_DOC" \
    "SKILL.md" \
    "Keep all artifacts in .signum" \
    "skill_root_artifacts_stale" \
    "Root skill still contains stale root .signum artifact wording" \
    "Remove stale wording that says to keep all artifacts in .signum"

  require_not_contains \
    "$SKILL_DOC" \
    "SKILL.md" \
    "Keep all artifacts in \`.signum/\`" \
    "skill_root_artifacts_stale" \
    "Root skill still contains stale root .signum artifact wording" \
    "Remove stale wording that says to keep all artifacts in \`.signum/\`"
}

check_current_architecture_surface() {
  require_contains \
    "$ARCHITECTURE_DOC" \
    "ARCHITECTURE.md" \
    "/signum:init" \
    "architecture_init_command_missing" \
    "Architecture docs do not use the current init command surface" \
    "Expected ARCHITECTURE.md to mention /signum:init"

  require_not_contains \
    "$ARCHITECTURE_DOC" \
    "ARCHITECTURE.md" \
    "/signum init" \
    "architecture_init_command_stale" \
    "Architecture docs still contain the stale spaced init command" \
    "Remove stale /signum init wording"

  require_contains \
    "$ARCHITECTURE_DOC" \
    "ARCHITECTURE.md" \
    ".signum/contracts/<contractId>/" \
    "architecture_contract_root_missing" \
    "Architecture docs do not document the active contract artifact root" \
    "Expected ARCHITECTURE.md to mention .signum/contracts/<contractId>/"
}

# 1. Canonical source policy exists in docs/reference.md
if ! grep -Fq 'Canonical pipeline behavior:' "$REFERENCE_DOC" || \
   ! grep -Fq 'root `commands/signum.md`' "$REFERENCE_DOC" || \
   ! grep -Fq 'Platform-specific overlays:' "$REFERENCE_DOC"; then
  add_warning \
    "canonical_source_policy_missing" \
    "docs/reference.md" \
    "Reference docs do not clearly declare canonical pipeline source and overlay policy" \
    "Expected canonical source policy pointing at root commands/signum.md and platform overlays"
fi

# 2. docs/reference.md schema range matches actual schema enum max
SCHEMA_MAX=$(jq -r '.properties.schemaVersion.enum[]' "$SCHEMA_DOC" | sort -V | tail -1)
SCHEMA_ROW=$(awk 'index($0, "| `schemaVersion` |") { print; exit }' "$REFERENCE_DOC")
DOC_RANGE=$(echo "$SCHEMA_ROW" | sed -En 's/.*\| `schemaVersion` \| `\"([0-9.]+)\"`–`\"([0-9.]+)\"` \|.*/\1 \2/p')
DOC_MIN=$(echo "$DOC_RANGE" | awk '{print $1}')
DOC_MAX=$(echo "$DOC_RANGE" | awk '{print $2}')
if [ -z "$SCHEMA_ROW" ] || [ "$DOC_MIN" != "3.0" ] || [ "$DOC_MAX" != "$SCHEMA_MAX" ]; then
  add_warning \
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
  add_warning \
    "phase_inventory_mismatch" \
    "platforms/claude-code/commands/signum.md" \
    "Overlay command phase inventory differs from canonical root command" \
    "root=[$(echo "$ROOT_PHASES" | paste -sd ',' -)] overlay=[$(echo "$OVERLAY_PHASES" | paste -sd ',' -)]"
fi

# 4. Large-project roadmap maintenance update exists
if ! grep -Fq '**2026-04-10 maintenance update**' "$ROADMAP_DOC"; then
  add_warning \
    "roadmap_maintenance_note_missing" \
    "docs/plans/2026-03-15-large-project-support-roadmap.md" \
    "Large-project roadmap is missing the maintenance note that explains shipped-vs-follow-up interpretation" \
    "Expected an explicit maintenance update near the top of the roadmap"
fi

# 5. Roadmap phases 1-5 are marked shipped in core
for phase in 1 2 3 4 5; do
  # Avoid piping awk into head under `set -o pipefail`: on GitHub-hosted
  # Linux runners awk can receive SIGPIPE after head exits, causing an
  # infrastructure failure even when parity is OK.
  block=$(awk -v phase="$phase" '
    $0 ~ "^### Phase " phase ":" { flag=1; count=0; next }
    /^### Phase [0-9]+:/ { flag=0 }
    flag && count < 5 { print; count++ }
  ' "$ROADMAP_DOC")
  if ! echo "$block" | grep -Fq '**Status:** shipped in core'; then
    add_warning \
      "roadmap_phase_status_mismatch" \
      "docs/plans/2026-03-15-large-project-support-roadmap.md" \
      "Roadmap Phase $phase is not marked shipped in core" \
      "Expected '**Status:** shipped in core' in the Phase $phase block"
  fi
done

# 6. Critical PR #98 drift hardening: current proofpack, artifact-root, and init docs
check_current_proofpack_reference
check_current_skill_artifact_root
check_current_architecture_surface

FINDINGS=$(jq -s '.' "$FINDINGS_FILE")
ERROR_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "error")] | length')
WARN_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "warn")] | length')

if [ "$ERROR_COUNT" -gt 0 ]; then
  echo "doc_parity_check: $ERROR_COUNT error(s), $WARN_COUNT warning(s) found" >&2
  echo "$FINDINGS" | jq -r '.[] | "  " + (.severity | ascii_upcase) + " [" + .code + "] " + .file + ": " + .message' >&2
  STATUS="error"
  SUMMARY="$ERROR_COUNT blocking documentation/parity error(s), $WARN_COUNT warning(s) found"
elif [ "$WARN_COUNT" -gt 0 ]; then
  echo "doc_parity_check: $WARN_COUNT warning(s) found" >&2
  echo "$FINDINGS" | jq -r '.[] | "  WARN [" + .code + "] " + .file + ": " + .message' >&2
  STATUS="warn"
  SUMMARY="$WARN_COUNT documentation/parity warning(s) found"
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

if [ "$ERROR_COUNT" -gt 0 ]; then
  exit 1
fi
