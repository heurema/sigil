#!/usr/bin/env bash
# test-claude-overlay-doc-mirror.sh -- keep mirrored Claude overlay docs/meta aligned with root copies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAY_ROOT="$REPO_ROOT/platforms/claude-code"

passed=0
failed=0

assert_same_file() {
  local name="$1" root_file="$2" overlay_file="$3"
  if diff -q "$root_file" "$overlay_file" >/dev/null 2>&1; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — files differ\n' "$name"
    failed=$((failed + 1))
  fi
}

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

echo "=== Claude overlay mirrored docs ==="
assert_same_file "CHANGELOG mirror" "$REPO_ROOT/CHANGELOG.md" "$OVERLAY_ROOT/CHANGELOG.md"
assert_same_file "QUICKSTART mirror" "$REPO_ROOT/QUICKSTART.md" "$OVERLAY_ROOT/QUICKSTART.md"
assert_same_file "how-it-works mirror" "$REPO_ROOT/docs/how-it-works.md" "$OVERLAY_ROOT/docs/how-it-works.md"
assert_same_file "reference mirror" "$REPO_ROOT/docs/reference.md" "$OVERLAY_ROOT/docs/reference.md"

echo ""
echo "=== Claude overlay plugin version ==="
ROOT_VERSION=$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json")
OVERLAY_VERSION=$(jq -r '.version' "$OVERLAY_ROOT/.claude-plugin/plugin.json")
assert_eq "plugin version matches root" "$OVERLAY_VERSION" "$ROOT_VERSION"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
