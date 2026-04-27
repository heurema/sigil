#!/usr/bin/env bash
# test-release-workflow-hardening.sh -- static checks for release workflow safety
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
workflow_path = repo_root / ".github" / "workflows" / "release-guardrails.yml"
text = workflow_path.read_text(encoding="utf-8") if workflow_path.exists() else ""

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


def block_between(start_marker, end_marker=None):
    start = text.find(start_marker)
    if start == -1:
        return ""
    if end_marker is None:
        return text[start:]
    end = text.find(end_marker, start + len(start_marker))
    if end == -1:
        return text[start:]
    return text[start:end]


preflight = block_between("- name: Release preflight", "- name: Checkout Emporium registry (dry run)")
dry_checkout = block_between(
    "- name: Checkout Emporium registry (dry run)",
    "- name: Checkout Emporium registry (write)",
)
write_checkout = block_between(
    "- name: Checkout Emporium registry (write)",
    "- name: Sync Emporium marketplace entry",
)
sync_step = block_between("- name: Sync Emporium marketplace entry", "- name: Run release smoke path")

assert_true("release workflow exists", workflow_path.exists(), f"missing {workflow_path}")
assert_true("workflow has explicit permissions block", "permissions:\n  contents: read" in text, "expected contents: read")
assert_true(
    "workflow uses fixed Ubuntu runner",
    re.search(r"(?m)^\s*runs-on:\s*ubuntu-24[.]04\s*$", text) is not None,
    "expected runs-on: ubuntu-24.04",
)
assert_true(
    "workflow does not use mutable Ubuntu latest runner",
    "ubuntu-latest" not in text,
    "ubuntu-latest must not be used in release workflow",
)
assert_true("workflow does not request contents write", "contents: write" not in text, "contents: write is not needed")
assert_true("workflow does not use pull_request_target", "pull_request_target" not in text, "release workflow must not use pull_request_target")
assert_true("workflow does not use set -x", "set -x" not in text, "secret-handling paths must not use set -x")
assert_true(
    "workflow does not echo EMPORIUM_SSH_KEY value",
    re.search(r"echo\s+.*(\$\{?EMPORIUM_SSH_KEY|\bsecrets[.]EMPORIUM_SSH_KEY\b)", text) is None,
    "must not echo secret variable or secrets context",
)

assert_true("workflow defines dry-run dispatch input", "dry_run:" in text, "missing workflow_dispatch dry_run input")
assert_true("workflow exposes SIGNUM_RELEASE_DRY_RUN", "SIGNUM_RELEASE_DRY_RUN:" in text, "missing dry-run env")
assert_true("workflow validates dry-run values", 'SIGNUM_RELEASE_DRY_RUN must be 0 or 1' in preflight, "missing dry-run validation")
assert_true(
    "workflow does not require key in dry-run preflight",
    '[ "$SIGNUM_RELEASE_DRY_RUN" != "1" ] && [ -z "${EMPORIUM_SSH_KEY:-}" ]' in preflight,
    "missing conditional EMPORIUM_SSH_KEY guard",
)

assert_true("preflight validates target repo", "EMPORIUM_REPO is required" in preflight, "missing repo validation")
assert_true("preflight validates target ref", "EMPORIUM_GIT_REF is required" in preflight, "missing ref validation")
assert_true("preflight validates target path", "EMPORIUM_PATH is required" in preflight, "missing path validation")
assert_true("preflight validates plugin metadata source", ".claude-plugin/plugin.json" in preflight, "missing plugin metadata check")
assert_true("preflight validates sync helper source", "lib/update-emporium-marketplace.sh" in preflight, "missing sync helper check")
assert_true("preflight prints non-secret summary", "Release preflight:" in preflight and "target repo:" in preflight, "missing preflight summary")

assert_true("workflow has explicit Emporium repo default", "EMPORIUM_REPO:" in text and "heurema/emporium" in text, "missing explicit repo")
assert_true("workflow has explicit Emporium ref default", "EMPORIUM_GIT_REF:" in text and "'main'" in text, "missing explicit ref")
assert_true("workflow has explicit Emporium path default", "EMPORIUM_PATH:" in text and ".claude-plugin/marketplace.json" in text, "missing explicit path")

assert_true("dry-run checkout avoids ssh key", "ssh-key:" not in dry_checkout, "dry-run checkout must not use EMPORIUM_SSH_KEY")
assert_true("dry-run checkout avoids persisted credentials", "persist-credentials: false" in dry_checkout, "dry-run checkout must not persist credentials")
assert_true("write checkout is non-dry-run only", "SIGNUM_RELEASE_DRY_RUN != '1'" in write_checkout, "write checkout must be gated")
assert_true("write checkout uses EMPORIUM_SSH_KEY", "ssh-key: ${{ secrets.EMPORIUM_SSH_KEY }}" in write_checkout, "normal write checkout must use SSH key")

assert_true("sync checks marketplace file after checkout", "Emporium marketplace file not found after checkout" in sync_step, "missing marketplace file check")
assert_true("sync runs marketplace updater", "bash lib/update-emporium-marketplace.sh" in sync_step, "missing sync helper invocation")
assert_true("dry-run shows status summary", "git -C _external/emporium status --short" in sync_step, "missing dry-run status summary")
assert_true("dry-run skips commit and push", "SIGNUM_RELEASE_DRY_RUN=1; skipping Emporium commit and git push." in sync_step, "missing dry-run skip")

dry_skip_index = sync_step.find('SIGNUM_RELEASE_DRY_RUN=1; skipping Emporium commit and git push.')
push_index = sync_step.find('git -C _external/emporium push origin "HEAD:${EMPORIUM_GIT_REF}"')
assert_true("dry-run skip appears before git push", dry_skip_index != -1 and push_index != -1 and dry_skip_index < push_index, "dry-run guard must precede push")
assert_true("normal path still pushes Emporium ref", push_index != -1, "normal Emporium push path missing")
assert_true("workflow does not use old push token", "EMPORIUM_PUSH_TOKEN" not in text, "old push token should not return")

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
