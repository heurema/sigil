#!/usr/bin/env bash
# init-scanner.sh -- deterministic signal extraction for /signum init
# Scans a project root and emits structured JSON signals for LLM synthesis.
# Usage: init-scanner.sh [--project-root <path>]
# Output: JSON to stdout with all extracted signals
# Exit 0: scan complete (signals may be empty/sparse)
# Exit 1: fatal error (missing tools, invalid args)

set -euo pipefail

PROJECT_ROOT="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if ! command -v jq > /dev/null 2>&1; then
  echo '{"error":"jq not found"}' >&2
  exit 1
fi

cd "$PROJECT_ROOT"
ROOT_ABS="$(pwd)"

# ---------------------------------------------------------------------------
# Ignore set -- paths excluded from scanning
# ---------------------------------------------------------------------------
IGNORE_DIRS=(".git" ".signum" "node_modules" "dist" "build" ".venv" "__pycache__" "coverage" "tests/fixtures")

is_ignored() {
  local path="$1"
  for ig in "${IGNORE_DIRS[@]}"; do
    case "$path" in
      "$ig"/*|"$ig") return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Helper: safe read (first N lines, empty string if missing)
# ---------------------------------------------------------------------------
safe_head() {
  local file="$1" lines="${2:-200}"
  if [ -f "$file" ]; then
    head -n "$lines" "$file" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Phase 1: Authoritative docs (precedence rank 1)
# docs/how-it-works.md, ARCHITECTURE.md, legacy docs/architecture.md, docs/reference.md
# Also deep-scan docs/ subdirectories: docs/research/, docs/plans/, docs/adr/
# ---------------------------------------------------------------------------
AUTHORITATIVE_DOCS=""
for candidate in docs/how-it-works.md ARCHITECTURE.md docs/architecture.md docs/reference.md docs/design.md; do
  if [ -f "$candidate" ]; then
    content=$(safe_head "$candidate" 300)
    AUTHORITATIVE_DOCS="${AUTHORITATIVE_DOCS}
=== $candidate ===
$content
"
  fi
done

# Deep-scan docs/ subdirectories (research, plans, adr, etc.)
DOCS_DEEP=""
if [ -d "docs" ]; then
  while IFS= read -r -d $'\0' f; do
    rel="${f#./}"
    if ! is_ignored "$rel"; then
      content=$(safe_head "$f" 100)
      DOCS_DEEP="${DOCS_DEEP}
=== $rel ===
$content
"
    fi
  done < <(find docs -type f -name "*.md" -not -name "$(basename docs/how-it-works.md)" \
    -not -path "./.git/*" \
    -not -path "./.signum/*" \
    -not -path "./node_modules/*" \
    -not -path "./tests/fixtures/*" \
    -print0 2>/dev/null | tr '\0' '\n' | head -n 30 | tr '\n' '\0')
fi

# ---------------------------------------------------------------------------
# Phase 2: Convention files (precedence rank 2)
# CLAUDE.md, AGENTS.md
# ---------------------------------------------------------------------------
CLAUDE_MD=$(safe_head "CLAUDE.md" 300)
AGENTS_MD=$(safe_head "AGENTS.md" 300)

# ---------------------------------------------------------------------------
# Phase 3: README (precedence rank 3)
# ---------------------------------------------------------------------------
README=""
for candidate in README.md README.rst README.txt README; do
  if [ -f "$candidate" ]; then
    README=$(safe_head "$candidate" 150)
    break
  fi
done

# ---------------------------------------------------------------------------
# Phase 4: Project manifest (precedence rank 4)
# package.json, pyproject.toml, Cargo.toml
# ---------------------------------------------------------------------------
PKG_JSON=""
PYPROJECT=""
CARGO_TOML=""

if [ -f "package.json" ]; then
  PKG_JSON=$(safe_head "package.json" 100)
fi
if [ -f "pyproject.toml" ]; then
  PYPROJECT=$(safe_head "pyproject.toml" 100)
fi
if [ -f "Cargo.toml" ]; then
  CARGO_TOML=$(safe_head "Cargo.toml" 50)
fi

# ---------------------------------------------------------------------------
# Phase 5: Build/CI signals (precedence rank 5)
# .github/workflows/*.yml, Makefile, justfile, Taskfile.yml
# ---------------------------------------------------------------------------
CI_SIGNALS=""
if [ -d ".github/workflows" ]; then
  for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    content=$(safe_head "$wf" 50)
    CI_SIGNALS="${CI_SIGNALS}
=== $wf ===
$content
"
  done
fi
for runner in Makefile justfile Taskfile.yml tox.ini; do
  if [ -f "$runner" ]; then
    content=$(safe_head "$runner" 60)
    CI_SIGNALS="${CI_SIGNALS}
=== $runner ===
$content
"
  fi
done

# ---------------------------------------------------------------------------
# Phase 6: Public entrypoints (precedence rank 6)
# bin/, commands/, skills/ directories + console_scripts in manifests
# ---------------------------------------------------------------------------
ENTRYPOINTS=""
for ep_dir in bin commands skills; do
  if [ -d "$ep_dir" ]; then
    entries=$(find "$ep_dir" -maxdepth 2 -type f 2>/dev/null | grep -v "__pycache__" | sort || true)
    if [ -n "$entries" ]; then
      ENTRYPOINTS="${ENTRYPOINTS}
=== ${ep_dir}/ ===
$entries
"
    fi
  fi
done

# Extract console_scripts from pyproject.toml
CONSOLE_SCRIPTS=""
if [ -f "pyproject.toml" ]; then
  CONSOLE_SCRIPTS=$(grep -A 20 '\[project.scripts\]' pyproject.toml 2>/dev/null || true)
  if [ -z "$CONSOLE_SCRIPTS" ]; then
    CONSOLE_SCRIPTS=$(grep -A 20 '\[tool.poetry.scripts\]' pyproject.toml 2>/dev/null || true)
  fi
fi

# Extract bin from package.json
PKG_BIN=""
if [ -f "package.json" ]; then
  PKG_BIN=$(python3 -c "
import json, sys
try:
  d = json.load(open('package.json'))
  b = d.get('bin', {})
  if isinstance(b, str):
    print('bin: ' + b)
  elif isinstance(b, dict):
    for k,v in b.items():
      print(k + ': ' + str(v))
except: pass
" 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Phase 7: Git log -- 6 months dirstat (precedence rank 7)
# --dirstat=files --since="6 months ago"
# ---------------------------------------------------------------------------
GIT_LOG=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  GIT_LOG=$(git log --dirstat=files --since="6 months ago" \
    --format="" \
    -- . \
    2>/dev/null | \
    grep -vE '^\s*$' | \
    awk '{print $NF, $0}' | \
    sort -rn | \
    awk '{$1=""; print $0}' | \
    head -50 || true)
fi

# Also get recent commit messages for project activity
GIT_RECENT=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  GIT_RECENT=$(git log --oneline --since="6 months ago" 2>/dev/null | head -30 || true)
fi

# ---------------------------------------------------------------------------
# Phase 8: ADR scan for explicit negative signals (Non-Goals only)
# docs/adr/*.md with status "Rejected" or "Deprecated"
# ---------------------------------------------------------------------------
ADR_SIGNALS=""
if [ -d "docs/adr" ]; then
  for adr in docs/adr/*.md docs/adr/*.rst; do
    [ -f "$adr" ] || continue
    status_line=$(grep -i "^status:" "$adr" 2>/dev/null | head -1 || true)
    if echo "$status_line" | grep -qiE "(rejected|deprecated|superseded|declined|won.t)"; then
      title=$(grep -m1 "^#" "$adr" 2>/dev/null | sed 's/^#\s*//' || basename "$adr")
      ADR_SIGNALS="${ADR_SIGNALS}
REJECTED ADR: $title ($adr)
$status_line
$(grep -i "context\|decision\|consequences" "$adr" 2>/dev/null | head -5 || true)
"
    fi
  done
fi

# README "Not supported" / "Out of scope" / "Limitations" sections
README_NEGATIVE=""
if [ -f "README.md" ]; then
  README_NEGATIVE=$(grep -A 5 -iE "^#{1,3}\s+(not supported|out of scope|limitations|non.?goals?|won.t support|excluded)" README.md 2>/dev/null || true)
fi

CLAUDE_NEGATIVE=""
if [ -f "CLAUDE.md" ]; then
  CLAUDE_NEGATIVE=$(grep -A 3 -iE "^-\s.*(not|never|don.t|avoid|excluded|out.of.scope|prohibited)|^##\s+(non.?goals?|excluded|out.of.scope)" CLAUDE.md 2>/dev/null | head -30 || true)
fi

# ---------------------------------------------------------------------------
# Phase 9: Glossary candidates (module/package names for canonicalTerms)
# Also check for existing project.glossary.json
# ---------------------------------------------------------------------------
EXISTING_GLOSSARY=""
GLOSSARY_FILE=""
for gf in project.glossary.json .signum/project.glossary.json; do
  if [ -f "$gf" ]; then
    EXISTING_GLOSSARY=$(cat "$gf")
    GLOSSARY_FILE="$gf"
    break
  fi
done

# Module-level directories (depth 2, excluding ignore set)
MODULE_DIRS=""
for d in */; do
  d="${d%/}"
  [ -d "$d" ] || continue
  is_ignored "$d" && continue
  case "$d" in
    .|..) continue ;;
  esac
  MODULE_DIRS="${MODULE_DIRS} $d"
done

# Check existing project.intent.md
EXISTING_INTENT=""
INTENT_FILE=""
for inf in project.intent.md .signum/project.intent.md; do
  if [ -f "$inf" ]; then
    EXISTING_INTENT=$(cat "$inf")
    INTENT_FILE="$inf"
    break
  fi
done

# ---------------------------------------------------------------------------
# Assemble output JSON
# canonicalTerms and aliases placeholders for glossary schema (AC6)
# ---------------------------------------------------------------------------
jq -n \
  --arg root "$ROOT_ABS" \
  --arg authoritative_docs "$AUTHORITATIVE_DOCS" \
  --arg docs_deep "$DOCS_DEEP" \
  --arg claude_md "$CLAUDE_MD" \
  --arg agents_md "$AGENTS_MD" \
  --arg readme "$README" \
  --arg pkg_json "$PKG_JSON" \
  --arg pyproject "$PYPROJECT" \
  --arg cargo_toml "$CARGO_TOML" \
  --arg ci_signals "$CI_SIGNALS" \
  --arg entrypoints "$ENTRYPOINTS" \
  --arg console_scripts "$CONSOLE_SCRIPTS" \
  --arg pkg_bin "$PKG_BIN" \
  --arg git_dirstat "$GIT_LOG" \
  --arg git_recent "$GIT_RECENT" \
  --arg adr_signals "$ADR_SIGNALS" \
  --arg readme_negative "$README_NEGATIVE" \
  --arg claude_negative "$CLAUDE_NEGATIVE" \
  --arg existing_glossary "$EXISTING_GLOSSARY" \
  --arg glossary_file "$GLOSSARY_FILE" \
  --arg existing_intent "$EXISTING_INTENT" \
  --arg intent_file "$INTENT_FILE" \
  --arg module_dirs "$MODULE_DIRS" \
  '{
    schemaVersion: "1.0",
    scanTarget: $root,
    signals: {
      authoritative_docs: $authoritative_docs,
      docs_deep: $docs_deep,
      claude_md: $claude_md,
      agents_md: $agents_md,
      readme: $readme,
      package_json: $pkg_json,
      pyproject_toml: $pyproject,
      cargo_toml: $cargo_toml,
      ci_signals: $ci_signals,
      entrypoints: $entrypoints,
      console_scripts: $console_scripts,
      pkg_bin: $pkg_bin,
      git_dirstat: $git_dirstat,
      git_recent: $git_recent,
      adr_signals: $adr_signals,
      readme_negative: $readme_negative,
      claude_negative: $claude_negative,
      module_dirs: $module_dirs
    },
    existingFiles: {
      glossary: {
        path: $glossary_file,
        content: $existing_glossary
      },
      intent: {
        path: $intent_file,
        content: $existing_intent
      }
    },
    glossarySchema: {
      canonicalTerms: [],
      aliases: {}
    }
  }'
