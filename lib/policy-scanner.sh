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
RULE_CATALOG_OVERRIDE=""
PATTERN_CATALOG_OVERRIDE=""
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

SCANNED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

validate_policy_rule_catalog() {
  local catalog_path="${1:-}"
  local validation_errors=""
  local regex_syntax_errors=""

  if [ -z "$catalog_path" ]; then
    echo "ERROR: policy rule catalog path is empty" >&2
    return 1
  fi
  if [ ! -f "$catalog_path" ]; then
    echo "ERROR: policy rule catalog not found: $catalog_path" >&2
    return 1
  fi
  if ! jq empty "$catalog_path" >/dev/null 2>&1; then
    echo "ERROR: policy rule catalog is not valid JSON: $catalog_path" >&2
    return 1
  fi

  if ! validation_errors=$(jq -r '
    def nonempty_string: type == "string" and length > 0;
    def string_array:
      type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    def string_array_without_tabs:
      type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\t") | not));
    [
      (if type != "object" then "top-level object required" else empty end),
      (if type == "object" and (has("schemaVersion") | not) then "schemaVersion missing" else empty end),
      (if type == "object" and ((.rules | type) != "array" or (.rules | length) == 0) then "rules must be a non-empty array" else empty end),
      (if type == "object" and (.rules | type) == "array" then
        (
          .rules
          | to_entries[]
          | .key as $i
          | .value as $r
          | (
              if ($r | type) != "object" then
                "rules[\($i)] must be object"
              else empty end
            ),
            (
              [
                "ruleId",
                "type",
                "severity",
                "pattern",
                "autoBlock",
                "description",
                "fixture",
                "engine",
                "regex",
                "suppressible"
              ][]
              | . as $field
              | if (($r | type) != "object" or ($r | has($field) | not)) then
                  "rules[\($i)] missing \($field)"
                else empty end
            ),
            (if (($r.ruleId? | nonempty_string) and ($r.ruleId | test("^POLICY_[A-Z0-9_]+$"))) then empty else "rules[\($i)] invalid ruleId" end),
            (if ($r.type? | nonempty_string) then empty else "rules[\($i)] invalid type" end),
            (if (($r.severity? | type) == "string" and (["CRITICAL", "MAJOR", "MINOR"] | index($r.severity))) then empty else "rules[\($i)] invalid severity" end),
            (if ($r.pattern? | nonempty_string) then empty else "rules[\($i)] invalid pattern" end),
            (if ($r.description? | nonempty_string) then empty else "rules[\($i)] invalid description" end),
            (if ($r.fixture? | nonempty_string) then empty else "rules[\($i)] invalid fixture" end),
            (if $r.engine? == "regex" then empty else "rules[\($i)] engine must be regex" end),
            (if ($r.regex? | nonempty_string) then empty else "rules[\($i)] invalid regex" end),
            (if (($r.regex? | type) == "string" and ($r.regex | contains("\t"))) then "rules[\($i)] regex contains literal tab" else empty end),
            (if ($r.autoBlock? | type) == "boolean" then empty else "rules[\($i)] invalid autoBlock" end),
            (if ($r.suppressible? | type) == "boolean" then empty else "rules[\($i)] invalid suppressible" end),
            (if (($r.autoBlock? | type) == "boolean" and ($r.severity? | type) == "string" and ($r.autoBlock == ($r.severity == "CRITICAL"))) then empty else "rules[\($i)] autoBlock must match CRITICAL severity" end),
            (if ($r.severity? == "CRITICAL" and $r.suppressible? != false) then "rules[\($i)] CRITICAL rule must not be suppressible" else empty end),
            (if ($r.severity? != "CRITICAL" and ($r.suppressible? | type) == "boolean" and $r.suppressible != true) then "rules[\($i)] non-critical rule must be suppressible" else empty end),
            (if ($r | has("fileScope")) and (($r.fileScope | string_array_without_tabs) | not) then "rules[\($i)] invalid fileScope" else empty end),
            (if ($r | has("excludedPathPrefixes")) and (($r.excludedPathPrefixes | string_array_without_tabs) | not) then "rules[\($i)] invalid excludedPathPrefixes" else empty end),
            (if $r.type? == "dependency" and (($r.fileScope? | string_array_without_tabs) | not) then "rules[\($i)] dependency rule requires fileScope" else empty end),
            (if $r.type? == "dependency" and (($r.excludedPathPrefixes? | string_array_without_tabs) | not) then "rules[\($i)] dependency rule requires excludedPathPrefixes" else empty end)
        ),
        (
          .rules
          | map(select(type == "object" and (.ruleId? | type) == "string") | .ruleId)
          | group_by(.)
          | map(select(length > 1) | .[0])
          | .[]
          | "duplicate ruleId: \(.)"
        )
      else empty end)
    ]
    | .[]
  ' "$catalog_path"); then
    echo "ERROR: policy rule catalog validation failed: $catalog_path" >&2
    return 1
  fi

  if [ -n "$validation_errors" ]; then
    echo "ERROR: policy rule catalog validation failed: $catalog_path" >&2
    printf '%s\n' "$validation_errors" >&2
    return 1
  fi

  regex_syntax_errors=$(jq -r '.rules[] | "\(.ruleId)\t\(.regex)"' "$catalog_path" | while IFS=$'\t' read -r rule_id regex; do
    local grep_status=0
    set +e
    printf '' | grep -Eq -- "$regex" >/dev/null 2>&1
    grep_status=$?
    set -e
    if [ "$grep_status" -eq 2 ]; then
      printf 'rule %s has invalid regex syntax\n' "$rule_id"
    fi
  done)

  if [ -n "$regex_syntax_errors" ]; then
    echo "ERROR: policy rule catalog validation failed: $catalog_path" >&2
    printf '%s\n' "$regex_syntax_errors" >&2
    return 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE_CATALOG_OVERRIDE="${SIGNUM_POLICY_RULE_CATALOG:-}"
PATTERN_CATALOG_OVERRIDE="${SIGNUM_POLICY_PATTERN_CATALOG:-}"
if [ -n "$RULE_CATALOG_OVERRIDE" ] && [ -n "$PATTERN_CATALOG_OVERRIDE" ]; then
  echo "ERROR: set only one of SIGNUM_POLICY_RULE_CATALOG or SIGNUM_POLICY_PATTERN_CATALOG" >&2
  exit 1
elif [ -n "$RULE_CATALOG_OVERRIDE" ]; then
  RULE_CATALOG_PATH="$RULE_CATALOG_OVERRIDE"
elif [ -n "$PATTERN_CATALOG_OVERRIDE" ]; then
  RULE_CATALOG_PATH="$PATTERN_CATALOG_OVERRIDE"
else
  RULE_CATALOG_PATH="${SCRIPT_DIR}/policy-rules.json"
fi

validate_policy_rule_catalog "$RULE_CATALOG_PATH"
KNOWN_RULE_IDS=$(jq -r '.rules[].ruleId' "$RULE_CATALOG_PATH")

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
# Pattern definitions are loaded from the policy rule catalog.
# Runtime format:
# RULE_ID<TAB>TYPE<TAB>SEVERITY<TAB>PATTERN<TAB>GREP_REGEX<TAB>SUPPRESSIBLE<TAB>EXCLUDED_PATH_PREFIXES<TAB>FILE_SCOPE
# ---------------------------------------------------------------------------
declare -a PATTERNS=()
while IFS= read -r pattern_def; do
  PATTERNS+=("$pattern_def")
done < <(jq -r '.rules[] | "\(.ruleId)\t\(.type)\t\(.severity)\t\(.pattern)\t\(.regex)\t\(.suppressible)\t\((.excludedPathPrefixes // []) | join("\u001c"))\t\((.fileScope // []) | join("\u001c"))"' "$RULE_CATALOG_PATH")

if [ "${#PATTERNS[@]}" -eq 0 ]; then
  echo "ERROR: policy rule catalog has no runtime patterns: $RULE_CATALOG_PATH" >&2
  exit 1
fi

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

path_has_excluded_prefix() {
  local file="${1:-}"
  local excluded_prefixes="${2:-}"
  local prefix=""
  local old_ifs="$IFS"

  [ -n "$excluded_prefixes" ] || return 1

  IFS=$'\034'
  for prefix in $excluded_prefixes; do
    [ -n "$prefix" ] || continue
    case "$file" in
      "$prefix"*)
        IFS="$old_ifs"
        return 0
        ;;
    esac
  done
  IFS="$old_ifs"
  return 1
}

rule_file_scope_allows() {
  local file="${1:-}"
  local file_scope="${2:-}"
  local basename=""
  local scope_pattern=""
  local old_ifs="$IFS"

  [ -n "$file_scope" ] || return 0
  basename=$(basename "$file")

  IFS=$'\034'
  for scope_pattern in $file_scope; do
    [ -n "$scope_pattern" ] || continue
    case "$basename" in
      $scope_pattern)
        IFS="$old_ifs"
        return 0
        ;;
    esac
  done

  IFS="$old_ifs"
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
      IFS=$'\t' read -r p_rule_id p_type p_severity p_name p_regex p_suppressible p_excluded_prefixes p_file_scope <<< "$pattern_def"

      if path_has_excluded_prefix "$f_file" "$p_excluded_prefixes"; then
        continue
      fi

      # Dependency patterns: only match in manifest files
      if [ "$p_type" = "dependency" ]; then
        rule_file_scope_allows "$f_file" "$p_file_scope" || continue
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
          if [ "$p_suppressible" != "true" ]; then
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
