#!/usr/bin/env bash
# policy-scanner.sh -- deterministic policy scan on combined.patch (zero LLM cost)
# Scans only addition lines (+) in the patch for security, unsafe, and dependency patterns.
# Usage: policy-scanner.sh <patch_file>
# Output: <patch_dir>/policy_scan.json
# Exit 0: scan complete (findings may be empty)
# Exit 1: fatal error (missing tools, missing patch file — writes JSON error + exits non-zero)

set -euo pipefail

PATCH_FILE="${1:-}"
OUTPUT_DIR=""
OUTPUT_PATH=""
SCRIPT_DIR=""
RULE_CATALOG_PATH=""
KNOWN_RULE_IDS=""

if [ -z "$PATCH_FILE" ]; then
  echo "Usage: policy-scanner.sh <patch_file>" >&2
  exit 1
fi

OUTPUT_DIR=$(dirname "$PATCH_FILE")
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="."
OUTPUT_PATH="${OUTPUT_DIR}/policy_scan.json"

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq not found" >&2
  exit 1
fi

if [ ! -f "$PATCH_FILE" ]; then
  echo "ERROR: policy-scanner.sh: patch file not found: $PATCH_FILE" >&2
  mkdir -p "$OUTPUT_DIR"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pf "$PATCH_FILE" \
    '{scannedAt:$ts, patchFile:$pf, error:"missing_combined_patch", findings:[], suppressedFindings:[], rejectedSuppressions:[], summaryCounts:{critical:0,major:0,minor:0,total:0,suppressed:0,rejectedSuppressions:0}}' \
    > "$OUTPUT_PATH"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE_CATALOG_PATH="${SCRIPT_DIR}/policy-rules.json"
if [ ! -f "$RULE_CATALOG_PATH" ]; then
  echo "ERROR: policy rule catalog not found: $RULE_CATALOG_PATH" >&2
  exit 1
fi
KNOWN_RULE_IDS=$(jq -r '.rules[].ruleId' "$RULE_CATALOG_PATH")

SCANNED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------------------
# Parse patch: extract (file, line_number, addition_line) tuples
# Track current file and line counter from patch headers
# ---------------------------------------------------------------------------
TMPDIR_SCAN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SCAN"' EXIT

ADDITIONS_FILE="$TMPDIR_SCAN/additions.tsv"  # file\tline\tcontent

current_file=""
new_line=0

while IFS= read -r raw_line; do
  # Detect file header: diff --git a/foo b/foo
  if printf '%s\n' "$raw_line" | grep -qE '^diff --git '; then
    current_file=$(printf '%s\n' "$raw_line" | sed 's|^diff --git a/||; s| b/.*||')
    new_line=0
    continue
  fi

  # Hunk header: @@ -old_start,old_count +new_start,new_count @@
  if printf '%s\n' "$raw_line" | grep -qE '^@@ '; then
    new_start=$(printf '%s\n' "$raw_line" | sed -n 's/^@@ -[0-9]*\(,[0-9]*\)\? +\([0-9]*\)\(,[0-9]*\)\? @@.*/\2/p')
    if [ -n "$new_start" ]; then
      new_line=$((new_start - 1))
    fi
    continue
  fi

  # Prefer the new-file path from the +++ header when present.
  if printf '%s\n' "$raw_line" | grep -qE '^\+\+\+ b/'; then
    current_file="${raw_line#+++ b/}"
    continue
  fi

  # Skip index/--- /+++ headers
  if printf '%s\n' "$raw_line" | grep -qE '^(index |--- |\+\+\+ |Binary files)'; then
    continue
  fi

  # Context line: increment new_line counter
  if printf '%s\n' "$raw_line" | grep -qE '^ '; then
    new_line=$((new_line + 1))
    continue
  fi

  # Deletion line: do NOT increment new_line counter (deleted lines don't exist in new file)
  if printf '%s\n' "$raw_line" | grep -qE '^-'; then
    continue
  fi

  # Addition line: record it
  if printf '%s\n' "$raw_line" | grep -qE '^\+'; then
    new_line=$((new_line + 1))
    content="${raw_line:1}"  # strip leading '+'
    # Write: file TAB line TAB content
    printf '%s\t%d\t%s\n' "$current_file" "$new_line" "$content" >> "$ADDITIONS_FILE"
    continue
  fi
done < "$PATCH_FILE"

# ---------------------------------------------------------------------------
# Pattern definitions
# Format: RULE_ID|TYPE|SEVERITY|PATTERN_NAME|GREP_REGEX
# ---------------------------------------------------------------------------
declare -a PATTERNS=(
  # security: dynamic code execution (curated sinks, language-aware)
  "POLICY_DYNAMIC_CODE_EXECUTION|security|CRITICAL|dynamic_code_execution|eval\s*\(|new\s+Function\s*\(|__import__\s*\("
  # security: XSS sinks
  "POLICY_XSS_SINK|security|CRITICAL|xss_sink|innerHTML\s*=|outerHTML\s*=|document\.write\s*\(|insertAdjacentHTML\s*\("
  # security: SQL injection (SQL keywords + string concatenation)
  "POLICY_SQL_INJECTION|security|CRITICAL|sql_injection|(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE).*[+%].*['\"]|['\"].*[+%].*(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE)"
  # security: subprocess shell injection (Python + JS + shell)
  "POLICY_SUBPROCESS_SHELL_INJECTION|security|CRITICAL|subprocess_shell_injection|shell\s*=\s*True|subprocess\.(call|run|Popen)\s*\(|os\.system\s*\(|child_process\.(exec|execSync|spawn)\s*\("
  # security: weak crypto
  "POLICY_WEAK_CRYPTO|security|MAJOR|weak_crypto|md5\s*\(|sha1\s*\(|DES\.|RC4\.|hashlib\.md5|hashlib\.sha1"
  # unsafe: unchecked any-type (TypeScript)
  "POLICY_UNCHECKED_ANY|unsafe|MINOR|unchecked_any|:\s*any\b|as\s+any\b"
  # unsafe: incomplete implementation markers (CRITICAL — direct incident class)
  "POLICY_INCOMPLETE_MARKER|unsafe|CRITICAL|incomplete_implementation|TODO:|FIXME:|HACK:|XXX:"
  # unsafe: incomplete implementation via code patterns
  "POLICY_INCOMPLETE_STUB|unsafe|CRITICAL|incomplete_implementation|panic\(\"not implemented\"\)|panic\(\"todo\"\)|raise\s+NotImplementedError|throw\s+new\s+Error\(\"TODO\"\)"
  # unsafe: suspicious nil/null returns
  "POLICY_SUSPICIOUS_RETURN|unsafe|MINOR|suspicious_return|return nil\s*//|return nil\s*$|return null\s*//\s*TODO"
  # unsafe: debug statements (no generic print — too noisy)
  "POLICY_DEBUG_PRINT|unsafe|MINOR|debug_print|console\.log\s*\(|debugger\s*;|pprint\s*\(|console\.debug\s*\("
  # dependency: new package entry in package.json (quoted name followed by quoted version)
  "POLICY_NEW_NPM_DEPENDENCY|dependency|MAJOR|new_npm_dependency|\"[a-zA-Z0-9@/_-]+\"\s*:\s*\"[~^]?[0-9*]"
  # dependency: new crate entry in Cargo.toml (bare crate-name = version line)
  "POLICY_NEW_CARGO_DEPENDENCY|dependency|MAJOR|new_cargo_dependency|^[a-zA-Z0-9_-]+\s*=\s*[\"{]"
  # dependency: new package entry in pyproject.toml (quoted or bare package with optional version specifier)
  "POLICY_NEW_PYTHON_DEPENDENCY|dependency|MAJOR|new_python_dependency|\"[a-zA-Z0-9_.-]+[><=!~]|'[a-zA-Z0-9_.-]+[><=!~]|^\s*[a-zA-Z0-9_.-]+[><=!~]"
  # dependency: new require entry in go.mod (module path with vN.N.N version)
  "POLICY_NEW_GO_DEPENDENCY|dependency|MAJOR|new_go_dependency|[a-z][a-zA-Z0-9._/-]*/[a-zA-Z0-9_-]+\s+v[0-9]+\.[0-9]"
)

rule_id_known() {
  local rule_id="${1:-}"
  [ -n "$rule_id" ] || return 1
  printf '%s\n' "$KNOWN_RULE_IDS" | grep -Fxq "$rule_id"
}

trim_policy_reason() {
  printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

json_string_length() {
  local value="${1:-}"
  jq -nr --arg value "$value" '$value | length'
}

dependency_rule_in_scope() {
  local rule_id="${1:-}"
  local file="${2:-}"
  local basename=""

  basename=$(basename "$file")

  case "$file" in
    docs/*|examples/*|fixtures/*|tests/*|test/*) return 1 ;;
  esac

  case "$rule_id" in
    POLICY_NEW_NPM_DEPENDENCY)
      case "$basename" in
        package.json|package-lock.json|npm-shrinkwrap.json|pnpm-lock.yaml|yarn.lock) return 0 ;;
      esac
      ;;
    POLICY_NEW_CARGO_DEPENDENCY)
      case "$basename" in
        Cargo.toml|Cargo.lock) return 0 ;;
      esac
      ;;
    POLICY_NEW_PYTHON_DEPENDENCY)
      case "$basename" in
        requirements*.txt|pyproject.toml|poetry.lock|Pipfile|Pipfile.lock|setup.py|setup.cfg) return 0 ;;
      esac
      ;;
    POLICY_NEW_GO_DEPENDENCY)
      case "$basename" in
        go.mod|go.sum) return 0 ;;
      esac
      ;;
  esac

  return 1
}

# ---------------------------------------------------------------------------
# Parse suppression markers before applying findings.
# Syntax: SIGNUM_POLICY_ALLOW:<RULE_ID>:<reason>
# Scope: same added line and the next added line in the same file only.
# ---------------------------------------------------------------------------
SUPPRESSIONS_NDJSON="$TMPDIR_SCAN/suppressions.ndjson"
REJECTED_SUPPRESSIONS_NDJSON="$TMPDIR_SCAN/rejected_suppressions.ndjson"
touch "$SUPPRESSIONS_NDJSON" "$REJECTED_SUPPRESSIONS_NDJSON"

if [ -f "$ADDITIONS_FILE" ]; then
  declare -a ADDITION_ROWS=()
  while IFS= read -r addition_row; do
    ADDITION_ROWS+=("$addition_row")
  done < "$ADDITIONS_FILE"
  for ((i = 0; i < ${#ADDITION_ROWS[@]}; i++)); do
    IFS=$'\t' read -r s_file s_line s_content <<< "${ADDITION_ROWS[$i]}"
    if [[ "$s_content" != *"SIGNUM_POLICY_ALLOW:"* ]]; then
      continue
    fi

    marker_tail="${s_content#*SIGNUM_POLICY_ALLOW:}"
    marker_rule="${marker_tail%%:*}"
    if [[ "$marker_tail" == "$marker_rule" ]]; then
      marker_reason=""
    else
      marker_reason="${marker_tail#*:}"
    fi
    marker_reason=$(trim_policy_reason "$marker_reason")
    reason_len=$(json_string_length "$marker_reason")
    rejected_reason=""

    if ! printf '%s\n' "$marker_rule" | grep -qE '^POLICY_[A-Z0-9_]+$'; then
      rejected_reason="invalid_rule_id"
    elif ! rule_id_known "$marker_rule"; then
      rejected_reason="unknown_rule_id"
    elif [ -z "$marker_reason" ]; then
      rejected_reason="missing_reason"
    elif [ "$reason_len" -lt 10 ]; then
      rejected_reason="reason_too_short"
    fi

    if [ -n "$rejected_reason" ]; then
      jq -n \
        --arg ruleId "$marker_rule" \
        --arg file "$s_file" \
        --argjson line "$s_line" \
        --arg reason "$marker_reason" \
        --arg rejectedReason "$rejected_reason" \
        '{ruleId:$ruleId,file:$file,line:$line,reason:$reason,rejectedReason:$rejectedReason}' \
        >> "$REJECTED_SUPPRESSIONS_NDJSON"
      continue
    fi

    jq -n \
      --arg ruleId "$marker_rule" \
      --arg file "$s_file" \
      --argjson markerLine "$s_line" \
      --argjson targetLine "$s_line" \
      --arg reason "$marker_reason" \
      '{ruleId:$ruleId,file:$file,markerLine:$markerLine,targetLine:$targetLine,scope:"same-line",reason:$reason}' \
      >> "$SUPPRESSIONS_NDJSON"

    if [ $((i + 1)) -lt "${#ADDITION_ROWS[@]}" ]; then
      IFS=$'\t' read -r next_file next_line _next_content <<< "${ADDITION_ROWS[$((i + 1))]}"
      if [ "$next_file" = "$s_file" ]; then
        jq -n \
          --arg ruleId "$marker_rule" \
          --arg file "$s_file" \
          --argjson markerLine "$s_line" \
          --argjson targetLine "$next_line" \
          --arg reason "$marker_reason" \
          '{ruleId:$ruleId,file:$file,markerLine:$markerLine,targetLine:$targetLine,scope:"next-added-line",reason:$reason}' \
          >> "$SUPPRESSIONS_NDJSON"
      fi
    fi
  done
fi

SUPPRESSIONS_FILE="$TMPDIR_SCAN/suppressions.json"
if [ -s "$SUPPRESSIONS_NDJSON" ]; then
  jq -s '.' "$SUPPRESSIONS_NDJSON" > "$SUPPRESSIONS_FILE"
else
  echo "[]" > "$SUPPRESSIONS_FILE"
fi

# ---------------------------------------------------------------------------
# Scan addition lines against each pattern and collect findings as NDJSON
# ---------------------------------------------------------------------------
FINDINGS_NDJSON="$TMPDIR_SCAN/findings.ndjson"
SUPPRESSED_FINDINGS_NDJSON="$TMPDIR_SCAN/suppressed_findings.ndjson"
touch "$FINDINGS_NDJSON" "$SUPPRESSED_FINDINGS_NDJSON"

if [ -f "$ADDITIONS_FILE" ]; then
  while IFS=$'\t' read -r f_file f_line f_content; do
    f_basename=$(basename "$f_file")
    for pattern_def in "${PATTERNS[@]}"; do
      IFS='|' read -r p_rule_id p_type p_severity p_name p_regex <<< "$pattern_def"

      # Dependency patterns: only match in manifest files
      if [ "$p_type" = "dependency" ]; then
        dependency_rule_in_scope "$p_rule_id" "$f_file" || continue
      fi

      # incomplete_implementation patterns: skip non-code files (docs, tests, configs, examples)
      if [ "$p_name" = "incomplete_implementation" ]; then
        case "$f_file" in
          *.md|*.txt|*.rst|*.yml|*.yaml|*.toml|*.json|*.xml) continue ;;
        esac
        case "$f_file" in
          docs/*|examples/*|fixtures/*|tests/*|test/*|*.example|*.sample) continue ;;
        esac
        case "$f_basename" in
          *_test.*|*.test.*|*.spec.*|test_*.*|*_spec.*) continue ;;
        esac
      fi

      if printf '%s\n' "$f_content" | grep -qE -- "$p_regex"; then
        matched_suppression=$(jq -c \
          --arg file "$f_file" \
          --arg ruleId "$p_rule_id" \
          --argjson line "$f_line" \
          '[.[] | select(.file == $file and .ruleId == $ruleId and .targetLine == $line)][0] // empty' \
          "$SUPPRESSIONS_FILE")
        if [ -n "$matched_suppression" ] && [ "$matched_suppression" != "null" ]; then
          if [ "$p_severity" = "CRITICAL" ]; then
            echo "$matched_suppression" | jq -c \
              --arg rejectedReason "critical_not_suppressible" \
              --arg severity "$p_severity" \
              '. + {rejectedReason:$rejectedReason,severity:$severity}' \
              >> "$REJECTED_SUPPRESSIONS_NDJSON"
          else
            # Emit suppressed finding separately; active findings/counts exclude it.
            jq -n \
              --arg ruleId "$p_rule_id" \
              --arg type "$p_type" \
              --arg pattern "$p_name" \
              --arg file "$f_file" \
              --argjson line "$f_line" \
              --arg snippet "$f_content" \
              --arg severity "$p_severity" \
              --argjson suppression "$matched_suppression" \
              '{ruleId: $ruleId, type: $type, pattern: $pattern, file: $file, line: $line, snippet: $snippet, severity: $severity,
                suppressionReason: $suppression.reason, suppressionLine: $suppression.markerLine, suppressionScope: $suppression.scope}' \
              >> "$SUPPRESSED_FINDINGS_NDJSON"
            continue
          fi
        fi

        # Emit one JSON object per line — no array rebuild on each hit
        jq -n \
          --arg ruleId "$p_rule_id" \
          --arg type "$p_type" \
          --arg pattern "$p_name" \
          --arg file "$f_file" \
          --argjson line "$f_line" \
          --arg snippet "$f_content" \
          --arg severity "$p_severity" \
          '{ruleId: $ruleId, type: $type, pattern: $pattern, file: $file, line: $line, snippet: $snippet, severity: $severity}' \
          >> "$FINDINGS_NDJSON"
      fi
    done
  done < "$ADDITIONS_FILE"
fi

# Build findings array in a single batch operation
FINDINGS_FILE="$TMPDIR_SCAN/findings.json"
if [ -s "$FINDINGS_NDJSON" ]; then
  jq -s '.' "$FINDINGS_NDJSON" > "$FINDINGS_FILE"
else
  echo "[]" > "$FINDINGS_FILE"
fi

SUPPRESSED_FINDINGS_FILE="$TMPDIR_SCAN/suppressed_findings.json"
if [ -s "$SUPPRESSED_FINDINGS_NDJSON" ]; then
  jq -s '.' "$SUPPRESSED_FINDINGS_NDJSON" > "$SUPPRESSED_FINDINGS_FILE"
else
  echo "[]" > "$SUPPRESSED_FINDINGS_FILE"
fi

REJECTED_SUPPRESSIONS_FILE="$TMPDIR_SCAN/rejected_suppressions.json"
if [ -s "$REJECTED_SUPPRESSIONS_NDJSON" ]; then
  jq -s '.' "$REJECTED_SUPPRESSIONS_NDJSON" > "$REJECTED_SUPPRESSIONS_FILE"
else
  echo "[]" > "$REJECTED_SUPPRESSIONS_FILE"
fi

# ---------------------------------------------------------------------------
# Compute summary counts
# ---------------------------------------------------------------------------
COUNTS=$(jq -n \
  --argjson findings "$(cat "$FINDINGS_FILE")" \
  --argjson suppressed "$(cat "$SUPPRESSED_FINDINGS_FILE")" \
  --argjson rejected "$(cat "$REJECTED_SUPPRESSIONS_FILE")" \
  '{
    critical: ([ $findings[] | select(.severity == "CRITICAL") ] | length),
    major:    ([ $findings[] | select(.severity == "MAJOR") ]    | length),
    minor:    ([ $findings[] | select(.severity == "MINOR") ]    | length),
    total:    ($findings | length),
    suppressed: ($suppressed | length),
    rejectedSuppressions: ($rejected | length)
  }')

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
jq -n \
  --arg scannedAt "$SCANNED_AT" \
  --arg patchFile "$PATCH_FILE" \
  --argjson findings "$(cat "$FINDINGS_FILE")" \
  --argjson suppressedFindings "$(cat "$SUPPRESSED_FINDINGS_FILE")" \
  --argjson rejectedSuppressions "$(cat "$REJECTED_SUPPRESSIONS_FILE")" \
  --argjson summaryCounts "$COUNTS" \
  '{
    scannedAt: $scannedAt,
    patchFile: $patchFile,
    findings: $findings,
    suppressedFindings: $suppressedFindings,
    rejectedSuppressions: $rejectedSuppressions,
    summaryCounts: $summaryCounts
  }' > "$OUTPUT_PATH"

TOTAL=$(echo "$COUNTS" | jq -r '.total')
CRITICAL=$(echo "$COUNTS" | jq -r '.critical')
MAJOR=$(echo "$COUNTS" | jq -r '.major')
MINOR=$(echo "$COUNTS" | jq -r '.minor')

echo "Policy scan done: $TOTAL findings (critical=$CRITICAL major=$MAJOR minor=$MINOR)"
