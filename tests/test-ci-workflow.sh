#!/usr/bin/env bash
# test-ci-workflow.sh -- static safety checks for deterministic PR CI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
workflow = repo_root / ".github" / "workflows" / "ci.yml"
runner = repo_root / "scripts" / "run-deterministic-tests.sh"
cleanroom_test = repo_root / "tests" / "test-cleanroom-smoke.sh"
cleanroom_smoke = repo_root / "scripts" / "run-cleanroom-smoke.sh"

passed = 0
failed = 0


def ok(name):
    global passed
    print(f"  PASS: {name}")
    passed += 1


def bad(name, message):
    global failed
    print(f"  FAIL: {name} -- {message}")
    failed += 1


def assert_true(name, condition, message):
    if condition:
        ok(name)
    else:
        bad(name, message)


workflow_text = workflow.read_text(encoding="utf-8") if workflow.exists() else ""
runner_text = runner.read_text(encoding="utf-8") if runner.exists() else ""
cleanroom_test_text = cleanroom_test.read_text(encoding="utf-8") if cleanroom_test.exists() else ""
cleanroom_smoke_text = cleanroom_smoke.read_text(encoding="utf-8") if cleanroom_smoke.exists() else ""
workflow_lower = workflow_text.lower()
runner_lower = runner_text.lower()

assert_true("ci workflow exists", workflow.exists(), f"missing {workflow}")
assert_true(
    "ci workflow uses pull_request",
    re.search(r"(?m)^\s*pull_request\s*:", workflow_text) is not None,
    "missing pull_request trigger",
)
assert_true(
    "ci workflow does not use pull_request_target",
    "pull_request_target" not in workflow_text,
    "pull_request_target is not allowed for deterministic PR CI",
)
assert_true(
    "ci workflow does not reference secrets",
    "secrets" not in workflow_lower,
    "secrets must not be used by deterministic PR CI",
)
assert_true(
    "ci workflow uses read-only contents permission",
    re.search(r"(?ms)^permissions:\s*\n\s*contents:\s*read\s*$", workflow_text) is not None,
    "expected permissions: contents: read",
)
assert_true(
    "ci workflow uses fixed Ubuntu runner",
    re.search(r"(?m)^\s*runs-on:\s*ubuntu-24[.]04\s*$", workflow_text) is not None,
    "expected runs-on: ubuntu-24.04",
)
assert_true(
    "ci workflow does not use mutable Ubuntu latest runner",
    "ubuntu-latest" not in workflow_text,
    "ubuntu-latest must not be used in deterministic PR CI",
)
assert_true(
    "ci workflow does not install Claude Code",
    "@anthropic-ai/claude-code" not in workflow_text,
    "external AI CLI install is not allowed",
)
assert_true(
    "ci workflow does not invoke AI CLIs",
    re.search(r"(?m)^\s*(claude|codex|gemini)(\s|$)", workflow_text) is None,
    "claude/codex/gemini commands are not allowed",
)
assert_true(
    "ci workflow invokes deterministic runner",
    "bash scripts/run-deterministic-tests.sh" in workflow_text,
    "workflow must call scripts/run-deterministic-tests.sh",
)
assert_true(
    "ci workflow fetches history for version-bump guard",
    re.search(
        r"(?ms)uses:\s*actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5\s*\n\s*with:\s*\n\s*fetch-depth:\s*0\s*$",
        workflow_text,
    )
    is not None,
    "checkout must fetch enough history for scripts/check_version_bump.py to compare against origin/main",
)
assert_true(
    "ci workflow does not duplicate clean-room smoke step",
    "run-cleanroom-smoke.sh" not in workflow_text,
    "clean-room smoke should be reached through the deterministic runner, not a second workflow step",
)
assert_true(
    "ci workflow does not run release smoke or Emporium actions directly",
    "lib/release-smoke.sh" not in workflow_text
    and "update-emporium-marketplace.sh" not in workflow_text
    and "EMPORIUM_" not in workflow_text,
    "deterministic PR CI must not perform release/Emporium actions directly",
)

assert_true("deterministic runner exists", runner.exists(), f"missing {runner}")
assert_true(
    "deterministic runner does not call itself",
    "run-deterministic-tests.sh" not in runner_text.replace("run-deterministic-tests.sh -- local deterministic checks for PR CI", ""),
    "runner must not recursively invoke itself",
)
assert_true(
    "deterministic runner runs top-level tests",
    "find \"${find_args[@]}\"" in runner_text and "$REPO_ROOT/tests" in runner_text and "-maxdepth 1" in runner_text,
    "runner must include top-level tests/test-*.sh",
)
assert_true("clean-room smoke test exists", cleanroom_test.exists(), f"missing {cleanroom_test}")
assert_true(
    "clean-room smoke test is top-level test-*.sh",
    cleanroom_test.parent == repo_root / "tests" and cleanroom_test.name == "test-cleanroom-smoke.sh",
    "clean-room smoke test must stay discoverable by the top-level deterministic runner",
)
assert_true("clean-room smoke script exists", cleanroom_smoke.exists(), f"missing {cleanroom_smoke}")
assert_true(
    "deterministic runner does not permanently exclude clean-room smoke",
    "! -name 'test-cleanroom-smoke.sh'" not in runner_text
    and re.search(r"grep\s+-v\s+.*test-cleanroom-smoke[.]sh", runner_text) is None,
    "clean-room smoke must not be unconditionally excluded from deterministic CI",
)
assert_true(
    "deterministic runner has clean-room recursion guard",
    "SIGNUM_CLEANROOM_SMOKE_ACTIVE" in runner_text
    and "test-cleanroom-smoke.sh" in runner_text
    and "continue" in runner_text,
    "runner must skip nested clean-room smoke only when SIGNUM_CLEANROOM_SMOKE_ACTIVE=1",
)
assert_true(
    "clean-room test invokes clean-room smoke script",
    'SMOKE_SCRIPT="$REPO_ROOT/scripts/run-cleanroom-smoke.sh"' in cleanroom_test_text
    and 'bash "$SMOKE_SCRIPT"' in cleanroom_test_text,
    "test-cleanroom-smoke.sh must call scripts/run-cleanroom-smoke.sh",
)
assert_true(
    "clean-room test uses targeted non-recursive mode",
    "SIGNUM_CLEANROOM_FULL=0" in cleanroom_test_text,
    "CI should not run the optional full clean-room suite by default",
)
assert_true(
    "clean-room smoke marks inner commands active",
    "SIGNUM_CLEANROOM_SMOKE_ACTIVE=1" in cleanroom_smoke_text,
    "inner clean-room commands must set recursion guard flag",
)
assert_true(
    "deterministic runner runs platform tests",
    "platforms/claude-code/tests" in runner_text,
    "runner must include mirrored platform shell tests",
)
assert_true(
    "deterministic runner runs offline evals",
    "python3 evals/run.py" in runner_text,
    "runner must run evals/run.py when present",
)
assert_true(
    "deterministic runner does not invoke AI CLIs",
    "@anthropic-ai/claude-code" not in runner_text
    and re.search(r"(?m)^\s*(claude|codex|gemini)(\s|$)", runner_text) is None,
    "runner must not invoke external AI CLIs",
)

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
