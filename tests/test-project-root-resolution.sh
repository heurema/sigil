#!/usr/bin/env bash
# test-project-root-resolution.sh -- keep /signum project-root resolution deterministic and local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
command_files = [
    repo_root / "commands" / "signum.md",
    repo_root / "platforms" / "claude-code" / "commands" / "signum.md",
]

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


banned_patterns = {
    "hardcoded skill7 home scan": r"\$HOME/personal/skill7|personal/skill7",
    "hardcoded works home scan": r"\$HOME/works",
    "hardcoded projects home scan": r"\$HOME/projects",
    "home search loop variable": r"\bSEARCH_DIR\b",
    "task text lowercasing for root discovery": r"\bTASK_LOWER\b",
    "plugin-name root matching": r"\bPLUGIN_NAME\b|Auto-detected project",
    "plugin manifest find scan": r"find\s+\"\$SEARCH_DIR\"|\.claude-plugin/\*",
    "parent/sibling directory scan": r"\$CURRENT_DIR/\.\.",
}

required_patterns = {
    "uses SIGNUM_PROJECT_ROOT override": r"SIGNUM_PROJECT_ROOT",
    "validates project root directory": r"project root is not a directory",
    "canonicalizes with pwd -P": r"pwd -P",
    "uses git root fallback": r"git rev-parse --show-toplevel",
    "documents current-directory-only fallback": r"Using current directory only",
    "exports PROJECT_ROOT": r"export PROJECT_ROOT",
}

for path in command_files:
    rel = path.relative_to(repo_root)
    text = path.read_text(encoding="utf-8")
    assert_true(f"{rel} exists", path.exists(), f"missing {rel}")

    for name, pattern in banned_patterns.items():
        assert_true(
            f"{rel} has no {name}",
            re.search(pattern, text) is None,
            f"found banned pattern {pattern!r}",
        )

    for name, pattern in required_patterns.items():
        assert_true(
            f"{rel} {name}",
            re.search(pattern, text) is not None,
            f"missing required pattern {pattern!r}",
        )

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
