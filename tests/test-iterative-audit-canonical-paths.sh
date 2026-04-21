#!/usr/bin/env bash
set -euo pipefail

ROOT_CMD="/Users/vi/personal/heurema/signum/commands/signum.md"
OVERLAY_CMD="/Users/vi/personal/heurema/signum/platforms/claude-code/commands/signum.md"

extract_iterative_audit_section() {
  local file="$1"
  awk '
    /^### Step 3\.5: Synthesizer \(agent\)/ { capture=1 }
    capture { print }
    /^## Phase 4: PACK/ && capture { exit }
  ' "$file"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected ${label} to not contain: $needle" >&2
    exit 1
  fi
}

ROOT_SECTION="$(extract_iterative_audit_section "$ROOT_CMD")"
OVERLAY_SECTION="$(extract_iterative_audit_section "$OVERLAY_CMD")"

for label in ROOT_SECTION OVERLAY_SECTION; do
  section="${!label}"
  assert_contains "$section" 'The canonical artifact root for this synthesis is `.signum/contracts/<activeContractId>/`.' "$label"
  assert_contains "$section" 'REVIEWS_DIR="${ARTIFACT_ROOT}reviews"' "$label"
  assert_contains "$section" 'AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"' "$label"
  assert_contains "$section" 'AUDIT_ITERATION_LOG_PATH="${ARTIFACT_ROOT}audit_iteration_log.json"' "$label"
  assert_contains "$section" 'REPAIR_BRIEF_PATH="${ARTIFACT_ROOT}repair_brief.json"' "$label"
  assert_contains "$section" 'The canonical artifact root in this lane is `.signum/contracts/<activeContractId>/`.' "$label"
  assert_not_contains "$section" '.signum/reviews/' "$label"
  assert_not_contains "$section" '.signum/audit_summary.json' "$label"
  assert_not_contains "$section" '.signum/audit_iteration_log.json' "$label"
  assert_not_contains "$section" '.signum/repair_brief.json' "$label"
  assert_not_contains "$section" 'Read .signum/mechanic_report.json' "$label"
done

echo "ok: iterative audit flow uses canonical artifact-root paths"
