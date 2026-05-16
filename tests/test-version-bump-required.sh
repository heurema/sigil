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

MERGE_BASE_REPO="$TMP_DIR/merge-base-repo"
git init -q -b main "$MERGE_BASE_REPO"
cd "$MERGE_BASE_REPO"
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
git switch -q -c feature
git switch -q main
mkdir -p lib
printf '#!/usr/bin/env bash\n' > lib/base-only.sh
git add lib/base-only.sh
git commit -q -m "main runtime change"
git switch -q feature
mkdir -p docs
printf 'feature docs\n' > docs/readme.md
MERGE_BASE_REPORT="$TMP_DIR/merge-base.json"
if run_checker "$MERGE_BASE_REPO" main "$MERGE_BASE_REPORT"; then
  pass "branch comparison ignores base-only sensitive changes"
else
  fail "branch comparison ignores base-only sensitive changes" "checker failed"
fi
assert_json_eq "merge-base comparison uses merge-base mode" "$MERGE_BASE_REPORT" ".baseMode" "merge_base"
assert_json_eq "merge-base comparison does not require bump for docs-only feature" "$MERGE_BASE_REPORT" ".versionBumpRequired" "false"

MULTI_COMMIT_REPO="$TMP_DIR/multi-commit-repo"
git init -q -b main "$MULTI_COMMIT_REPO"
cd "$MULTI_COMMIT_REPO"
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
git switch -q -c feature
mkdir -p lib
printf '#!/usr/bin/env bash\n' > lib/runtime.sh
git add lib/runtime.sh
git commit -q -m "runtime change"
mkdir -p docs
printf 'follow-up docs\n' > docs/readme.md
git add docs/readme.md
git commit -q -m "docs follow-up"
MULTI_COMMIT_REPORT="$TMP_DIR/multi-commit.json"
if run_checker "$MULTI_COMMIT_REPO" main "$MULTI_COMMIT_REPORT"; then
  fail "branch comparison catches earlier sensitive commit" "checker unexpectedly passed"
else
  pass "branch comparison catches earlier sensitive commit"
fi
assert_json_eq "multi-commit branch requires bump" "$MULTI_COMMIT_REPORT" ".versionBumpRequired" "true"
assert_json_eq "multi-commit branch reports bump violation" "$MULTI_COMMIT_REPORT" ".violations[0].id" "version.bump_required"

PUSH_REPO="$TMP_DIR/push-repo"
git init -q -b main "$PUSH_REPO"
cd "$PUSH_REPO"
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
PUSH_BEFORE="$(git rev-parse HEAD)"
mkdir -p lib
printf '#!/usr/bin/env bash\n' > lib/runtime.sh
git add lib/runtime.sh
git commit -q -m "runtime change"
PUSH_EVENT="$TMP_DIR/push-event.json"
printf '{"before":"%s"}\n' "$PUSH_BEFORE" > "$PUSH_EVENT"
PUSH_REPORT="$TMP_DIR/push.json"
if GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$PUSH_EVENT" python3 "$CHECKER" --repo-root "$PUSH_REPO" --json-output "$PUSH_REPORT"; then
  fail "push event comparison catches sensitive commit" "checker unexpectedly passed"
else
  pass "push event comparison catches sensitive commit"
fi
assert_json_eq "push event uses previous sha source" "$PUSH_REPORT" ".baseSource" "github_push_before"
assert_json_eq "push event uses direct diff mode" "$PUSH_REPORT" ".baseMode" "direct"
assert_json_eq "push event reports bump violation" "$PUSH_REPORT" ".violations[0].id" "version.bump_required"

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
