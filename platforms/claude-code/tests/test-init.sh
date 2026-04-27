#!/usr/bin/env bash
# test-init.sh -- tests for lib/init-scanner.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCANNER="$SCRIPT_DIR/../lib/init-scanner.sh"
SCANNER_IMPL="$SCRIPT_DIR/../scripts/init_scanner.py"

passed=0
failed=0

WORK=$(mktemp -d)
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

assert_fail() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    printf '  FAIL: %s — expected failure, got exit 0\n' "$name"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected to find "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    printf '  FAIL: %s — found "%s" but should not have\n' "$name" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
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

# ---------------------------------------------------------------------------
# Setup: minimal test project
# ---------------------------------------------------------------------------
setup_project() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "$dir/README.md" << 'EOF'
# TestProject

A test project for signum init.

## Features
- Feature A
- Feature B

## Not supported
- Legacy API v1
- Windows XP

## Installation
```
npm install
```
EOF

  cat > "$dir/package.json" << 'EOF'
{
  "name": "testproject",
  "version": "1.0.0",
  "description": "A test project",
  "scripts": {
    "test": "jest",
    "build": "tsc"
  },
  "bin": {
    "testproject": "bin/cli.js"
  }
}
EOF

  cat > "$dir/CLAUDE.md" << 'EOF'
# TestProject Claude Config

## Build
npm run build

## Never do
- Never commit secrets
- Don't modify dist/ directly
EOF

  mkdir -p "$dir/bin"
  echo '#!/usr/bin/env node' > "$dir/bin/cli.js"

  mkdir -p "$dir/commands"
  echo '# test command' > "$dir/commands/test.md"

  mkdir -p "$dir/docs"
  cat > "$dir/docs/how-it-works.md" << 'EOF'
# How TestProject Works

TestProject is an evidence-driven testing pipeline.

## Architecture
The pipeline runs: SCAN → ANALYZE → REPORT
EOF

  mkdir -p "$dir/docs/adr"
  cat > "$dir/docs/adr/001-rejected-feature.md" << 'EOF'
# ADR 001: Legacy XML Support

Status: Rejected

## Context
Users requested XML output format.

## Decision
Rejected: JSON is the only supported output format.
EOF

  # Create ignored directories with content that should NOT appear in output
  mkdir -p "$dir/node_modules/somelib"
  echo "should not be scanned" > "$dir/node_modules/somelib/index.js"

  mkdir -p "$dir/.signum"
  echo '{"secret": "should not be scanned"}' > "$dir/.signum/contract.json"

  mkdir -p "$dir/dist"
  echo "compiled output" > "$dir/dist/output.js"

  mkdir -p "$dir/tests/fixtures"
  echo "fixture data" > "$dir/tests/fixtures/data.json"

  mkdir -p "$dir/build"
  echo "build artifact" > "$dir/build/app.js"

  # Init git repo for git log test
  cd "$dir"
  git init -q 2>/dev/null || true
  git config user.email "test@test.com" 2>/dev/null || true
  git config user.name "Test" 2>/dev/null || true
  git add -A 2>/dev/null || true
  git commit -q -m "initial commit" 2>/dev/null || true
  cd - > /dev/null
}

PROJECT="$WORK/project"
setup_project "$PROJECT"

# ---------------------------------------------------------------------------
# Test: scanner exists and is executable
# ---------------------------------------------------------------------------
echo "=== Scanner existence ==="
assert_pass "scanner file exists" test -f "$SCANNER"
assert_pass "scanner implementation exists" test -f "$SCANNER_IMPL"
assert_pass "scanner is executable after chmod" chmod +x "$SCANNER"

# ---------------------------------------------------------------------------
# Test: scanner runs and outputs valid JSON
# ---------------------------------------------------------------------------
echo ""
echo "=== Basic execution ==="
SCAN_OUTPUT=$("$SCANNER" --project-root "$PROJECT" 2>/dev/null)
assert_pass "scanner exits 0" "$SCANNER" --project-root "$PROJECT"
assert_contains "output is JSON (starts with {)" "$SCAN_OUTPUT" "^{"

# ---------------------------------------------------------------------------
# Test: JSON schema fields present
# ---------------------------------------------------------------------------
echo ""
echo "=== Output schema ==="
assert_json_field "schemaVersion field" "$SCAN_OUTPUT" ".schemaVersion"
assert_json_field "scanTarget field" "$SCAN_OUTPUT" ".scanTarget"
assert_json_field "signals field" "$SCAN_OUTPUT" ".signals"
assert_json_field "readme signal" "$SCAN_OUTPUT" ".signals.readme"
assert_json_field "entrypoints signal" "$SCAN_OUTPUT" ".signals.entrypoints"
assert_json_field "git_dirstat signal" "$SCAN_OUTPUT" ".signals.git_dirstat"
assert_json_field "glossarySchema field" "$SCAN_OUTPUT" ".glossarySchema"
assert_json_field "glossarySchema.canonicalTerms" "$SCAN_OUTPUT" ".glossarySchema.canonicalTerms"
assert_json_field "glossarySchema.aliases" "$SCAN_OUTPUT" ".glossarySchema.aliases"

# ---------------------------------------------------------------------------
# Test: source content is captured
# ---------------------------------------------------------------------------
echo ""
echo "=== Signal content ==="
README_SIG=$(echo "$SCAN_OUTPUT" | jq -r '.signals.readme')
assert_contains "README captured" "$README_SIG" "TestProject"
assert_contains "README features captured" "$README_SIG" "Feature A"

CLAUDE_SIG=$(echo "$SCAN_OUTPUT" | jq -r '.signals.claude_md')
assert_contains "CLAUDE.md captured" "$CLAUDE_SIG" "Build"

AUTH_DOCS=$(echo "$SCAN_OUTPUT" | jq -r '.signals.authoritative_docs')
assert_contains "docs/how-it-works.md captured" "$AUTH_DOCS" "evidence-driven"

ADR_SIG=$(echo "$SCAN_OUTPUT" | jq -r '.signals.adr_signals')
assert_contains "rejected ADR captured" "$ADR_SIG" "Rejected"

README_NEG=$(echo "$SCAN_OUTPUT" | jq -r '.signals.readme_negative')
assert_contains "README negative signals captured" "$README_NEG" "Not supported"

ENTRY_SIG=$(echo "$SCAN_OUTPUT" | jq -r '.signals.entrypoints')
assert_contains "bin/ entrypoints captured" "$ENTRY_SIG" "bin"
assert_contains "commands/ entrypoints captured" "$ENTRY_SIG" "commands"

# ---------------------------------------------------------------------------
# Test: ignore set respected (AC2)
# ---------------------------------------------------------------------------
echo ""
echo "=== Ignore set (AC2) ==="
assert_not_contains "node_modules excluded from readme" "$README_SIG" "should not be scanned"

# Verify node_modules is in the ignore list in the scanner script
assert_pass "node_modules in scanner ignore list" grep -q "node_modules" "$SCANNER_IMPL"
assert_pass ".git in scanner ignore list" grep -q '".git"' "$SCANNER_IMPL"
assert_pass ".signum in scanner ignore list" grep -q '".signum"' "$SCANNER_IMPL"
assert_pass "dist in scanner ignore list" grep -q '"dist"' "$SCANNER_IMPL"
assert_pass "build in scanner ignore list" grep -q '"build"' "$SCANNER_IMPL"
assert_pass ".venv in scanner ignore list" grep -q '".venv"' "$SCANNER_IMPL"
assert_pass "__pycache__ in scanner ignore list" grep -q '"__pycache__"' "$SCANNER_IMPL"
assert_pass "coverage in scanner ignore list" grep -q '"coverage"' "$SCANNER_IMPL"
assert_pass "tests/fixtures in scanner ignore list" grep -q '"tests/fixtures"' "$SCANNER_IMPL"

# ---------------------------------------------------------------------------
# Test: git log uses 6-month horizon (AC11)
# ---------------------------------------------------------------------------
echo ""
echo "=== Git log horizon (AC11) ==="
assert_pass "6 months in scanner" grep -q "6 months" "$SCANNER_IMPL"
assert_pass "dirstat in scanner" grep -q "dirstat" "$SCANNER_IMPL"

# ---------------------------------------------------------------------------
# Test: glossary schema includes canonicalTerms and aliases (AC6)
# ---------------------------------------------------------------------------
echo ""
echo "=== Glossary schema (AC6) ==="
SCHEMA=$(echo "$SCAN_OUTPUT" | jq -r '.glossarySchema | keys | sort | join(",")')
assert_contains "canonicalTerms in schema" "$SCHEMA" "canonicalTerms"
assert_contains "aliases in schema" "$SCHEMA" "aliases"
assert_pass "canonicalTerms in scanner source" grep -q "canonicalTerms" "$SCANNER_IMPL"

# ---------------------------------------------------------------------------
# Test: existing glossary detection
# ---------------------------------------------------------------------------
echo ""
echo "=== Existing glossary detection ==="
cat > "$PROJECT/project.glossary.json" << 'EOF'
{
  "version": "1.0",
  "canonicalTerms": [{"term": "OldTerm", "definition": "existing"}],
  "aliases": {"old": "OldTerm"}
}
EOF

SCAN_WITH_GLOSSARY=$("$SCANNER" --project-root "$PROJECT" 2>/dev/null)
EXISTING_G=$(echo "$SCAN_WITH_GLOSSARY" | jq -r '.existingFiles.glossary.content')
assert_contains "existing glossary detected" "$EXISTING_G" "OldTerm"
assert_contains "existing glossary path set" \
  "$(echo "$SCAN_WITH_GLOSSARY" | jq -r '.existingFiles.glossary.path')" "project.glossary.json"

# Cleanup
rm -f "$PROJECT/project.glossary.json"

# ---------------------------------------------------------------------------
# Test: project with no signals (sparse project)
# ---------------------------------------------------------------------------
echo ""
echo "=== Sparse project (no README, no manifest) ==="
SPARSE="$WORK/sparse"
mkdir -p "$SPARSE"
SPARSE_OUT=$("$SCANNER" --project-root "$SPARSE" 2>/dev/null)
assert_pass "scanner handles sparse project" "$SCANNER" --project-root "$SPARSE"
assert_json_field "sparse project has schemaVersion" "$SPARSE_OUT" ".schemaVersion"

# ---------------------------------------------------------------------------
# Test: pyproject.toml support
# ---------------------------------------------------------------------------
echo ""
echo "=== pyproject.toml support ==="
PY_PROJECT="$WORK/pyproject"
mkdir -p "$PY_PROJECT"
cat > "$PY_PROJECT/pyproject.toml" << 'EOF'
[project]
name = "mypkg"
description = "A Python package"
version = "1.0.0"

[project.scripts]
mypkg = "mypkg.cli:main"
EOF

PY_OUT=$("$SCANNER" --project-root "$PY_PROJECT" 2>/dev/null)
PYPROJ_SIG=$(echo "$PY_OUT" | jq -r '.signals.pyproject_toml')
assert_contains "pyproject.toml captured" "$PYPROJ_SIG" "mypkg"

CONSOLE_SIG=$(echo "$PY_OUT" | jq -r '.signals.console_scripts')
assert_contains "console_scripts extracted" "$CONSOLE_SIG" "mypkg"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
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
  exit 0
fi
