#!/usr/bin/env bash
set -euo pipefail

ROOT_CMD="/Users/vi/personal/heurema/signum/commands/signum.md"
OVERLAY_CMD="/Users/vi/personal/heurema/signum/platforms/claude-code/commands/signum.md"

extract_phase3_review_section() {
  local file="$1"
  awk '
    /^### Step 3\.2\.5: Launch reviews/ { capture=1 }
    capture { print }
    /^### Step 3\.5: Synthesizer \(agent\)/ && capture { exit }
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

ROOT_SECTION="$(extract_phase3_review_section "$ROOT_CMD")"
OVERLAY_SECTION="$(extract_phase3_review_section "$OVERLAY_CMD")"

for label in ROOT_SECTION OVERLAY_SECTION; do
  section="${!label}"
  assert_contains "$section" 'REVIEWS_DIR="${ARTIFACT_ROOT}reviews"' "$label"
  assert_contains "$section" 'CODEX_EXTRACTED_PATH="${ARTIFACT_ROOT}codex_extracted.json"' "$label"
  assert_contains "$section" 'GEMINI_EXTRACTED_PATH="${ARTIFACT_ROOT}gemini_extracted.json"' "$label"
  assert_not_contains "$section" '.signum/reviews/' "$label"
  assert_not_contains "$section" '.signum/codex_extracted.json' "$label"
  assert_not_contains "$section" '.signum/gemini_extracted.json' "$label"
done

echo "ok: Phase 3 review launch/parse paths use canonical artifact-root helpers"
