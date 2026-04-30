#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_event() {
  local path="$1"
  local body="$2"
  local labels_json="$3"
  local author_association="$4"
  local author_login="$5"
  python3 - "$path" "$body" "$labels_json" "$author_association" "$author_login" <<'PY'
import json
import sys

path, body, labels_json, author_association, author_login = sys.argv[1:]
labels = [{"name": name} for name in json.loads(labels_json)]
event = {
    "repository": {"full_name": "heurema/signum"},
    "pull_request": {
        "number": 123,
        "title": "Test PR",
        "body": body,
        "author_association": author_association,
        "user": {"login": author_login},
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
  local author_association="$4"
  local author_permission="$5"
  local files_json="$6"
  local body="$7"
  local labels_json="$8"
  local event_path="$TMP_DIR/${name}.event.json"
  local stdout_path="$TMP_DIR/${name}.stdout.json"
  local stderr_path="$TMP_DIR/${name}.stderr.txt"
  local summary_path="$TMP_DIR/${name}.summary.md"

  write_event "$event_path" "$body" "$labels_json" "$author_association" "${name}-author"

  set +e
  (
    cd "$ROOT_DIR"
    GITHUB_EVENT_PATH="$event_path" \
    GITHUB_STEP_SUMMARY="$summary_path" \
    PR_INTAKE_GATE_CHANGED_FILES_JSON="$files_json" \
    PR_INTAKE_GATE_AUTHOR_PERMISSION="$author_permission" \
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

json_assert() {
  local path="$1"
  local key="$2"
  local expected_json="$3"
  python3 - "$path" "$key" "$expected_json" <<'PY'
import json
import sys

path, key, expected_json = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    value = json.load(handle)
for part in key.split("."):
    value = value[part]
expected = json.loads(expected_json)
if value != expected:
    raise SystemExit(f"expected {key}={expected!r}, got {value!r}")
PY
}

json_list_contains() {
  local path="$1"
  local key="$2"
  local expected="$3"
  python3 - "$path" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    value = json.load(handle)
for part in key.split("."):
    value = value[part]
if expected not in value:
    raise SystemExit(f"expected {key} to contain {expected!r}, got {value!r}")
PY
}

case_stdout() {
  printf '%s/%s.stdout.json' "$TMP_DIR" "$1"
}

case_stderr() {
  printf '%s/%s.stderr.txt' "$TMP_DIR" "$1"
}

full_context_body() {
  cat <<'EOF'
## Problem
The current behavior blocks a needed contributor workflow.

### Why now
The project is ready to accept this contribution path.

#### Existing options checked
Existing documentation and configuration were checked and are insufficient.

## Alternatives considered
Keeping the current process was considered and rejected because it blocks review.

##### No-code alternative
Documentation-only guidance would not enforce the intake policy.

###### Why code is needed
The gate must make the decision deterministically in CI.
EOF
}

full_context_with_link_body() {
  cat <<'EOF'
## Problem
The current behavior blocks a needed contributor workflow.

## Why now
The project is ready to accept this contribution path.

## Existing options checked
Existing documentation and configuration were checked and are insufficient.

## Alternatives considered
Keeping the current process was considered and rejected because it blocks review.

## No-code alternative
Documentation-only guidance would not enforce the intake policy.

## Why code is needed
The gate must make the decision deterministically in CI.

Closes #42
EOF
}

missing_no_code_body() {
  cat <<'EOF'
## Problem
The current behavior blocks a needed contributor workflow.

## Why now
The project is ready to accept this contribution path.

## Existing options checked
Existing documentation and configuration were checked and are insufficient.

## Alternatives considered
Keeping the current process was considered and rejected because it blocks review.

## Why code is needed
The gate must make the decision deterministically in CI.

Closes #42
EOF
}

missing_context_body() {
  cat <<'EOF'
## No-code alternative
Documentation-only guidance would not enforce the intake policy.

## Why code is needed
The gate must make the decision deterministically in CI.

Closes #42
EOF
}

python3 - <<'PY'
import contextlib
import io

from scripts.pr_intake_gate import (
    GateError,
    is_gate_comment,
    load_minimal_yaml,
    managed_verdict_labels,
    markdown_sections,
    missing_required_sections,
    path_matches,
    run_optional_side_effect,
)

marker = "<!-- pr-intake-gate -->"
assert path_matches("README.md", "*.md")
assert path_matches("docs/usage.md", "docs/**")
assert not path_matches("src/runtime.md", "*.md")
assert path_matches("scripts/check.sh", "scripts/**/*.sh")
assert path_matches("scripts/nested/check.sh", "scripts/**/*.sh")
assert is_gate_comment({"body": marker, "user": {"login": "github-actions[bot]", "type": "Bot"}}, marker)
assert not is_gate_comment({"body": marker, "user": {"login": "contributor", "type": "User"}}, marker)
assert not is_gate_comment({"body": marker, "user": {"login": "other-bot", "type": "Bot"}}, marker)

sections = markdown_sections("## Problem!\nreal problem\n\n### Why now?\nright now\n")
assert sections["problem"] == "real problem"
assert sections["why now"] == "right now"

required = [
    "Problem",
    "Why now",
    "Existing options checked",
    "Alternatives considered",
    "No-code alternative",
    "Why code is needed",
]
body = """
## Problem
real problem
## Why now
right now
## Existing options checked
checked
## Alternatives considered
alternative
## Why code is needed
needs deterministic enforcement
"""
assert missing_required_sections(body, required) == ["No-code alternative"]
assert missing_required_sections("## Problem\nN/A\n", ["Problem"]) == ["Problem"]
assert missing_required_sections("## Problem\n-\n", ["Problem"]) == ["Problem"]

stream = io.StringIO()
with contextlib.redirect_stderr(stream):
    result = run_optional_side_effect("label sync", lambda: (_ for _ in ()).throw(GateError("boom")))
assert result is False
assert "pr-intake-gate warning: label sync skipped: boom" in stream.getvalue()

config = load_minimal_yaml(".github/pr-intake-gate.yml")
managed = managed_verdict_labels(config)
assert "intake/pass" in managed
assert "intake/needs-issue" in managed
assert "intake/accepted-for-pr" not in managed
assert "intake/first-time-contributor" not in managed
print("ok - helper semantics")
PY

run_case \
  "trusted_permission_passes_high_risk" \
  0 \
  "pass" \
  "CONTRIBUTOR" \
  "admin" \
  '[{"filename":".github/workflows/ci.yml","additions":1,"deletions":0}]' \
  '' \
  '[]'
json_assert "$(case_stdout trusted_permission_passes_high_risk)" "trusted_author" 'true'
json_assert "$(case_stdout trusted_permission_passes_high_risk)" "trust_source" '"permission:admin"'
json_assert "$(case_stdout trusted_permission_passes_high_risk)" "author_permission" '"admin"'

run_case \
  "trusted_association_fallback_passes_high_risk" \
  0 \
  "pass" \
  "OWNER" \
  "none" \
  '[{"filename":".github/workflows/ci.yml","additions":1,"deletions":0}]' \
  '' \
  '[]'
json_assert "$(case_stdout trusted_association_fallback_passes_high_risk)" "trusted_author" 'true'
json_assert "$(case_stdout trusted_association_fallback_passes_high_risk)" "trust_source" '"author_association:OWNER"'
json_assert "$(case_stdout trusted_association_fallback_passes_high_risk)" "author_permission" 'null'

run_case \
  "external_docs_only_passes" \
  0 \
  "pass" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":"docs/README.md","additions":2,"deletions":1}]' \
  '' \
  '[]'
json_assert "$(case_stdout external_docs_only_passes)" "trusted_author" 'false'
json_assert "$(case_stdout external_docs_only_passes)" "is_trivial" 'true'

run_case \
  "external_high_risk_fails" \
  1 \
  "high-risk" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":".github/workflows/ci.yml","additions":1,"deletions":0}]' \
  '' \
  '[]'
json_assert "$(case_stdout external_high_risk_fails)" "trusted_author" 'false'
json_list_contains "$(case_stdout external_high_risk_fails)" "high_risk_paths" '.github/workflows/ci.yml'

run_case \
  "first_time_external_high_risk_fails_with_signal" \
  1 \
  "high-risk" \
  "FIRST_TIMER" \
  "none" \
  '[{"filename":".github/workflows/ci.yml","additions":1,"deletions":0}]' \
  '' \
  '[]'
json_assert "$(case_stdout first_time_external_high_risk_fails_with_signal)" "first_time_external" 'true'
grep -q 'intake/first-time-contributor' "$(case_stderr first_time_external_high_risk_fails_with_signal)"

run_case \
  "external_non_trivial_missing_no_code_fails" \
  1 \
  "no-code-alternative" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":"docs/usage.md","additions":31,"deletions":0}]' \
  "$(missing_no_code_body)" \
  '[]'
json_list_contains "$(case_stdout external_non_trivial_missing_no_code_fails)" "missing_external_context_sections" 'No-code alternative'

run_case \
  "external_non_trivial_missing_context_fails" \
  1 \
  "needs-more-context" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":"docs/usage.md","additions":31,"deletions":0}]' \
  "$(missing_context_body)" \
  '[]'
json_list_contains "$(case_stdout external_non_trivial_missing_context_fails)" "missing_external_context_sections" 'Problem'

run_case \
  "external_full_context_without_link_fails" \
  1 \
  "needs-issue" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":"docs/usage.md","additions":31,"deletions":0}]' \
  "$(full_context_body)" \
  '[]'
json_assert "$(case_stdout external_full_context_without_link_fails)" "linked_intent" 'false'

run_case \
  "external_full_context_with_link_passes" \
  0 \
  "pass" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":"docs/usage.md","additions":31,"deletions":0}]' \
  "$(full_context_with_link_body)" \
  '[]'
json_assert "$(case_stdout external_full_context_with_link_passes)" "linked_intent" 'true'

run_case \
  "accepted_external_non_high_risk_passes" \
  0 \
  "pass" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":"docs/usage.md","additions":31,"deletions":0}]' \
  '' \
  '["intake/accepted-for-pr"]'
json_assert "$(case_stdout accepted_external_non_high_risk_passes)" "accepted_for_pr" 'true'
json_assert "$(case_stdout accepted_external_non_high_risk_passes)" "trusted_author" 'false'

run_case \
  "override_passes_external_high_risk" \
  0 \
  "pass" \
  "CONTRIBUTOR" \
  "none" \
  '[{"filename":".github/workflows/ci.yml","additions":1,"deletions":0}]' \
  '' \
  '["maintainer/override-intake"]'
json_assert "$(case_stdout override_passes_external_high_risk)" "trusted_author" 'false'

python3 - <<'PY'
import contextlib
import io

from scripts.pr_intake_gate import GateError, run_optional_side_effect

stream = io.StringIO()
with contextlib.redirect_stderr(stream):
    result = run_optional_side_effect("comment upsert", lambda: (_ for _ in ()).throw(GateError("HTTP 403")))
assert result is False
assert "pr-intake-gate warning: comment upsert skipped: HTTP 403" in stream.getvalue()
print("ok - side-effect failures are non-fatal")
PY
