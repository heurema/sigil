#!/usr/bin/env bash
# init-harness-scaffold.sh -- deterministic harness-doc scaffold for /signum init --harness
# Usage: init-harness-scaffold.sh [--project-root <path>] [--as-of YYYY-MM-DD]
# Output: JSON scaffold metadata + draft contents to stdout
# Exit 0: scaffold generated
# Exit 1: fatal error (missing jq, invalid args)

set -euo pipefail

PROJECT_ROOT="."
AS_OF=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates/init-harness"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --as-of)
      AS_OF="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v jq > /dev/null 2>&1; then
  echo '{"error":"jq not found"}' >&2
  exit 1
fi

cd "$PROJECT_ROOT"
ROOT_ABS="$(pwd)"
PROJECT_NAME="$(basename "$ROOT_ABS")"
AS_OF="${AS_OF:-$(date +%F)}"

build_frontmatter() {
  cat <<EOF
---
status: draft
owner: TODO
last_reviewed: ${AS_OF}
review_cadence: quarterly
---
EOF
}

FRONTMATTER="$(build_frontmatter)"

render_template() {
  local template_name="$1"
  local template_path="${TEMPLATE_DIR}/${template_name}"
  local content=""
  local restore_patsub_replacement=0

  if [ ! -f "$template_path" ]; then
    echo "ERROR: init harness template not found: $template_path" >&2
    exit 1
  fi

  content="$(cat "$template_path")"
  if shopt -q patsub_replacement 2>/dev/null; then
    restore_patsub_replacement=1
    shopt -u patsub_replacement
  fi
  content="${content//\{\{FRONTMATTER\}\}/$FRONTMATTER}"
  content="${content//\{\{PROJECT_NAME\}\}/$PROJECT_NAME}"
  if [ "$restore_patsub_replacement" -eq 1 ]; then
    shopt -s patsub_replacement
  fi

  if printf '%s\n' "$content" | grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}'; then
    echo "ERROR: unresolved init harness template placeholder in $template_path" >&2
    exit 1
  fi

  printf '%s' "$content"
}

AGENTS_CONTENT="$(render_template "agents.md.tmpl")"
ARCHITECTURE_CONTENT="$(render_template "architecture.md.tmpl")"
PLANS_CONTENT="$(render_template "plans.md.tmpl")"
RELIABILITY_CONTENT="$(render_template "reliability.md.tmpl")"
SECURITY_CONTENT="$(render_template "security.md.tmpl")"
QUALITY_SCORE_CONTENT="$(render_template "quality-score.md.tmpl")"

exists_json() {
  local path="$1"
  if [ -e "$path" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

AGENTS_EXISTS="$(exists_json "AGENTS.md")"
ARCHITECTURE_EXISTS="$(exists_json "ARCHITECTURE.md")"
PLANS_EXISTS="$(exists_json "docs/PLANS.md")"
RELIABILITY_EXISTS="$(exists_json "docs/RELIABILITY.md")"
SECURITY_EXISTS="$(exists_json "docs/SECURITY.md")"
QUALITY_SCORE_EXISTS="$(exists_json "docs/QUALITY_SCORE.md")"

jq -n \
  --arg schema_version "1.0" \
  --arg project_root "$ROOT_ABS" \
  --arg project_name "$PROJECT_NAME" \
  --arg as_of "$AS_OF" \
  --arg agents_content "$AGENTS_CONTENT" \
  --arg architecture_content "$ARCHITECTURE_CONTENT" \
  --arg plans_content "$PLANS_CONTENT" \
  --arg reliability_content "$RELIABILITY_CONTENT" \
  --arg security_content "$SECURITY_CONTENT" \
  --arg quality_score_content "$QUALITY_SCORE_CONTENT" \
  --argjson agents_exists "$AGENTS_EXISTS" \
  --argjson architecture_exists "$ARCHITECTURE_EXISTS" \
  --argjson plans_exists "$PLANS_EXISTS" \
  --argjson reliability_exists "$RELIABILITY_EXISTS" \
  --argjson security_exists "$SECURITY_EXISTS" \
  --argjson quality_score_exists "$QUALITY_SCORE_EXISTS" \
  '{
    schemaVersion: $schema_version,
    projectRoot: $project_root,
    projectName: $project_name,
    asOf: $as_of,
    writePolicy: "skip-existing-unless-force",
    directories: ["docs"],
    files: [
      {
        path: "AGENTS.md",
        purpose: "Agent-facing repo map and working agreements",
        exists: $agents_exists,
        content: $agents_content
      },
      {
        path: "ARCHITECTURE.md",
        purpose: "High-level system architecture and critical flows",
        exists: $architecture_exists,
        content: $architecture_content
      },
      {
        path: "docs/PLANS.md",
        purpose: "Active plan index and anti-drift planning rules",
        exists: $plans_exists,
        content: $plans_content
      },
      {
        path: "docs/RELIABILITY.md",
        purpose: "Critical journeys, service levels, and recovery notes",
        exists: $reliability_exists,
        content: $reliability_content
      },
      {
        path: "docs/SECURITY.md",
        purpose: "Trust boundaries, sensitive data, and security review triggers",
        exists: $security_exists,
        content: $security_content
      },
      {
        path: "docs/QUALITY_SCORE.md",
        purpose: "Repo-specific quality bars, evidence, and waiver policy",
        exists: $quality_score_exists,
        content: $quality_score_content
      }
    ]
  }
  | .missingCount = ([.files[] | select(.exists == false)] | length)
  | .existingCount = ([.files[] | select(.exists == true)] | length)'
