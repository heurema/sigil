#!/usr/bin/env bash
# test-init-harness-scaffold.sh -- tests for lib/init-harness-scaffold.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCAFFOLD="$REPO_ROOT/lib/init-harness-scaffold.sh"
OVERLAY_SCAFFOLD="$REPO_ROOT/platforms/claude-code/lib/init-harness-scaffold.sh"
TEMPLATE_DIR="$REPO_ROOT/lib/templates/init-harness"
OVERLAY_TEMPLATE_DIR="$REPO_ROOT/platforms/claude-code/lib/templates/init-harness"
FIXTURES="$REPO_ROOT/tests/fixtures/init-harness-scaffold"

passed=0
failed=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_pass() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — exited non-zero: %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected to find "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  fi
}

assert_equals() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

assert_json_field() {
  local name="$1" json="$2" field="$3"
  local val
  val=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "")
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    printf '  PASS: %s (%s=%s)\n' "$name" "$field" "${val:0:40}"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — field %s missing or null in JSON\n' "$name" "$field"
    failed=$((failed + 1))
  fi
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — missing file %s\n' "$name" "$path"
    failed=$((failed + 1))
  fi
}

assert_same_file() {
  local name="$1" left="$2" right="$3"
  if cmp -s "$left" "$right"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — files differ: %s %s\n' "$name" "$left" "$right"
    failed=$((failed + 1))
  fi
}

echo "=== Scaffold existence ==="
assert_pass "scaffold file exists" test -f "$SCAFFOLD"
assert_pass "overlay scaffold file exists" test -f "$OVERLAY_SCAFFOLD"
assert_pass "scaffold is executable after chmod" chmod +x "$SCAFFOLD"
assert_same_file "overlay scaffold mirrors root" "$SCAFFOLD" "$OVERLAY_SCAFFOLD"

echo ""
echo "=== Template wiring ==="
for template in \
  agents.md.tmpl \
  architecture.md.tmpl \
  plans.md.tmpl \
  reliability.md.tmpl \
  security.md.tmpl \
  quality-score.md.tmpl; do
  assert_file "template exists: $template" "$TEMPLATE_DIR/$template"
  assert_same_file "overlay template mirrors root: $template" "$TEMPLATE_DIR/$template" "$OVERLAY_TEMPLATE_DIR/$template"
done

if grep -qE 'read -r -d .*[A-Z_]+_CONTENT.*<<EOF' "$SCAFFOLD" \
  || grep -q '## Agent Entry Points' "$SCAFFOLD" \
  || grep -q '## Quality Dimensions' "$SCAFFOLD"; then
  printf '  FAIL: scaffold shell keeps large markdown heredocs\n'
  failed=$((failed + 1))
else
  printf '  PASS: scaffold shell no longer embeds large markdown heredocs\n'
  passed=$((passed + 1))
fi

PROJECT="$WORK/project"
mkdir -p "$PROJECT"

echo ""
echo "=== Basic execution ==="
OUTPUT=$("$SCAFFOLD" --project-root "$PROJECT" --as-of 2026-04-10 2>/dev/null)
assert_pass "scaffold exits 0" "$SCAFFOLD" --project-root "$PROJECT" --as-of 2026-04-10
assert_json_field "schemaVersion field" "$OUTPUT" ".schemaVersion"
assert_json_field "projectRoot field" "$OUTPUT" ".projectRoot"
assert_json_field "projectName field" "$OUTPUT" ".projectName"
assert_json_field "asOf field" "$OUTPUT" ".asOf"

echo ""
echo "=== Scaffold structure ==="
FILE_COUNT=$(echo "$OUTPUT" | jq -r '.files | length')
assert_equals "six scaffold files emitted" "$FILE_COUNT" "6"
assert_contains "docs directory declared" "$(echo "$OUTPUT" | jq -r '.directories | join(",")')" "docs"
assert_equals "missingCount is six for empty project" "$(echo "$OUTPUT" | jq -r '.missingCount')" "6"
assert_equals "existingCount is zero for empty project" "$(echo "$OUTPUT" | jq -r '.existingCount')" "0"

PATHS=$(echo "$OUTPUT" | jq -r '.files[].path')
assert_contains "AGENTS.md path present" "$PATHS" "^AGENTS.md$"
assert_contains "ARCHITECTURE.md path present" "$PATHS" "^ARCHITECTURE.md$"
assert_contains "docs/PLANS.md path present" "$PATHS" "^docs/PLANS.md$"
assert_contains "docs/RELIABILITY.md path present" "$PATHS" "^docs/RELIABILITY.md$"
assert_contains "docs/SECURITY.md path present" "$PATHS" "^docs/SECURITY.md$"
assert_contains "docs/QUALITY_SCORE.md path present" "$PATHS" "^docs/QUALITY_SCORE.md$"

echo ""
echo "=== Scaffold content ==="
AGENTS_CONTENT=$(echo "$OUTPUT" | jq -r '.files[] | select(.path=="AGENTS.md") | .content')
assert_contains "AGENTS content has generated marker" "$AGENTS_CONTENT" "generated by /signum init --harness"
assert_contains "AGENTS content has frontmatter" "$AGENTS_CONTENT" "^---"
assert_contains "AGENTS content has entry points table" "$AGENTS_CONTENT" "## Agent Entry Points"
assert_contains "AGENTS content uses fixed review date" "$AGENTS_CONTENT" "last_reviewed: 2026-04-10"

ARCH_CONTENT=$(echo "$OUTPUT" | jq -r '.files[] | select(.path=="ARCHITECTURE.md") | .content')
assert_contains "ARCHITECTURE content has components section" "$ARCH_CONTENT" "## Components"

QUALITY_CONTENT=$(echo "$OUTPUT" | jq -r '.files[] | select(.path=="docs/QUALITY_SCORE.md") | .content')
assert_contains "QUALITY_SCORE content has quality dimensions table" "$QUALITY_CONTENT" "## Quality Dimensions"

echo ""
echo "=== Golden content ==="
while IFS= read -r expected_file; do
  rel="${expected_file#$FIXTURES/}"
  actual_file="$WORK/generated/$rel"
  mkdir -p "$(dirname "$actual_file")"
  echo "$OUTPUT" | jq -rj --arg path "$rel" '.files[] | select(.path==$path) | .content' > "$actual_file"
  assert_same_file "generated content matches fixture: $rel" "$actual_file" "$expected_file"
done < <(find "$FIXTURES" -type f | sort)

OUTPUT_REPEAT=$("$SCAFFOLD" --project-root "$PROJECT" --as-of 2026-04-10 2>/dev/null)
if diff -u <(printf '%s\n' "$OUTPUT") <(printf '%s\n' "$OUTPUT_REPEAT") >/dev/null; then
  printf '  PASS: repeated scaffold output is stable without writes\n'
  passed=$((passed + 1))
else
  printf '  FAIL: repeated scaffold output changed without writes\n'
  failed=$((failed + 1))
fi

PROJECT_WITH_AMPERSAND="$WORK/project&team"
mkdir -p "$PROJECT_WITH_AMPERSAND"
OUTPUT_SPECIAL=$("$SCAFFOLD" --project-root "$PROJECT_WITH_AMPERSAND" --as-of 2026-04-10 2>/dev/null)
SPECIAL_ARCH_TITLE=$(echo "$OUTPUT_SPECIAL" | jq -r '.files[] | select(.path=="ARCHITECTURE.md") | .content' | grep '^# ')
assert_equals "template substitution preserves ampersand in project name" "$SPECIAL_ARCH_TITLE" "# project&team — Architecture"

echo ""
echo "=== Existing file detection ==="
mkdir -p "$PROJECT/docs"
printf '# Existing\n' > "$PROJECT/AGENTS.md"
printf '# Existing\n' > "$PROJECT/docs/SECURITY.md"
printf '# Target\n' > "$PROJECT/ARCHITECTURE.target.md"
ln -s "ARCHITECTURE.target.md" "$PROJECT/ARCHITECTURE.md"

OUTPUT_WITH_EXISTING=$("$SCAFFOLD" --project-root "$PROJECT" --as-of 2026-04-10 2>/dev/null)
assert_equals "AGENTS exists detected" \
  "$(echo "$OUTPUT_WITH_EXISTING" | jq -r '.files[] | select(.path=="AGENTS.md") | .exists')" "true"
assert_equals "ARCHITECTURE symlink exists detected" \
  "$(echo "$OUTPUT_WITH_EXISTING" | jq -r '.files[] | select(.path=="ARCHITECTURE.md") | .exists')" "true"
assert_equals "SECURITY exists detected" \
  "$(echo "$OUTPUT_WITH_EXISTING" | jq -r '.files[] | select(.path=="docs/SECURITY.md") | .exists')" "true"
assert_equals "missingCount updates when files exist" "$(echo "$OUTPUT_WITH_EXISTING" | jq -r '.missingCount')" "3"
assert_equals "existingCount updates when files exist" "$(echo "$OUTPUT_WITH_EXISTING" | jq -r '.existingCount')" "3"

echo ""
echo "=== Missing template failure ==="
MISSING_CASE="$WORK/missing-template-case"
mkdir -p "$MISSING_CASE/lib/templates/init-harness" "$MISSING_CASE/project"
cp "$SCAFFOLD" "$MISSING_CASE/lib/init-harness-scaffold.sh"
cp "$TEMPLATE_DIR"/*.md.tmpl "$MISSING_CASE/lib/templates/init-harness/"
rm "$MISSING_CASE/lib/templates/init-harness/security.md.tmpl"
if output=$(bash "$MISSING_CASE/lib/init-harness-scaffold.sh" --project-root "$MISSING_CASE/project" --as-of 2026-04-10 2>&1); then
  printf '  FAIL: missing template causes failure — command succeeded unexpectedly\n'
  failed=$((failed + 1))
else
  if printf '%s\n' "$output" | grep -q 'init harness template not found'; then
    printf '  PASS: missing template causes clear failure\n'
    passed=$((passed + 1))
  else
    printf '  FAIL: missing template failure message is unclear — %s\n' "$output"
    failed=$((failed + 1))
  fi
fi

echo ""
echo "=== Results ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
