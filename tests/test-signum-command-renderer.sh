#!/usr/bin/env bash
# test-signum-command-renderer.sh -- ensure Signum command fragments render byte-for-byte
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RENDERER="$REPO_ROOT/scripts/render_signum_command.py"
OVERLAY_RENDERER="$REPO_ROOT/platforms/claude-code/scripts/render_signum_command.py"
ROOT_MANIFEST="$REPO_ROOT/commands/signum.fragments/manifest.json"
OVERLAY_MANIFEST="$REPO_ROOT/platforms/claude-code/commands/signum.fragments/manifest.json"
ROOT_COMMAND="$REPO_ROOT/commands/signum.md"
OVERLAY_COMMAND="$REPO_ROOT/platforms/claude-code/commands/signum.md"
WORK="$(mktemp -d "$REPO_ROOT/.tmp-signum-renderer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

assert_ok() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

assert_fail_contains() {
  local name="$1" expected="$2"; shift 2
  local output exit_code
  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e
  if [ "$exit_code" -eq 0 ]; then
    fail "$name" "expected failure, got exit 0: $output"
  elif [[ "$output" == *"$expected"* ]]; then
    pass "$name"
  else
    fail "$name" "missing '$expected' in: $output"
  fi
}

assert_cmp() {
  local name="$1" left="$2" right="$3"
  if cmp -s "$left" "$right"; then
    pass "$name"
  else
    fail "$name" "$left differs from $right"
  fi
}

echo "=== Renderer wiring ==="
assert_file "root renderer exists" "$RENDERER"
assert_file "overlay renderer exists" "$OVERLAY_RENDERER"
assert_ok "root renderer compiles" python3 -m py_compile "$RENDERER"
assert_ok "overlay renderer compiles" python3 -m py_compile "$OVERLAY_RENDERER"
assert_cmp "overlay renderer mirrors root" "$RENDERER" "$OVERLAY_RENDERER"
assert_file "root manifest exists" "$ROOT_MANIFEST"
assert_file "overlay manifest exists" "$OVERLAY_MANIFEST"

assert_ok "root manifest has explicit fragment order" jq -e '.version == 1 and (.fragments | type == "array") and (.fragments | length == 13)' "$ROOT_MANIFEST"
assert_ok "overlay manifest has explicit fragment order" jq -e '.version == 1 and (.fragments | type == "array") and (.fragments | length == 14)' "$OVERLAY_MANIFEST"
assert_ok "root manifest references five shared repo-scope fragments" jq -e '[.fragments[] | select(type == "object" and .scope == "repo" and (.path | startswith("commands/signum.shared.fragments/")))] | length == 5' "$ROOT_MANIFEST"
assert_ok "overlay manifest references five shared repo-scope fragments" jq -e '[.fragments[] | select(type == "object" and .scope == "repo" and (.path | startswith("commands/signum.shared.fragments/")))] | length == 5' "$OVERLAY_MANIFEST"

echo ""
echo "=== Byte-for-byte render checks ==="
assert_ok "root --check matches checked-in command" python3 "$RENDERER" --manifest "$ROOT_MANIFEST" --output "$ROOT_COMMAND" --check
assert_ok "overlay --check matches checked-in command" python3 "$RENDERER" --manifest "$OVERLAY_MANIFEST" --output "$OVERLAY_COMMAND" --check
assert_ok "overlay mirrored renderer resolves shared fragments" python3 "$OVERLAY_RENDERER" --manifest "$OVERLAY_MANIFEST" --output "$OVERLAY_COMMAND" --check
assert_ok "root renders to temp output" python3 "$RENDERER" --manifest "$ROOT_MANIFEST" --output "$WORK/root.md"
assert_cmp "root temp render matches checked-in command" "$WORK/root.md" "$ROOT_COMMAND"
assert_ok "overlay renders to temp output" python3 "$RENDERER" --manifest "$OVERLAY_MANIFEST" --output "$WORK/overlay.md"
assert_cmp "overlay temp render matches checked-in command" "$WORK/overlay.md" "$OVERLAY_COMMAND"

echo ""
echo "=== Manifest validation ==="
mkdir -p "$WORK/missing" "$WORK/absolute" "$WORK/traversal" "$WORK/repo-missing" "$WORK/repo-absolute" "$WORK/repo-traversal" "$WORK/duplicate"
printf '{"version":1,"fragments":["missing.md"]}\n' > "$WORK/missing/manifest.json"
printf '{"version":1,"fragments":["/tmp/signum.md"]}\n' > "$WORK/absolute/manifest.json"
printf '{"version":1,"fragments":["../commands/signum.md"]}\n' > "$WORK/traversal/manifest.json"
printf '{"version":1,"fragments":[{"scope":"repo","path":"commands/signum.shared.fragments/missing.md"}]}\n' > "$WORK/repo-missing/manifest.json"
printf '{"version":1,"fragments":[{"scope":"repo","path":"/tmp/signum.md"}]}\n' > "$WORK/repo-absolute/manifest.json"
printf '{"version":1,"fragments":[{"scope":"repo","path":"../commands/signum.md"}]}\n' > "$WORK/repo-traversal/manifest.json"
printf '{"version":1,"fragments":[{"scope":"repo","path":"commands/signum.shared.fragments/00-header.md"},{"scope":"repo","path":"commands/signum.shared.fragments/00-header.md"}]}\n' > "$WORK/duplicate/manifest.json"
assert_fail_contains "missing fragment fails" "fragment not found" python3 "$RENDERER" --manifest "$WORK/missing/manifest.json" --output "$WORK/out.md"
assert_fail_contains "absolute fragment path fails" "absolute fragment paths are not allowed" python3 "$RENDERER" --manifest "$WORK/absolute/manifest.json" --output "$WORK/out.md"
assert_fail_contains "path traversal fragment fails" "path traversal" python3 "$RENDERER" --manifest "$WORK/traversal/manifest.json" --output "$WORK/out.md"
assert_fail_contains "missing shared fragment fails" "fragment not found" python3 "$RENDERER" --manifest "$WORK/repo-missing/manifest.json" --output "$WORK/out.md"
assert_fail_contains "absolute shared fragment path fails" "absolute fragment paths are not allowed" python3 "$RENDERER" --manifest "$WORK/repo-absolute/manifest.json" --output "$WORK/out.md"
assert_fail_contains "shared path traversal fragment fails" "path traversal" python3 "$RENDERER" --manifest "$WORK/repo-traversal/manifest.json" --output "$WORK/out.md"
assert_fail_contains "duplicate shared fragment fails" "duplicate fragment entry" python3 "$RENDERER" --manifest "$WORK/duplicate/manifest.json" --output "$WORK/out.md"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
