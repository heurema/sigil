#!/usr/bin/env bash
# test-version-bump-required.sh -- require plugin version bumps for runtime/plugin diffs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check_version_bump.py"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

assert_json_eq() {
  local name="$1" file="$2" filter="$3" expected="$4" actual
  actual="$(jq -r "$filter" "$file")"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected $expected, got $actual"
  fi
}

run_checker() {
  local repo="$1" base="$2" out="$3"
  python3 "$CHECKER" --repo-root "$repo" --base-ref "$base" --json-output "$out"
}

REPO="$TMP_DIR/repo"
git init -q "$REPO"
cd "$REPO"
git config user.name "Signum Test"
git config user.email "signum-test@example.invalid"

mkdir -p .claude-plugin
cat > .claude-plugin/plugin.json <<'JSON'
{
  "name": "signum",
  "version": "1.0.0"
}
JSON

git add .claude-plugin/plugin.json
git commit -q -m "initial"
BASE_REF="HEAD"

mkdir -p docs
printf 'docs only\n' > docs/readme.md
DOCS_REPORT="$TMP_DIR/docs.json"
if run_checker "$REPO" "$BASE_REF" "$DOCS_REPORT"; then
  pass "docs-only change does not require version bump"
else
  fail "docs-only change does not require version bump" "checker failed"
fi
assert_json_eq "docs-only hard gate passes" "$DOCS_REPORT" ".hardGatePassed" "true"
assert_json_eq "docs-only does not require bump" "$DOCS_REPORT" ".versionBumpRequired" "false"
rm -rf docs

mkdir -p lib
printf '#!/usr/bin/env bash\n' > lib/runtime.sh
NO_BUMP_REPORT="$TMP_DIR/no-bump.json"
if run_checker "$REPO" "$BASE_REF" "$NO_BUMP_REPORT"; then
  fail "runtime change without version bump fails" "checker unexpectedly passed"
else
  pass "runtime change without version bump fails"
fi
assert_json_eq "runtime no-bump hard gate fails" "$NO_BUMP_REPORT" ".hardGatePassed" "false"
assert_json_eq "runtime no-bump reports version requirement" "$NO_BUMP_REPORT" ".versionBumpRequired" "true"
assert_json_eq "runtime no-bump reports violation" "$NO_BUMP_REPORT" ".violations[0].id" "version.bump_required"

python3 - <<'PY'
import json
from pathlib import Path

path = Path(".claude-plugin/plugin.json")
data = json.loads(path.read_text(encoding="utf-8"))
data["version"] = "1.0.1"
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

BUMP_REPORT="$TMP_DIR/bump.json"
if run_checker "$REPO" "$BASE_REF" "$BUMP_REPORT"; then
  pass "runtime change with version bump passes"
else
  fail "runtime change with version bump passes" "checker failed"
fi
assert_json_eq "runtime bump hard gate passes" "$BUMP_REPORT" ".hardGatePassed" "true"
assert_json_eq "runtime bump current version" "$BUMP_REPORT" ".currentVersion" "1.0.1"

UNKNOWN_REPORT="$TMP_DIR/unknown.json"
if python3 "$CHECKER" --repo-root "$REPO" --base-ref missing-ref --json-output "$UNKNOWN_REPORT"; then
  pass "missing base ref skips without blocking"
else
  fail "missing base ref skips without blocking" "checker failed"
fi
assert_json_eq "missing base ref status is skipped" "$UNKNOWN_REPORT" ".status" "skipped"
assert_json_eq "missing base ref hard gate passes" "$UNKNOWN_REPORT" ".hardGatePassed" "true"

CURRENT_REPORT="$TMP_DIR/current-repo.json"
if python3 "$CHECKER" --repo-root "$REPO_ROOT" --json-output "$CURRENT_REPORT"; then
  pass "current repository version-bump guard passes"
else
  fail "current repository version-bump guard passes" "checker failed for current repository diff"
fi
assert_json_eq "current repository report has hard gate" "$CURRENT_REPORT" ".hardGatePassed" "true"
assert_json_eq "current repository report has deterministic schema" "$CURRENT_REPORT" ".schemaVersion" "1.0"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
