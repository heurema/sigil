#!/usr/bin/env bash
# test-contract-dir-legacy-isolation.sh -- guard legacy root compatibility isolation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
root_path = repo_root / "lib" / "contract-dir.sh"
overlay_path = repo_root / "platforms" / "claude-code" / "lib" / "contract-dir.sh"
inventory_doc = repo_root / "docs" / "artifact-path-inventory.md"

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


root_text = root_path.read_text(encoding="utf-8") if root_path.exists() else ""
overlay_text = overlay_path.read_text(encoding="utf-8") if overlay_path.exists() else ""
lines = root_text.splitlines()

assert_true("root contract-dir exists", root_path.exists(), f"missing {root_path}")
assert_true("overlay contract-dir exists", overlay_path.exists(), f"missing {overlay_path}")
assert_true("root and overlay contract-dir are byte-for-byte identical", root_text == overlay_text, "overlay mirror drift")

for section in [
    "Neutral/shared helpers",
    "Canonical contract artifact helpers",
    "Canonical contract registry and active-root helpers",
    "Canonical archive helpers",
    "Legacy root artifact compatibility layer",
]:
    assert_true(f"contract-dir has {section} section", section in root_text, f"missing section: {section}")

function_matches = list(re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{", root_text, flags=re.MULTILINE))
function_names = [match.group(1) for match in function_matches]
function_ranges = {}
for index, match in enumerate(function_matches):
    name = match.group(1)
    start_line = root_text[: match.start()].count("\n") + 1
    if index + 1 < len(function_matches):
        end_line = root_text[: function_matches[index + 1].start()].count("\n")
    else:
        end_line = len(lines)
    function_ranges[name] = (start_line, end_line)

public_functions = {
    "new_contract_id",
    "contract_dir",
    "init_contract_dir",
    "sync_contract_artifacts",
    "register_contract",
    "set_active_contract",
    "clear_active_contract",
    "update_contract_status",
    "get_active_contract",
    "get_contract_status",
    "describe_active_contract_state",
    "active_artifact_root",
    "active_artifact_path",
    "reset_canonical_active_artifact",
    "verify_canonical_contract_artifacts",
    "link_active_artifact",
    "ensure_active_artifact_dir",
    "remove_root_artifact_view",
    "archive_contract_artifacts",
    "purge_root_working_set_views",
    "reset_active_artifact",
    "promote_root_artifact_to_active",
    "current_contract_dir",
}
missing_public = sorted(public_functions - set(function_names))
assert_true("public contract-dir function names are preserved", not missing_public, ", ".join(missing_public))

legacy_helpers = {
    "sync_contract_artifacts",
    "remove_root_artifact_view",
    "purge_root_working_set_views",
    "link_active_artifact",
    "ensure_active_artifact_dir",
    "reset_active_artifact",
    "promote_root_artifact_to_active",
}


def comment_window(name, before=8):
    if name not in function_ranges:
        return ""
    start, _ = function_ranges[name]
    lo = max(1, start - before)
    return "\n".join(lines[lo - 1 : start - 1])


unmarked_legacy = [
    name for name in sorted(legacy_helpers)
    if "LEGACY_ROOT_COMPAT:" not in comment_window(name)
]
assert_true("legacy root compatibility helpers are explicitly marked", not unmarked_legacy, ", ".join(unmarked_legacy))

canonical_helpers = {
    "contract_dir",
    "init_contract_dir",
    "_ensure_index",
    "register_contract",
    "set_active_contract",
    "clear_active_contract",
    "update_contract_status",
    "get_active_contract",
    "get_contract_status",
    "describe_active_contract_state",
    "active_artifact_root",
    "active_artifact_path",
    "reset_canonical_active_artifact",
    "verify_canonical_contract_artifacts",
    "archive_contract_artifacts",
}
misclassified_canonical = [
    name for name in sorted(canonical_helpers)
    if "LEGACY_ROOT_COMPAT:" in comment_window(name)
]
assert_true("canonical helpers are not marked as legacy", not misclassified_canonical, ", ".join(misclassified_canonical))

line_to_function = {}
for name, (start, end) in function_ranges.items():
    for line_number in range(start, end + 1):
        line_to_function[line_number] = name

dynamic_root_hits = []
for line_number, line in enumerate(lines, 1):
    if ".signum/${rel}" in line:
        dynamic_root_hits.append((line_number, line_to_function.get(line_number, "<top-level>")))

unclassified_dynamic_hits = [
    f"line {line_number} in {function_name}"
    for line_number, function_name in dynamic_root_hits
    if function_name not in legacy_helpers
]
assert_true(
    "dynamic root artifact path construction stays inside legacy helpers",
    not unclassified_dynamic_hits,
    "; ".join(unclassified_dynamic_hits),
)

doc_text = inventory_doc.read_text(encoding="utf-8") if inventory_doc.exists() else ""
assert_true(
    "inventory doc records isolated legacy compatibility layer",
    "legacy root artifact compatibility layer" in doc_text
    and "Runtime behavior is unchanged" in doc_text,
    "inventory doc missing isolation wording",
)

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
