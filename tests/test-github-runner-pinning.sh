#!/usr/bin/env bash
# test-github-runner-pinning.sh -- static checks for fixed GitHub-hosted runner labels
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
inventory_path = repo_root / "tests" / "fixtures" / "github-runner-labels.json"
scan_roots = [
    Path(".github/workflows"),
    Path("lib/templates"),
    Path("platforms/claude-code/lib/templates"),
]

mutable_latest_re = re.compile(r"^(ubuntu|windows|macos)-latest$")
fixed_github_hosted_labels = {
    "ubuntu-22.04",
    "ubuntu-22.04-arm",
    "ubuntu-24.04",
    "ubuntu-24.04-arm",
    "windows-2022",
    "windows-2025",
    "macos-13",
    "macos-13-large",
    "macos-13-xlarge",
    "macos-14",
    "macos-14-large",
    "macos-14-xlarge",
    "macos-15",
    "macos-15-large",
    "macos-15-xlarge",
}

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


def yaml_paths_under(root):
    full_root = repo_root / root
    if not full_root.exists():
        return []
    return sorted(
        path.relative_to(repo_root)
        for path in full_root.rglob("*")
        if path.is_file() and path.suffix in {".yml", ".yaml"}
    )


def strip_inline_comment(value):
    quote = ""
    for index, char in enumerate(value):
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in {"'", '"'}:
            quote = char
            continue
        if char == "#" and (index == 0 or value[index - 1].isspace()):
            return value[:index].rstrip()
    return value.strip()


def unquote(value):
    value = strip_inline_comment(value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def parse_inline_value(value):
    value = strip_inline_comment(value).strip()
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [unquote(part.strip()) for part in inner.split(",")]
    return unquote(value)


def parse_block_value(lines, start_index, base_indent):
    values = []
    for line in lines[start_index + 1 :]:
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= base_indent:
            break
        stripped = line.strip()
        if stripped.startswith("- "):
            values.append(unquote(stripped[2:]))
        else:
            values.append(unquote(stripped))
    if len(values) == 1:
        return values[0]
    return values


def normalized_runs_on(value):
    if isinstance(value, list):
        return [str(item) for item in value]
    return str(value)


def value_contains(value, needle_re):
    if isinstance(value, list):
        return any(needle_re.fullmatch(str(item)) for item in value)
    return needle_re.fullmatch(str(value)) is not None


def classify_runs_on(value):
    flat = " ".join(str(item) for item in value) if isinstance(value, list) else str(value)
    if not flat.strip():
        return "unknown"
    if "${{" in flat:
        if "matrix." in flat:
            return "matrix_expression"
        return "expression"
    if value_contains(value, mutable_latest_re):
        return "mutable_latest_label"
    if isinstance(value, list):
        if any(str(item) == "self-hosted" for item in value):
            return "self_hosted_runner"
        return "larger_runner_or_custom_label"
    if value == "self-hosted":
        return "self_hosted_runner"
    if value in fixed_github_hosted_labels:
        return "fixed_github_hosted_runner"
    if re.search(r"(^|[-_])(large|xlarge|[0-9]+core|[0-9]+cores)([-_]|$)", value):
        return "larger_runner_or_custom_label"
    if re.search(r"[A-Za-z0-9_.-]", value):
        return "larger_runner_or_custom_label"
    return "unknown"


def infer_context(lines, index):
    for cursor in range(index - 1, -1, -1):
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$", lines[cursor])
        if match:
            return f"jobs.{match.group(1)}"
    return "unknown"


def scan_file(path):
    lines = (repo_root / path).read_text(encoding="utf-8").splitlines()
    entries = []
    occurrence = 0
    for index, line in enumerate(lines):
        match = re.match(r"^(\s*)runs-on\s*:\s*(.*)$", line)
        if not match:
            continue
        occurrence += 1
        indent = len(match.group(1))
        raw_value = match.group(2).strip()
        runs_on = parse_inline_value(raw_value) if raw_value else parse_block_value(lines, index, indent)
        classification = classify_runs_on(runs_on)
        entries.append(
            {
                "file": path.as_posix(),
                "occurrence": occurrence,
                "line": index + 1,
                "context": infer_context(lines, index),
                "runsOn": normalized_runs_on(runs_on),
                "classification": classification,
            }
        )
    return entries


scan_paths = []
for root in scan_roots:
    scan_paths.extend(yaml_paths_under(root))
scan_paths = sorted(dict.fromkeys(scan_paths))

all_yaml_with_runs_on = []
for path in sorted(repo_root.rglob("*")):
    if not path.is_file() or path.suffix not in {".yml", ".yaml"}:
        continue
    rel = path.relative_to(repo_root)
    if ".git" in rel.parts:
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    if re.search(r"(?m)^\s*runs-on\s*:", text):
        all_yaml_with_runs_on.append(rel)

outside_scan = [path.as_posix() for path in all_yaml_with_runs_on if path not in scan_paths]
assert_true(
    "all YAML files with runs-on entries are in runner-label scan roots",
    not outside_scan,
    "missing scan coverage for: " + ", ".join(outside_scan),
)

actual = []
for path in scan_paths:
    actual.extend(scan_file(path))

assert_true("GitHub runner label inventory exists", inventory_path.exists(), f"missing {inventory_path}")
try:
    inventory = json.loads(inventory_path.read_text(encoding="utf-8")) if inventory_path.exists() else {}
except json.JSONDecodeError as exc:
    inventory = {}
    bad("GitHub runner label inventory is valid JSON", str(exc))
else:
    ok("GitHub runner label inventory is valid JSON")

inventory_entries = inventory.get("runners", []) if isinstance(inventory, dict) else []
allowlist_entries = inventory.get("mutableLatestAllowlist", []) if isinstance(inventory, dict) else []
skipped_entries = inventory.get("skipped", []) if isinstance(inventory, dict) else []
assert_true("inventory schema version is fixed", inventory.get("schemaVersion") == 1, "expected schemaVersion=1")
assert_true("inventory runners field is a list", isinstance(inventory_entries, list), "expected runners list")
assert_true("inventory mutableLatestAllowlist field is a list", isinstance(allowlist_entries, list), "expected mutableLatestAllowlist list")
assert_true("inventory skipped field is a list", isinstance(skipped_entries, list), "expected skipped list")
assert_true(
    "inventory scan roots match test scan roots",
    inventory.get("scanRoots") == [root.as_posix() for root in scan_roots],
    f"expected scanRoots={[root.as_posix() for root in scan_roots]!r}",
)

# Unit checks protect the classifier from rejecting runner categories that are
# allowed when explicitly inventoried.
classifier_examples = [
    ("ubuntu-24.04", "fixed_github_hosted_runner"),
    ("ubuntu-latest", "mutable_latest_label"),
    ("windows-latest", "mutable_latest_label"),
    ("macos-latest", "mutable_latest_label"),
    ("self-hosted", "self_hosted_runner"),
    (["self-hosted", "linux", "x64"], "self_hosted_runner"),
    ("project-large-runner", "larger_runner_or_custom_label"),
    ("${{ matrix.runner }}", "matrix_expression"),
]
for value, expected in classifier_examples:
    assert_true(
        f"classifier accepts {value!r} as {expected}",
        classify_runs_on(value) == expected,
        f"got {classify_runs_on(value)!r}",
    )

for entry in actual:
    where = f"{entry['file']}:{entry['line']}"
    runs_on = entry["runsOn"]
    classification = entry["classification"]
    assert_true(
        f"no ubuntu-latest remains at {where}",
        runs_on != "ubuntu-latest" and not (isinstance(runs_on, list) and "ubuntu-latest" in runs_on),
        f"mutable Ubuntu label remains: {runs_on!r}",
    )
    if classification in {"fixed_github_hosted_runner", "self_hosted_runner", "larger_runner_or_custom_label", "matrix_expression", "expression"}:
        ok(f"runner classification is explicit at {where}")
    elif classification == "mutable_latest_label":
        ok(f"runner mutable latest is classified at {where}")
    else:
        bad(f"runner classification is explicit at {where}", f"unknown runs-on value {runs_on!r}")

allowlist_by_key = {}
for item in allowlist_entries:
    key = (item.get("file"), item.get("occurrence"))
    allowlist_by_key[key] = item

for entry in actual:
    key = (entry["file"], entry["occurrence"])
    if entry["classification"] != "mutable_latest_label":
        continue
    allow = allowlist_by_key.get(key)
    assert_true(
        f"mutable latest runner at {key} is explicitly allowlisted",
        allow is not None and isinstance(allow.get("reason"), str) and bool(allow.get("reason")),
        "mutable *-latest runner labels require an allowlist reason",
    )

expected_by_key = {}
for entry in actual:
    key = (entry["file"], entry["occurrence"])
    expected_by_key[key] = {
        "file": entry["file"],
        "occurrence": entry["occurrence"],
        "context": entry["context"],
        "runsOn": entry["runsOn"],
        "classification": entry["classification"],
    }

inventory_by_key = {}
for inv in inventory_entries:
    key = (inv.get("file"), inv.get("occurrence"))
    if key in inventory_by_key:
        bad("inventory has duplicate file/occurrence entries", f"duplicate {key}")
    inventory_by_key[key] = inv

missing = [key for key in sorted(expected_by_key) if key not in inventory_by_key]
stale = [key for key in sorted(inventory_by_key) if key not in expected_by_key]
assert_true("inventory has no missing runs-on entries", not missing, f"missing {missing}")
assert_true("inventory has no stale runs-on entries", not stale, f"stale {stale}")

for key, expected in sorted(expected_by_key.items()):
    inv = inventory_by_key.get(key)
    if inv is None:
        continue
    for field, expected_value in expected.items():
        assert_true(
            f"inventory {field} matches scan for {key}",
            inv.get(field) == expected_value,
            f"expected {field}={expected_value!r}, got {inv.get(field)!r}",
        )
    assert_true(
        f"inventory reason exists for {key}",
        isinstance(inv.get("reason"), str) and bool(inv.get("reason")),
        "missing reason",
    )
    if inv.get("originalLabel") == "ubuntu-latest":
        assert_true(
            f"previous ubuntu-latest is pinned to ubuntu-24.04 for {key}",
            inv.get("pinnedLabel") == "ubuntu-24.04" and inv.get("runsOn") == "ubuntu-24.04",
            f"expected pinnedLabel/runsOn ubuntu-24.04, got pinnedLabel={inv.get('pinnedLabel')!r} runsOn={inv.get('runsOn')!r}",
        )
        assert_true(
            f"previous ubuntu-latest entry is marked pinned for {key}",
            inv.get("status") == "pinned",
            f"expected status=pinned, got {inv.get('status')!r}",
        )
    if inv.get("classification") == "matrix_expression":
        assert_true(
            f"matrix runner label is explicitly classified for {key}",
            inv.get("status") in {"classified", "skipped", "pinned"},
            f"unexpected matrix status {inv.get('status')!r}",
        )

# If a mutable label is intentionally skipped in the future, it must be tracked
# in both skipped and mutableLatestAllowlist with a reason.
for skipped in skipped_entries:
    reason = skipped.get("reason")
    assert_true(
        f"skipped runner has reason for {(skipped.get('file'), skipped.get('occurrence'))}",
        isinstance(reason, str) and bool(reason),
        "skipped entries require a reason",
    )

root_template_dir = repo_root / "lib" / "templates"
platform_template_dir = repo_root / "platforms" / "claude-code" / "lib" / "templates"
if root_template_dir.exists() and platform_template_dir.exists():
    mirrored = []
    for root_file in sorted(root_template_dir.rglob("*")):
        if not root_file.is_file() or root_file.suffix not in {".yml", ".yaml"}:
            continue
        rel = root_file.relative_to(root_template_dir)
        platform_file = platform_template_dir / rel
        if platform_file.exists():
            mirrored.append(rel.as_posix())
            assert_true(
                f"Claude platform workflow template mirrors root template {rel.as_posix()}",
                root_file.read_text(encoding="utf-8") == platform_file.read_text(encoding="utf-8"),
                f"template differs: {rel.as_posix()}",
            )
    assert_true("at least one mirrored workflow template was checked", bool(mirrored), "no mirrored workflow templates found")
else:
    ok("Claude platform workflow template parity skipped when mirror directory is absent")

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
