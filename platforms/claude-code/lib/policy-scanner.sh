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
    '{scannedAt:$ts, patchFile:$pf, error:"missing_combined_patch", findings:[], summaryCounts:{critical:0,major:0,minor:0,total:0}}' \
    > "$OUTPUT_PATH"
  exit 1
fi

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
# Format: TYPE|SEVERITY|PATTERN_NAME|GREP_REGEX
# ---------------------------------------------------------------------------
declare -a PATTERNS=(
  # security: dynamic code execution (curated sinks, language-aware)
  "security|CRITICAL|dynamic_code_execution|eval\s*\(|new\s+Function\s*\(|__import__\s*\("
  # security: XSS sinks
  "security|CRITICAL|xss_sink|innerHTML\s*=|outerHTML\s*=|document\.write\s*\(|insertAdjacentHTML\s*\("
  # security: SQL injection (SQL keywords + string concatenation)
  "security|CRITICAL|sql_injection|(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE).*[+%].*['\"]|['\"].*[+%].*(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE)"
  # security: subprocess shell injection (Python + JS + shell)
  "security|CRITICAL|subprocess_shell_injection|shell\s*=\s*True|subprocess\.(call|run|Popen)\s*\(|os\.system\s*\(|child_process\.(exec|execSync|spawn)\s*\("
  # security: weak crypto
  "security|MAJOR|weak_crypto|md5\s*\(|sha1\s*\(|DES\.|RC4\.|hashlib\.md5|hashlib\.sha1"
  # unsafe: unchecked any-type (TypeScript)
  "unsafe|MINOR|unchecked_any|:\s*any\b|as\s+any\b"
  # unsafe: incomplete implementation markers (CRITICAL — direct incident class)
  "unsafe|CRITICAL|incomplete_implementation|TODO:|FIXME:|HACK:|XXX:"
  # unsafe: incomplete implementation via code patterns
  "unsafe|CRITICAL|incomplete_implementation|panic\(\"not implemented\"\)|panic\(\"todo\"\)|raise\s+NotImplementedError|throw\s+new\s+Error\(\"TODO\"\)"
  # unsafe: suspicious nil/null returns
  "unsafe|MINOR|suspicious_return|return nil\s*//|return nil\s*$|return null\s*//\s*TODO"
  # unsafe: debug statements (no generic print — too noisy)
  "unsafe|MINOR|debug_print|console\.log\s*\(|debugger\s*;|pprint\s*\(|console\.debug\s*\("
  # dependency: new package entry in package.json (quoted name followed by quoted version)
  "dependency|MAJOR|new_npm_dependency|\"[a-zA-Z0-9@/_-]+\"\s*:\s*\"[~^]?[0-9*]"
  # dependency: new crate entry in Cargo.toml (bare crate-name = version line)
  "dependency|MAJOR|new_cargo_dependency|^[a-zA-Z0-9_-]+\s*=\s*[\"{]"
  # dependency: new package entry in pyproject.toml (quoted or bare package with optional version specifier)
  "dependency|MAJOR|new_python_dependency|\"[a-zA-Z0-9_.-]+[><=!~]|'[a-zA-Z0-9_.-]+[><=!~]|^\s*[a-zA-Z0-9_.-]+[><=!~]"
  # dependency: new require entry in go.mod (module path with vN.N.N version)
  "dependency|MAJOR|new_go_dependency|[a-z][a-zA-Z0-9._/-]*/[a-zA-Z0-9_-]+\s+v[0-9]+\.[0-9]"
)

# ---------------------------------------------------------------------------
# Scan addition lines against each pattern and collect findings as NDJSON
# ---------------------------------------------------------------------------
FINDINGS_NDJSON="$TMPDIR_SCAN/findings.ndjson"
touch "$FINDINGS_NDJSON"

if [ -f "$ADDITIONS_FILE" ]; then
  while IFS=$'\t' read -r f_file f_line f_content; do
    f_basename=$(basename "$f_file")
    for pattern_def in "${PATTERNS[@]}"; do
      IFS='|' read -r p_type p_severity p_name p_regex <<< "$pattern_def"

      # Dependency patterns: only match in manifest files
      if [ "$p_type" = "dependency" ]; then
        case "$f_basename" in
          package.json|Cargo.toml|pyproject.toml|go.mod|go.sum) ;;
          *) continue ;;
        esac
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
        # Emit one JSON object per line — no array rebuild on each hit
        jq -n \
          --arg type "$p_type" \
          --arg pattern "$p_name" \
          --arg file "$f_file" \
          --argjson line "$f_line" \
          --arg snippet "$f_content" \
          --arg severity "$p_severity" \
          '{type: $type, pattern: $pattern, file: $file, line: $line, snippet: $snippet, severity: $severity}' \
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

# ---------------------------------------------------------------------------
# Compute summary counts
# ---------------------------------------------------------------------------
COUNTS=$(jq '{
  critical: ([.[] | select(.severity == "CRITICAL")] | length),
  major:    ([.[] | select(.severity == "MAJOR")]    | length),
  minor:    ([.[] | select(.severity == "MINOR")]    | length),
  total:    length
}' "$FINDINGS_FILE")

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
jq -n \
  --arg scannedAt "$SCANNED_AT" \
  --arg patchFile "$PATCH_FILE" \
  --argjson findings "$(cat "$FINDINGS_FILE")" \
  --argjson summaryCounts "$COUNTS" \
  '{
    scannedAt: $scannedAt,
    patchFile: $patchFile,
    findings: $findings,
    summaryCounts: $summaryCounts
  }' > "$OUTPUT_PATH"

TOTAL=$(echo "$COUNTS" | jq -r '.total')
CRITICAL=$(echo "$COUNTS" | jq -r '.critical')
MAJOR=$(echo "$COUNTS" | jq -r '.major')
MINOR=$(echo "$COUNTS" | jq -r '.minor')

echo "Policy scan done: $TOTAL findings (critical=$CRITICAL major=$MAJOR minor=$MINOR)"
