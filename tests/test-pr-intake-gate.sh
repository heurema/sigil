#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_event() {
  local path="$1"
  local body="$2"
  local labels_json="$3"
  python3 - "$path" "$body" "$labels_json" <<'PY'
import json
import sys
path, body, labels_json = sys.argv[1], sys.argv[2], sys.argv[3]
labels = [{"name": name} for name in json.loads(labels_json)]
event = {
    "repository": {"full_name": "heurema/signum"},
    "pull_request": {
        "number": 123,
        "title": "Test PR",
        "body": body,
        "author_association": "CONTRIBUTOR",
        "labels": labels,
        "base": {"sha": "base-sha"},
        "head": {"sha": "head-sha"},
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle)
PY
}

run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_verdict="$3"
  local files_json="$4"
  local body="$5"
  local labels_json="$6"
  local event_path="$TMP_DIR/${name}.event.json"
  local stdout_path="$TMP_DIR/${name}.stdout.json"
  local stderr_path="$TMP_DIR/${name}.stderr.txt"
  local summary_path="$TMP_DIR/${name}.summary.md"

  write_event "$event_path" "$body" "$labels_json"

  set +e
  (
    cd "$ROOT_DIR"
    GITHUB_EVENT_PATH="$event_path" \
    GITHUB_STEP_SUMMARY="$summary_path" \
    PR_INTAKE_GATE_CHANGED_FILES_JSON="$files_json" \
    PR_INTAKE_GATE_DRY_RUN=1 \
    python3 scripts/pr_intake_gate.py >"$stdout_path" 2>"$stderr_path"
  )
  local actual_status=$?
  set -e

  if [ "$actual_status" -ne "$expected_status" ]; then
    echo "FAIL $name: expected exit $expected_status, got $actual_status" >&2
    cat "$stderr_path" >&2 || true
    cat "$stdout_path" >&2 || true
    exit 1
  fi

  local actual_verdict
  actual_verdict="$(python3 - "$stdout_path" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["verdict"])
PY
)"

  if [ "$actual_verdict" != "$expected_verdict" ]; then
    echo "FAIL $name: expected verdict $expected_verdict, got $actual_verdict" >&2
    cat "$stdout_path" >&2 || true
    exit 1
  fi

  if ! grep -q 'PR Intake Gate' "$summary_path"; then
    echo "FAIL $name: missing step summary" >&2
    cat "$summary_path" >&2 || true
    exit 1
  fi

  echo "ok - $name"
}

python3 - <<'PY'
from scripts.pr_intake_gate import is_gate_comment, path_matches

marker = "<!-- pr-intake-gate -->"
assert path_matches("README.md", "*.md")
assert path_matches("docs/usage.md", "docs/**")
assert not path_matches("src/runtime.md", "*.md")
assert path_matches("scripts/check.sh", "scripts/**/*.sh")
assert path_matches("scripts/nested/check.sh", "scripts/**/*.sh")
assert not is_gate_comment({"body": marker, "user": {"login": "contributor", "type": "User"}}, marker)
assert is_gate_comment({"body": marker, "user": {"login": "github-actions[bot]", "type": "Bot"}}, marker)
print("ok - helper semantics")
PY

run_case \
  "docs_only_passes" \
  0 \
  "pass" \
  '[{"filename":"README.md","additions":2,"deletions":1}]' \
  '' \
  '[]'

run_case \
  "nested_markdown_without_intent_fails" \
  1 \
  "needs-issue" \
  '[{"filename":"src/runtime.md","additions":1,"deletions":0}]' \
  '' \
  '[]'

run_case \
  "non_trivial_without_intent_fails" \
  1 \
  "needs-issue" \
  '[{"filename":"docs/usage.md","additions":31,"deletions":0}]' \
  '' \
  '[]'

run_case \
  "high_risk_workflow_fails" \
  1 \
  "high-risk" \
  '[{"filename":".github/workflows/ci.yml","additions":1,"deletions":0}]' \
  '' \
  '[]'

run_case \
  "high_risk_script_shell_fails" \
  1 \
  "high-risk" \
  '[{"filename":"scripts/check.sh","additions":1,"deletions":0}]' \
  '' \
  '[]'

run_case \
  "override_passes_high_risk" \
  0 \
  "pass" \
  '[{"filename":".github/workflows/ci.yml","additions":1,"deletions":0}]' \
  '' \
  '["maintainer/override-intake"]'

run_case \
  "linked_non_trivial_passes" \
  0 \
  "pass" \
  '[{"filename":"docs/usage.md","additions":31,"deletions":0}]' \
  'Closes #42' \
  '[]'
