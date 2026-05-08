#!/usr/bin/env bash
# test-metadata-consistency.sh -- keep Signum version and proofpack schema metadata aligned
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import json
import os
import re
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
passed = 0
failed = 0


def pass_(name):
    global passed
    print(f"  PASS: {name}")
    passed += 1


def fail(name, message):
    global failed
    print(f"  FAIL: {name} -- {message}")
    failed += 1


def read(rel):
    return (repo_root / rel).read_text(encoding="utf-8")


def one_or_fail(name, rel, pattern):
    values = re.findall(pattern, read(rel), flags=re.MULTILINE)
    values = [v[0] if isinstance(v, tuple) else v for v in values]
    if not values:
        fail(name, f"missing pattern {pattern!r} in {rel}")
        return None
    unique = sorted(set(values))
    if len(unique) != 1:
        fail(name, f"expected one value in {rel}, found {unique}")
        return None
    return unique[0]


def assert_all_eq(name, rel, pattern, expected):
    values = re.findall(pattern, read(rel), flags=re.MULTILINE)
    values = [v[0] if isinstance(v, tuple) else v for v in values]
    if not values:
        fail(name, f"missing pattern {pattern!r} in {rel}")
        return
    bad = sorted(set(v for v in values if v != expected))
    if bad:
        fail(name, f"expected {expected}, found {bad} in {rel}")
    else:
        pass_(name)


plugin_version = json.loads(read(".claude-plugin/plugin.json"))["version"]
codex_plugin_path = repo_root / ".codex-plugin/plugin.json"
codex_marketplace_plugin_path = repo_root / "platforms/codex/.codex-plugin/plugin.json"
root_schema = one_or_fail(
    "root proofpack schema source exists",
    "commands/signum.md",
    r'--arg\s+schemaVersion\s+"([0-9]+\.[0-9]+)"',
)

if root_schema:
    pass_(f"root proofpack schema source is {root_schema}")

command_files = ["commands/signum.md"]
if (repo_root / "platforms/claude-code/commands/signum.md").exists():
    command_files.append("platforms/claude-code/commands/signum.md")

doc_files = ["docs/how-it-works.md"]
if (repo_root / "platforms/claude-code/docs/how-it-works.md").exists():
    doc_files.append("platforms/claude-code/docs/how-it-works.md")

if (repo_root / "platforms/claude-code/.claude-plugin/plugin.json").exists():
    overlay_version = json.loads(read("platforms/claude-code/.claude-plugin/plugin.json"))["version"]
    if overlay_version == plugin_version:
        pass_("Claude overlay plugin version matches root")
    else:
        fail("Claude overlay plugin version matches root", f"expected {plugin_version}, got {overlay_version}")

if codex_plugin_path.exists():
    codex_version = json.loads(read(".codex-plugin/plugin.json"))["version"]
    if codex_version == plugin_version:
        pass_("Codex plugin version matches root")
    else:
        fail("Codex plugin version matches root", f"expected {plugin_version}, got {codex_version}")

if codex_marketplace_plugin_path.exists():
    codex_marketplace_version = json.loads(read("platforms/codex/.codex-plugin/plugin.json"))["version"]
    if codex_marketplace_version == plugin_version:
        pass_("Codex marketplace plugin version matches root")
    else:
        fail("Codex marketplace plugin version matches root", f"expected {plugin_version}, got {codex_marketplace_version}")

for rel in command_files:
    assert_all_eq(
        f"{rel} /signum explain version matches plugin",
        rel,
        r'^\s+"version":\s+"([0-9]+\.[0-9]+\.[0-9]+)",',
        plugin_version,
    )
    assert_all_eq(
        f"{rel} proofpack signumVersion matches plugin",
        rel,
        r'--arg\s+signumVersion\s+"([0-9]+\.[0-9]+\.[0-9]+)"',
        plugin_version,
    )
    if root_schema:
        assert_all_eq(
            f"{rel} proofpack schemaVersion matches root runtime",
            rel,
            r'--arg\s+schemaVersion\s+"([0-9]+\.[0-9]+)"',
            root_schema,
        )
        assert_all_eq(
            f"{rel} proofpack goal schema label matches root runtime",
            rel,
            r'proof package \(schema v([0-9]+\.[0-9]+)\)',
            root_schema,
        )
        assert_all_eq(
            f"{rel} proofpack completion schema label matches root runtime",
            rel,
            r'Proofpack written: \$RUN_ID \(schema v([0-9]+\.[0-9]+)\)',
            root_schema,
        )

if root_schema:
    for rel in doc_files:
        assert_all_eq(
            f"{rel} proofpack JSON schemaVersion example matches runtime",
            rel,
            r'^\s+"schemaVersion":\s+"([0-9]+\.[0-9]+)",',
            root_schema,
        )

print("")
print(f"Plugin version: {plugin_version}")
print(f"Proofpack schema version: {root_schema or 'unavailable'}")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
