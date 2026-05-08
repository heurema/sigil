#!/usr/bin/env bash
# test-github-action-pinning.sh -- static checks for pinned external GitHub Actions refs
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
inventory_path = repo_root / "tests" / "fixtures" / "github-action-pins.json"
scan_roots = [
    Path(".github/workflows"),
    Path("lib/templates"),
    Path("platforms/claude-code/lib/templates"),
]
sha_re = re.compile(r"^[0-9a-f]{40}$")
mutable_ref_re = re.compile(r"^(v[1-7]|main|master|latest)$")
uses_re = re.compile(r"^\s*uses\s*:\s*(['\"]?)([^'\"\s#]+)\1(?:\s*(?:#.*)?)?$")
pinned_comment_re = re.compile(r"^\s*#\s*pinned from\s+([^\s#]+)\s*$")

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


def classify(uses):
    if uses.startswith("./"):
        return "local"
    if uses.startswith("docker://"):
        return "docker"
    if "@" not in uses:
        return "unknown"
    action, ref = uses.rsplit("@", 1)
    if "/.github/workflows/" in action:
        return "reusable_workflow"
    return "external_action"


def yaml_paths_under(root):
    full_root = repo_root / root
    if not full_root.exists():
        return []
    return sorted(
        path.relative_to(repo_root)
        for path in full_root.rglob("*")
        if path.is_file() and path.suffix in {".yml", ".yaml"}
    )


def scan_file(path):
    lines = (repo_root / path).read_text(encoding="utf-8").splitlines()
    entries = []
    occurrence = 0
    for index, line in enumerate(lines):
        match = uses_re.match(line)
        if not match:
            continue
        uses = match.group(2)
        occurrence += 1
        kind = classify(uses)
        entry = {
            "file": path.as_posix(),
            "occurrence": occurrence,
            "line": index + 1,
            "uses": uses,
            "kind": kind,
        }

        if kind in {"external_action", "reusable_workflow"}:
            action, ref = uses.rsplit("@", 1)
            previous_line = lines[index - 1] if index > 0 else ""
            comment_match = pinned_comment_re.match(previous_line)
            original_uses = comment_match.group(1) if comment_match else ""
            original_action = ""
            original_ref = ""
            if "@" in original_uses:
                original_action, original_ref = original_uses.rsplit("@", 1)
            entry.update(
                {
                    "action": action,
                    "ref": ref,
                    "originalUses": original_uses,
                    "originalAction": original_action,
                    "originalRef": original_ref,
                    "pinnedSha": ref if sha_re.fullmatch(ref) else "",
                }
            )
        entries.append(entry)
    return entries


scan_paths = []
for root in scan_roots:
    scan_paths.extend(yaml_paths_under(root))
scan_paths = sorted(dict.fromkeys(scan_paths))

all_yaml_with_uses = []
for path in sorted(repo_root.rglob("*")):
    if not path.is_file() or path.suffix not in {".yml", ".yaml"}:
        continue
    rel = path.relative_to(repo_root)
    if ".git" in rel.parts:
        continue
    if rel.parts and rel.parts[0] == ".signum":
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    if re.search(r"(?m)^\s*uses\s*:", text):
        all_yaml_with_uses.append(rel)

outside_scan = [path.as_posix() for path in all_yaml_with_uses if path not in scan_paths]
assert_true(
    "all YAML files with uses entries are in the action-pin scan roots",
    not outside_scan,
    "missing scan coverage for: " + ", ".join(outside_scan),
)

actual = []
for path in scan_paths:
    actual.extend(scan_file(path))

assert_true("GitHub action pin inventory exists", inventory_path.exists(), f"missing {inventory_path}")
try:
    inventory = json.loads(inventory_path.read_text(encoding="utf-8")) if inventory_path.exists() else {}
except json.JSONDecodeError as exc:
    inventory = {}
    bad("GitHub action pin inventory is valid JSON", str(exc))
else:
    ok("GitHub action pin inventory is valid JSON")

inventory_entries = inventory.get("pins", []) if isinstance(inventory, dict) else []
assert_true("inventory schema version is fixed", inventory.get("schemaVersion") == 1, "expected schemaVersion=1")
assert_true("inventory pins field is a list", isinstance(inventory_entries, list), "expected pins list")

for entry in actual:
    kind = entry["kind"]
    uses = entry["uses"]
    where = f"{entry['file']}:{entry['line']}"
    if kind == "local":
        assert_true(f"local uses allowed unpinned at {where}", uses.startswith("./"), uses)
        continue
    if kind == "docker":
        assert_true(f"docker uses skipped at {where}", uses.startswith("docker://"), uses)
        continue
    if kind == "unknown":
        bad(f"unknown uses form at {where}", uses)
        continue

    ref = entry["ref"]
    action = entry["action"]
    assert_true(
        f"external uses is pinned to full SHA at {where}",
        sha_re.fullmatch(ref) is not None,
        f"{uses} is not pinned to a full 40-character SHA",
    )
    assert_true(
        f"external uses has no bare mutable ref at {where}",
        mutable_ref_re.fullmatch(ref) is None,
        f"mutable ref remains: {uses}",
    )
    assert_true(
        f"pin comment preserves original action at {where}",
        entry["originalAction"] == action,
        f"expected adjacent '# pinned from {action}@<ref>' before {uses}",
    )
    assert_true(
        f"pin comment preserves original mutable ref at {where}",
        bool(entry["originalRef"]) and sha_re.fullmatch(entry["originalRef"]) is None,
        f"missing original mutable ref comment before {uses}",
    )

# Build a compact expected inventory from the scan. This keeps the inventory
# deterministic while allowing notes/resolution details to stay human-friendly.
expected_by_key = {}
for entry in actual:
    key = (entry["file"], entry["occurrence"])
    compact = {
        "file": entry["file"],
        "occurrence": entry["occurrence"],
        "uses": entry["uses"],
        "kind": entry["kind"],
    }
    if entry["kind"] == "local":
        compact.update({"status": "allowed-unpinned"})
    elif entry["kind"] == "docker":
        compact.update({"status": "skipped"})
    elif entry["kind"] == "unknown":
        compact.update({"status": "skipped"})
    else:
        compact.update(
            {
                "status": "pinned" if entry["pinnedSha"] else "mutable-unpinned",
                "action": entry["action"],
                "originalRef": entry["originalRef"],
                "pinnedSha": entry["pinnedSha"],
            }
        )
    expected_by_key[key] = compact

inventory_by_key = {}
for inv in inventory_entries:
    key = (inv.get("file"), inv.get("occurrence"))
    if key in inventory_by_key:
        bad("inventory has duplicate file/occurrence entries", f"duplicate {key}")
    inventory_by_key[key] = inv

missing = [key for key in sorted(expected_by_key) if key not in inventory_by_key]
stale = [key for key in sorted(inventory_by_key) if key not in expected_by_key]
assert_true("inventory has no missing uses entries", not missing, f"missing {missing}")
assert_true("inventory has no stale uses entries", not stale, f"stale {stale}")

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
        f"inventory note exists for {key}",
        isinstance(inv.get("note"), str) and bool(inv.get("note")),
        "missing note",
    )
    if expected.get("status") == "pinned":
        assert_true(
            f"inventory pinned SHA is full length for {key}",
            sha_re.fullmatch(inv.get("pinnedSha", "")) is not None,
            f"invalid pinnedSha={inv.get('pinnedSha')!r}",
        )
        assert_true(
            f"inventory preserves original ref for {key}",
            bool(inv.get("originalRef")) and sha_re.fullmatch(inv.get("originalRef", "")) is None,
            "missing originalRef",
        )

root_template = repo_root / "lib" / "templates" / "signum-gate.yml"
platform_template = repo_root / "platforms" / "claude-code" / "lib" / "templates" / "signum-gate.yml"
if root_template.exists() and platform_template.exists():
    root_pins = [
        (entry.get("action"), entry.get("ref"))
        for entry in scan_file(root_template.relative_to(repo_root))
        if entry["kind"] in {"external_action", "reusable_workflow"}
    ]
    platform_pins = [
        (entry.get("action"), entry.get("ref"))
        for entry in scan_file(platform_template.relative_to(repo_root))
        if entry["kind"] in {"external_action", "reusable_workflow"}
    ]
    assert_true(
        "Claude platform template action pins match root template pins",
        root_pins == platform_pins,
        f"root={root_pins} platform={platform_pins}",
    )
else:
    ok("Claude platform template pin parity skipped when mirror is absent")

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
