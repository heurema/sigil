#!/usr/bin/env bash
# test-init-command-surface.sh -- command surface and helper resolution checks for init
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ROOT_INIT="$REPO_ROOT/commands/init.md"
OVERLAY_INIT="$REPO_ROOT/platforms/claude-code/commands/init.md"
ROOT_SIGNUM="$REPO_ROOT/commands/signum.md"
OVERLAY_SIGNUM="$REPO_ROOT/platforms/claude-code/commands/signum.md"
README_FILE="$REPO_ROOT/README.md"
HOW_IT_WORKS="$REPO_ROOT/docs/how-it-works.md"

passed=0
failed=0

assert_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s" in %s\n' "$name" "$needle" "$file"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  FAIL: %s — found "%s" in %s\n' "$name" "$needle" "$file"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

echo "=== Public docs ==="
assert_contains "README uses canonical init command" "$README_FILE" "/signum:init --harness"
assert_contains "README documents version requirement" "$README_FILE" ">= v4.18.0"
assert_not_contains "README no longer presents spaced init example" "$README_FILE" "/signum init --harness"
assert_contains "How-it-works uses canonical init heading" "$HOW_IT_WORKS" "## Project Context Bootstrap: /signum:init"
assert_contains "How-it-works uses canonical init usage" "$HOW_IT_WORKS" "/signum:init [--force] [--harness] [--project-root <path>]"
assert_contains "How-it-works documents version requirement" "$HOW_IT_WORKS" ">= v4.18.0"

echo ""
echo "=== Init command prompts ==="
assert_contains "Root init usage is canonical" "$ROOT_INIT" "/signum:init [--force] [--harness] [--project-root <path>]"
assert_contains "Overlay init usage is canonical" "$OVERLAY_INIT" "/signum:init [--force] [--actualize] [--harness] [--project-root <path>]"
assert_contains "Root init resolves plugin helper paths" "$ROOT_INIT" "resolve_signum_helper()"
assert_contains "Overlay init resolves plugin helper paths" "$OVERLAY_INIT" "resolve_signum_helper()"
assert_contains "Root init checks CLAUDE_PLUGIN_ROOT" "$ROOT_INIT" 'CLAUDE_PLUGIN_ROOT'
assert_contains "Overlay init checks CLAUDE_PLUGIN_ROOT" "$OVERLAY_INIT" 'CLAUDE_PLUGIN_ROOT'
assert_contains "Root init uses resolved scanner path" "$ROOT_INIT" 'bash "$INIT_SCANNER_PATH" --project-root'
assert_contains "Overlay init uses resolved scanner path" "$OVERLAY_INIT" 'bash "$INIT_SCANNER_PATH" --project-root'
assert_contains "Root init uses resolved harness scaffold path" "$ROOT_INIT" 'bash "$INIT_HARNESS_SCAFFOLD_PATH" --project-root'
assert_contains "Overlay init uses resolved harness scaffold path" "$OVERLAY_INIT" 'bash "$INIT_HARNESS_SCAFFOLD_PATH" --project-root'
assert_not_contains "Root init no longer hardcodes repo-local scanner path" "$ROOT_INIT" 'bash lib/init-scanner.sh'
assert_not_contains "Overlay init no longer hardcodes repo-local scanner path" "$OVERLAY_INIT" 'bash lib/init-scanner.sh'
assert_not_contains "Root init no longer hardcodes repo-local harness scaffold path" "$ROOT_INIT" 'bash lib/init-harness-scaffold.sh'
assert_not_contains "Overlay init no longer hardcodes repo-local harness scaffold path" "$OVERLAY_INIT" 'bash lib/init-harness-scaffold.sh'

echo ""
echo "=== Root command guard ==="
assert_contains "Root signum has init redirect section" "$ROOT_SIGNUM" "## Init Command Redirect"
assert_contains "Overlay signum has init redirect section" "$OVERLAY_SIGNUM" "## Init Command Redirect"
assert_contains "Root signum redirects to canonical init command" "$ROOT_SIGNUM" 'Use `/signum:init [--force] [--harness] [--project-root <path>]`.'
assert_contains "Overlay signum redirects to canonical init command" "$OVERLAY_SIGNUM" 'Use `/signum:init [--force] [--actualize] [--harness] [--project-root <path>]`.'
assert_contains "Root signum mentions version requirement" "$ROOT_SIGNUM" '>= v4.18.0'
assert_contains "Overlay signum mentions version requirement" "$OVERLAY_SIGNUM" '>= v4.18.0'

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
