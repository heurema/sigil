#!/usr/bin/env bash
# test-legacy-root-helper-callsites.sh -- guard classified LEGACY_ROOT_COMPAT helper call sites
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
allowlist_path = repo_root / "tests" / "fixtures" / "legacy-root-helper-callsite-allowlist.txt"
inventory_doc = repo_root / "docs" / "legacy-root-helper-callsite-inventory.md"

helpers = [
    "sync_contract_artifacts",
    "remove_root_artifact_view",
    "purge_root_working_set_views",
    "link_active_artifact",
    "ensure_active_artifact_dir",
    "reset_active_artifact",
    "promote_root_artifact_to_active",
]

allowed_categories = {
    "definition",
    "normal-runtime",
    "legacy-archive-close-cleanup",
    "legacy-final-output-cleanup",
    "legacy-resume-import-restart",
    "ci-fallback",
    "test",
    "docs/prose",
    "unknown",
}

helper_re = re.compile(r"\b(" + "|".join(re.escape(helper) for helper in helpers) + r")\b")

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


def rel(path):
    return path.relative_to(repo_root).as_posix()


def scan_files():
    files = [
        repo_root / "commands" / "signum.md",
        repo_root / "platforms" / "claude-code" / "commands" / "signum.md",
    ]
    files.extend(sorted((repo_root / "lib").glob("*.sh")))
    overlay_lib = repo_root / "platforms" / "claude-code" / "lib"
    if overlay_lib.exists():
        files.extend(sorted(overlay_lib.glob("*.sh")))
    scripts = repo_root / "scripts"
    if scripts.exists():
        files.extend(sorted(scripts.glob("*.py")))
    files.extend(sorted((repo_root / "tests").glob("test-*.sh")))
    overlay_tests = repo_root / "platforms" / "claude-code" / "tests"
    if overlay_tests.exists():
        files.extend(sorted(overlay_tests.rglob("*.sh")))

    seen = []
    for path in files:
        if path.exists() and path not in seen:
            seen.append(path)
    return seen


def strip_quoted_strings(line):
    out = []
    quote = None
    i = 0
    while i < len(line):
        char = line[i]
        if quote:
            if char == "\\":
                i += 2
                continue
            if char == quote:
                quote = None
            i += 1
            continue
        if char in {"'", '"', "`"}:
            quote = char
            i += 1
            continue
        out.append(char)
        i += 1
    return "".join(out)


def scan_executable_mentions():
    occurrences = []
    for path in scan_files():
        file_rel = rel(path)
        for line_number, raw_line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            if not raw_line.strip() or raw_line.lstrip().startswith("#"):
                continue
            line = strip_quoted_strings(raw_line)
            for match in helper_re.finditer(line):
                helper = match.group(1)
                kind = "call"
                if re.match(rf"\s*(function\s+)?{re.escape(helper)}\s*\(\)\s*\{{", line):
                    kind = "definition"
                occurrences.append(
                    {
                        "kind": kind,
                        "helper": helper,
                        "file": file_rel,
                        "line": line_number,
                        "text": raw_line.strip(),
                    }
                )
    return occurrences


def load_allowlist():
    entries = []
    malformed = []
    duplicates = []
    seen = set()
    if not allowlist_path.exists():
        return entries, [f"missing {allowlist_path}"], duplicates

    for line_number, raw in enumerate(allowlist_path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|", 4)
        if len(parts) != 5:
            malformed.append(f"line {line_number}: expected 5 pipe-separated fields")
            continue
        category, helper, file_path, expected_count, context = parts
        if category not in allowed_categories:
            malformed.append(f"line {line_number}: unknown category {category!r}")
        if category == "unknown":
            malformed.append(f"line {line_number}: unknown call sites must be resolved before allowlisting")
        if helper not in helpers:
            malformed.append(f"line {line_number}: unknown helper {helper!r}")
        if file_path.startswith("/") or ".." in Path(file_path).parts:
            malformed.append(f"line {line_number}: file path must be repo-relative")
        if not context or context == "*":
            malformed.append(f"line {line_number}: context must be specific")
        try:
            expected = int(expected_count)
        except ValueError:
            malformed.append(f"line {line_number}: expected_count is not an integer")
            continue
        if expected < 1:
            malformed.append(f"line {line_number}: expected_count must be positive")
        key = (category, helper, file_path, context)
        if key in seen:
            duplicates.append(f"line {line_number}: duplicate allowlist key {key}")
        seen.add(key)
        entries.append(
            {
                "category": category,
                "kind": "definition" if category == "definition" else "call",
                "helper": helper,
                "file": file_path,
                "expected": expected,
                "context": context,
                "line": line_number,
            }
        )
    return entries, malformed, duplicates


occurrences = scan_executable_mentions()
allowlist, malformed, duplicates = load_allowlist()

assert_true("call-site allowlist exists", allowlist_path.exists(), f"missing {allowlist_path}")
assert_true("call-site allowlist has no malformed entries", not malformed, "\n".join(malformed))
assert_true("call-site allowlist has no duplicate entries", not duplicates, "\n".join(duplicates))

found_by_kind = Counter((item["kind"], item["helper"], item["file"]) for item in occurrences)
found_lines = defaultdict(list)
for item in occurrences:
    found_lines[(item["kind"], item["helper"], item["file"])].append(item["line"])

allowed_by_kind = Counter()
allowlist_contexts = defaultdict(list)
for entry in allowlist:
    key = (entry["kind"], entry["helper"], entry["file"])
    allowed_by_kind[key] += entry["expected"]
    allowlist_contexts[key].append(entry["context"])

unknown = sorted(set(found_by_kind) - set(allowed_by_kind))
stale = sorted(set(allowed_by_kind) - set(found_by_kind))
mismatches = []
for key in sorted(set(found_by_kind) & set(allowed_by_kind)):
    if found_by_kind[key] != allowed_by_kind[key]:
        mismatches.append((key, allowed_by_kind[key], found_by_kind[key], found_lines[key], allowlist_contexts[key]))

assert_true(
    "no unclassified legacy helper definitions or calls",
    not unknown,
    "\n".join(
        f"{kind}|{helper}|{file} lines={found_lines[(kind, helper, file)]}"
        for kind, helper, file in unknown
    ),
)
assert_true(
    "call-site allowlist entries are not stale",
    not stale,
    "\n".join(f"{kind}|{helper}|{file}" for kind, helper, file in stale),
)
assert_true(
    "call-site allowlist counts match executable mentions",
    not mismatches,
    "\n".join(
        f"{kind}|{helper}|{file} expected={expected} actual={actual} lines={lines} contexts={contexts}"
        for (kind, helper, file), expected, actual, lines, contexts in mismatches
    ),
)

doc_text = inventory_doc.read_text(encoding="utf-8") if inventory_doc.exists() else ""
assert_true("call-site inventory doc exists", inventory_doc.exists(), f"missing {inventory_doc}")
for helper in helpers:
    assert_true(f"inventory doc lists {helper}", helper in doc_text, f"missing {helper}")
assert_true("inventory doc says runtime behavior is unchanged", "does not change runtime behavior" in doc_text, "missing behavior note")
assert_true("inventory doc lists migration candidates", "Migration candidates" in doc_text and "normal-runtime" in doc_text, "missing migration candidate section")
assert_true("inventory doc records root-only finalization cleanup difference", "three additional" in doc_text and "Final Output" in doc_text, "missing root/overlay difference note")
assert_true(
    "inventory doc classifies Final Output cleanup exception",
    "legacy-final-output-cleanup" in doc_text
    and "exactly three" in doc_text
    and "overlay Final Output has zero" in doc_text,
    "missing bounded Final Output cleanup classification",
)

normal_runtime_entries = [
    entry for entry in allowlist
    if entry["category"] == "normal-runtime"
]
assert_true(
    "no normal-runtime LEGACY_ROOT_COMPAT allowlist entries remain",
    not normal_runtime_entries,
    "\n".join(
        f"line {entry['line']}: {entry['helper']} in {entry['file']}"
        for entry in normal_runtime_entries
    ),
)

final_output_entries = [
    entry for entry in allowlist
    if entry["category"] == "legacy-final-output-cleanup"
]
assert_true(
    "Final Output legacy cleanup allowlist is explicit and bounded",
    len(final_output_entries) == 1
    and final_output_entries[0]["helper"] == "purge_root_working_set_views"
    and final_output_entries[0]["file"] == "commands/signum.md"
    and final_output_entries[0]["expected"] == 3,
    repr(final_output_entries),
)

root_contract_dir = repo_root / "lib" / "contract-dir.sh"
overlay_contract_dir = repo_root / "platforms" / "claude-code" / "lib" / "contract-dir.sh"
if overlay_contract_dir.exists():
    assert_true(
        "root and Claude overlay contract-dir remain identical",
        root_contract_dir.read_text(encoding="utf-8") == overlay_contract_dir.read_text(encoding="utf-8"),
        "contract-dir mirror drift",
    )

def command_call_counts(file_path):
    return Counter(
        item["helper"]
        for item in occurrences
        if item["kind"] == "call" and item["file"] == file_path
    )


def helper_counts_in_text(text):
    counts = Counter()
    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        line = strip_quoted_strings(raw_line)
        for match in helper_re.finditer(line):
            counts[match.group(1)] += 1
    return counts


def final_output_section(file_path):
    text = (repo_root / file_path).read_text(encoding="utf-8", errors="ignore")
    marker = "\n## Final Output"
    if marker not in text:
        return ""
    return text.split(marker, 1)[1]


root_command_counts = command_call_counts("commands/signum.md")
overlay_command_counts = command_call_counts("platforms/claude-code/commands/signum.md")
command_count_diffs = {}
for helper in helpers:
    root_count = root_command_counts.get(helper, 0)
    overlay_count = overlay_command_counts.get(helper, 0)
    if helper == "purge_root_working_set_views":
        if root_count - overlay_count != 3:
            command_count_diffs[helper] = (root_count, overlay_count, "expected root to have exactly 3 additional Final Output cleanup calls")
    elif root_count != overlay_count:
        command_count_diffs[helper] = (root_count, overlay_count, "expected equal root/overlay command counts")

assert_true(
    "root/overlay command call counts match except documented finalization cleanup",
    not command_count_diffs,
    "\n".join(f"{helper}: root={root} overlay={overlay} ({note})" for helper, (root, overlay, note) in command_count_diffs.items()),
)

root_final_output_counts = helper_counts_in_text(final_output_section(Path("commands/signum.md")))
overlay_final_output_counts = helper_counts_in_text(final_output_section(Path("platforms/claude-code/commands/signum.md")))
assert_true(
    "root Final Output legacy cleanup is bounded to purge helper",
    root_final_output_counts == Counter({"purge_root_working_set_views": 3}),
    repr(root_final_output_counts),
)
assert_true(
    "overlay Final Output has no LEGACY_ROOT_COMPAT helper calls",
    not overlay_final_output_counts,
    repr(overlay_final_output_counts),
)

print("")
print(f"Classified executable legacy helper mention groups: {len(found_by_kind)}")
print(f"Classified executable legacy helper mentions: {sum(found_by_kind.values())}")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
