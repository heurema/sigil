#!/usr/bin/env bash
# test-toolchain-pinning.sh -- static reproducibility checks for workflow templates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
root_template = repo_root / "lib" / "templates" / "signum-gate.yml"
overlay_template = repo_root / "platforms" / "claude-code" / "lib" / "templates" / "signum-gate.yml"
root_versions = repo_root / "lib" / "tool-versions.env"
overlay_versions = repo_root / "platforms" / "claude-code" / "lib" / "tool-versions.env"

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


def read(path):
    return path.read_text(encoding="utf-8") if path.exists() else ""


def parse_env(path):
    values = {}
    for line in read(path).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def check_template(label, path):
    text = read(path)
    assert_true(f"{label} template exists", path.exists(), f"missing {path}")
    assert_true(
        f"{label} has no bare Claude Code install",
        re.search(r"(?m)^\s*npm\s+install\s+-g\s+@anthropic-ai/claude-code\s*$", text) is None,
        "bare npm install -g @anthropic-ai/claude-code is not reproducible",
    )
    assert_true(
        f"{label} loads tool versions source",
        ". lib/tool-versions.env" in text,
        "template must load lib/tool-versions.env",
    )
    assert_true(
        f"{label} installs pinned Claude Code package",
        'npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"' in text,
        "template must install @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}",
    )
    assert_true(
        f"{label} rejects empty/latest/stable version",
        '""|latest|stable)' in text,
        "template must reject empty/latest/stable CLAUDE_CODE_VERSION",
    )
    assert_true(
        f"{label} validates semver-like version",
        "CLAUDE_CODE_VERSION is not semver-like" in text,
        "template must validate semver-like CLAUDE_CODE_VERSION",
    )


root_env = parse_env(root_versions)
overlay_env = parse_env(overlay_versions)
version = root_env.get("CLAUDE_CODE_VERSION", "")

assert_true("root tool versions file exists", root_versions.exists(), f"missing {root_versions}")
assert_true("root CLAUDE_CODE_VERSION exists", bool(version), "missing CLAUDE_CODE_VERSION")
assert_true(
    "root CLAUDE_CODE_VERSION is semver-like",
    re.fullmatch(r"[0-9]+[.][0-9]+[.][0-9]+([-.+][0-9A-Za-z.-]+)?", version or "") is not None,
    f"not semver-like: {version!r}",
)
assert_true(
    "root CLAUDE_CODE_VERSION is not floating",
    version not in {"", "latest", "stable"},
    "version must not be empty/latest/stable",
)

check_template("root", root_template)

if overlay_template.exists() or overlay_versions.exists():
    assert_true("overlay tool versions file exists", overlay_versions.exists(), f"missing {overlay_versions}")
    assert_true(
        "overlay tool versions match root",
        overlay_env.get("CLAUDE_CODE_VERSION") == version,
        f"expected {version}, got {overlay_env.get('CLAUDE_CODE_VERSION')}",
    )
    check_template("overlay", overlay_template)
    assert_true(
        "overlay template matches root template",
        read(overlay_template) == read(root_template),
        "overlay template must stay mirrored with root template",
    )

print("")
print(f"CLAUDE_CODE_VERSION={version}")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
