#!/usr/bin/env bash
# test-signum-fragment-parity.sh -- classify root/overlay Signum command fragments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
fixture_path = repo_root / "tests" / "fixtures" / "signum-fragment-parity.json"
doc_path = repo_root / "docs" / "signum-fragment-parity.md"
renderer = repo_root / "scripts" / "render_signum_command.py"
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


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        bad(f"load {path.relative_to(repo_root)}", str(exc))
        return None


def logical_name(fragment_path):
    name = Path(fragment_path).name
    if not name.endswith(".md"):
        return None
    stem = name[:-3]
    return re.sub(r"^\d+-", "", stem)


def normalize_entry(entry):
    if isinstance(entry, str):
        return {"scope": "manifest", "path": entry}
    if isinstance(entry, dict) and isinstance(entry.get("path"), str):
        return {"scope": entry.get("scope", "manifest"), "path": entry["path"]}
    return None


def ref_file(manifest_path, ref):
    base = repo_root if ref["scope"] == "repo" else manifest_path.parent
    return base / ref["path"]


def ref_key(ref):
    return f"{ref['scope']}:{ref['path']}"


def expected_ref(value):
    if value is None:
        return None
    if isinstance(value, dict) and isinstance(value.get("path"), str):
        return {"scope": value.get("scope", "manifest"), "path": value["path"]}
    return None


def manifest_fragments(manifest_rel):
    manifest_path = repo_root / manifest_rel
    assert_true(f"manifest exists: {manifest_rel}", manifest_path.exists(), f"missing {manifest_rel}")
    data = load_json(manifest_path) if manifest_path.exists() else None
    if not isinstance(data, dict):
        return manifest_path, {}, []
    fragments = data.get("fragments")
    assert_true(f"manifest has explicit fragments: {manifest_rel}", isinstance(fragments, list) and bool(fragments), "missing/non-empty fragments array")
    seen_logical = {}
    seen_refs = set()
    errors = []
    for entry in fragments or []:
        ref = normalize_entry(entry)
        if ref is None:
            errors.append(f"invalid entry {entry!r}")
            continue
        if ref["scope"] not in {"manifest", "repo"}:
            errors.append(f"invalid scope {ref['scope']!r} for {ref['path']!r}")
            continue
        logical = logical_name(ref["path"])
        if not logical:
            errors.append(f"cannot derive logical name from {ref['path']!r}")
            continue
        if logical in seen_logical:
            errors.append(f"duplicate logical fragment {logical!r}")
        key = ref_key(ref)
        if key in seen_refs:
            errors.append(f"duplicate fragment reference {key}")
        seen_refs.add(key)
        path = ref_file(manifest_path, ref)
        if not path.exists():
            errors.append(f"missing fragment {key}")
        seen_logical[logical] = {"ref": ref, "path": path, "key": key}
    assert_true(f"manifest fragments are present: {manifest_rel}", not errors, "; ".join(errors))
    return manifest_path, seen_logical, fragments or []


assert_true("fragment parity fixture exists", fixture_path.exists(), f"missing {fixture_path}")
fixture = load_json(fixture_path) if fixture_path.exists() else None
if not isinstance(fixture, dict):
    sys.exit(1)

assert_true("fragment parity fixture version is 1", fixture.get("version") == 1, f"found {fixture.get('version')!r}")
root_manifest_rel = fixture.get("rootManifest")
overlay_manifest_rel = fixture.get("overlayManifest")
assert_true("fixture has root manifest path", isinstance(root_manifest_rel, str) and root_manifest_rel, "missing rootManifest")
assert_true("fixture has overlay manifest path", isinstance(overlay_manifest_rel, str) and overlay_manifest_rel, "missing overlayManifest")

root_manifest_path, root_map, root_entries = manifest_fragments(root_manifest_rel) if isinstance(root_manifest_rel, str) else (None, {}, [])
overlay_manifest_path, overlay_map, overlay_entries = manifest_fragments(overlay_manifest_rel) if isinstance(overlay_manifest_rel, str) else (None, {}, [])

reason_ids = fixture.get("reasonIds", {})
assert_true("reasonIds map is non-empty", isinstance(reason_ids, dict) and bool(reason_ids), "missing reasonIds")
shared_root = fixture.get("sharedFragmentRoot")
assert_true("fixture records shared fragment root", isinstance(shared_root, str) and shared_root == "commands/signum.shared.fragments", f"found {shared_root!r}")

fragments = fixture.get("fragments")
assert_true("fixture has fragment entries", isinstance(fragments, list) and bool(fragments), "missing fragments array")
fixture_by_logical = {}
fixture_errors = []
for item in fragments or []:
    if not isinstance(item, dict):
        fixture_errors.append(f"non-object fragment entry {item!r}")
        continue
    logical = item.get("logicalName")
    if not isinstance(logical, str) or not logical:
        fixture_errors.append(f"missing logicalName in {item!r}")
        continue
    if logical in fixture_by_logical:
        fixture_errors.append(f"duplicate fixture logicalName {logical}")
    fixture_by_logical[logical] = item
assert_true("fixture logical names are unique", not fixture_errors, "; ".join(fixture_errors))

actual_logical = set(root_map) | set(overlay_map)
fixture_logical = set(fixture_by_logical)
assert_true("fixture classifies every actual logical fragment", actual_logical == fixture_logical, f"actual={sorted(actual_logical)} fixture={sorted(fixture_logical)}")

allowed_classes = {"shared-source", "divergent-bounded", "root-only", "overlay-only"}
counts = {name: 0 for name in allowed_classes}
unknown = []
used_reasons = set()
shared_logical = set()

for logical in sorted(fixture_logical):
    item = fixture_by_logical[logical]
    classification = item.get("classification")
    if classification not in allowed_classes:
        unknown.append(logical)
        bad(f"{logical} has known classification", f"unknown classification {classification!r}")
        continue
    counts[classification] += 1

    root_expected = expected_ref(item.get("root"))
    overlay_expected = expected_ref(item.get("overlay"))
    root_actual = root_map.get(logical)
    overlay_actual = overlay_map.get(logical)

    if root_expected is None:
        assert_true(f"{logical} has no root fragment as expected", root_actual is None, f"actual root {root_actual}")
    else:
        assert_true(f"{logical} root fragment ref matches fixture", root_actual is not None and root_actual["ref"] == root_expected, f"expected {root_expected!r}, found {root_actual}")
    if overlay_expected is None:
        assert_true(f"{logical} has no overlay fragment as expected", overlay_actual is None, f"actual overlay {overlay_actual}")
    else:
        assert_true(f"{logical} overlay fragment ref matches fixture", overlay_actual is not None and overlay_actual["ref"] == overlay_expected, f"expected {overlay_expected!r}, found {overlay_actual}")

    reasons = item.get("reasons", [])
    if classification == "shared-source":
        shared_logical.add(logical)
        assert_true(f"{logical} has no difference reasons", reasons == [], f"unexpected reasons {reasons}")
        shared = item.get("shared")
        assert_true(f"{logical} records shared source path", isinstance(shared, str) and shared.startswith("commands/signum.shared.fragments/"), f"shared={shared!r}")
        if root_actual and overlay_actual and isinstance(shared, str):
            same_ref = root_actual["ref"] == overlay_actual["ref"] == {"scope": "repo", "path": shared}
            assert_true(f"{logical} root and overlay point at same shared source", same_ref, f"root={root_actual['ref']} overlay={overlay_actual['ref']} shared={shared}")
            assert_true(f"{logical} shared source exists", (repo_root / shared).exists(), f"missing {shared}")
        else:
            bad(f"{logical} shared source is referenced by both manifests", "missing root or overlay fragment")
    else:
        assert_true(f"{logical} has bounded reason IDs", isinstance(reasons, list) and bool(reasons), f"missing reasons for {classification}")
        for reason in reasons if isinstance(reasons, list) else []:
            assert_true(f"{logical} reason ID is known: {reason}", reason in reason_ids, f"unknown reason {reason}")
            used_reasons.add(reason)

    if classification == "divergent-bounded":
        if root_actual and overlay_actual:
            separate = root_actual["path"].resolve() != overlay_actual["path"].resolve()
            assert_true(f"{logical} divergent fragments stay separate", separate, f"both point at {root_actual['path']}")
            same = root_actual["path"].read_bytes() == overlay_actual["path"].read_bytes()
            assert_true(f"{logical} divergent fragment is actually different", not same, "content is byte-identical; reclassify as shared-source")
        else:
            bad(f"{logical} divergent fragment exists on both sides", "missing root or overlay fragment")
    elif classification == "root-only":
        assert_true(f"{logical} is root-only", root_actual is not None and overlay_actual is None, f"root={root_actual} overlay={overlay_actual}")
    elif classification == "overlay-only":
        assert_true(f"{logical} is overlay-only", root_actual is None and overlay_actual is not None, f"root={root_actual} overlay={overlay_actual}")

# Shared-source extraction should remove stale local duplicate fragments with the same logical names.
for label, manifest_path in [("root", root_manifest_path), ("overlay", overlay_manifest_path)]:
    if manifest_path is None:
        continue
    stale = []
    for path in manifest_path.parent.glob("*.md"):
        logical = logical_name(path.name)
        if logical in shared_logical:
            stale.append(path.name)
    assert_true(f"{label} has no stale local duplicate shared fragments", not stale, f"stale duplicates {stale}")

assert_true("no unknown fragment classifications", not unknown, f"unknown={unknown}")
assert_true("root-only count matches baseline", counts["root-only"] == 0, f"found {counts['root-only']}")
assert_true("overlay-only count matches baseline", counts["overlay-only"] == 1, f"found {counts['overlay-only']}")
assert_true("shared-source count matches baseline", counts["shared-source"] == 5, f"found {counts['shared-source']}")
assert_true("divergent-bounded count matches baseline", counts["divergent-bounded"] == 8, f"found {counts['divergent-bounded']}")
assert_true("reasonIds map has no stale entries", set(reason_ids) == used_reasons, f"catalog={sorted(reason_ids)} used={sorted(used_reasons)}")

assert_true("fragment parity doc exists", doc_path.exists(), f"missing {doc_path.relative_to(repo_root)}")
doc_text = doc_path.read_text(encoding="utf-8") if doc_path.exists() else ""
for reason in sorted(used_reasons):
    assert_true(f"fragment parity doc mentions reason ID {reason}", reason in doc_text, f"missing {reason}")
for logical in sorted(fixture_logical):
    assert_true(f"fragment parity doc mentions {logical}", logical in doc_text, f"missing {logical}")
assert_true("fragment parity doc explains shared-source", "shared-source" in doc_text, "missing shared-source")

# Renderer checks keep this inventory tied to the byte-for-byte runtime guard.
for label, manifest_rel in [("root", root_manifest_rel), ("overlay", overlay_manifest_rel)]:
    if not isinstance(manifest_rel, str):
        continue
    manifest_path = repo_root / manifest_rel
    manifest = load_json(manifest_path)
    output_rel = manifest.get("source") if isinstance(manifest, dict) else None
    assert_true(f"{label} manifest declares source output", isinstance(output_rel, str) and output_rel, f"missing source in {manifest_rel}")
    if isinstance(output_rel, str) and renderer.exists():
        proc = subprocess.run(
            [sys.executable, str(renderer), "--manifest", str(manifest_path), "--output", str(repo_root / output_rel), "--check"],
            cwd=str(repo_root),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        assert_true(f"{label} fragments render byte-for-byte", proc.returncode == 0, proc.stdout.strip())

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")
if failed:
    print("FAILED")
    sys.exit(1)
print("ALL PASSED")
PY
