#!/usr/bin/env bash
# test-signum-command-structure.sh -- guard Signum command structure before decomposition
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
fixture_path = repo_root / "tests" / "fixtures" / "signum-command-structure.json"
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


def read_rel(rel):
    return (repo_root / rel).read_text(encoding="utf-8")


assert_true("command structure fixture exists", fixture_path.exists(), f"missing {fixture_path}")
if not fixture_path.exists():
    sys.exit(1)

fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
commands = fixture["commands"]
texts = {}
for label, rel in commands.items():
    path = repo_root / rel
    assert_true(f"{label} command exists", path.exists(), f"missing {rel}")
    texts[label] = path.read_text(encoding="utf-8") if path.exists() else ""

# Required markers in both command files.
for group, markers in fixture["requiredInBoth"].items():
    for label, text in texts.items():
        missing = [marker for marker in markers if marker not in text]
        assert_true(
            f"{label} has required {group} markers",
            not missing,
            f"missing {missing}",
        )

# Phase headings must match the expected normalized phase list and stay ordered.
phase_re = re.compile(r"^## Phase \d+: [A-Z]+", re.MULTILINE)
for label, expected in fixture["expectedPhases"].items():
    found = phase_re.findall(texts[label])
    assert_true(
        f"{label} phase list matches expected structure",
        found == expected,
        f"expected {expected}, found {found}",
    )
    positions = [texts[label].find(marker) for marker in expected]
    assert_true(
        f"{label} phase marker order is monotonic",
        all(pos >= 0 for pos in positions) and positions == sorted(positions),
        f"positions {positions}",
    )

root_shared = fixture["expectedPhases"]["root"]
overlay_shared = fixture["expectedPhases"]["claude_overlay"][: len(root_shared)]
assert_true(
    "root and overlay share CONTRACT->EXECUTE->AUDIT->PACK phase markers",
    root_shared == overlay_shared,
    f"root {root_shared}, overlay {overlay_shared}",
)

# Root-only and overlay-only differences are explicit and documented.
root_text = texts["root"]
overlay_text = texts["claude_overlay"]
for group, markers in fixture["requiredRootOnly"].items():
    command_markers = [marker for marker in markers if marker != "legacy-final-output-cleanup"]
    missing = [marker for marker in command_markers if marker not in root_text]
    unexpected = [marker for marker in command_markers if marker in overlay_text]
    assert_true(f"root has root-only {group} markers", not missing, f"missing {missing}")
    assert_true(f"overlay omits root-only {group} markers", not unexpected, f"unexpected {unexpected}")

for group, markers in fixture["requiredOverlayOnly"].items():
    command_markers = [marker for marker in markers if marker != "docs/overlay-deviations.json"]
    missing = [marker for marker in command_markers if marker not in overlay_text]
    unexpected = [marker for marker in command_markers if marker in root_text]
    assert_true(f"overlay has overlay-only {group} markers", not missing, f"missing {missing}")
    assert_true(f"root omits overlay-only {group} markers", not unexpected, f"unexpected {unexpected}")

# Forbidden patterns should stay out of command runtime files.
for group, markers in fixture["forbiddenInBoth"].items():
    for label, text in texts.items():
        present = [marker for marker in markers if marker in text]
        assert_true(f"{label} has no forbidden {group} markers", not present, f"present {present}")

# Bounded Final Output legacy cleanup exception.
def final_output_block(text):
    start = text.find("## Final Output")
    if start < 0:
        return ""
    end = text.find("## Error Handling", start)
    return text[start:] if end < 0 else text[start:end]

for rel, expected_count in fixture["expectedCounts"]["finalOutputPurgeRootWorkingSetViews"].items():
    label = next((name for name, path in commands.items() if path == rel), rel)
    count = final_output_block(texts[label]).count("purge_root_working_set_views")
    assert_true(
        f"{label} Final Output purge_root_working_set_views count is bounded",
        count == expected_count,
        f"expected {expected_count}, found {count}",
    )

# Documentation must record the baseline and known differences.
doc_rel = fixture["documentation"]["path"]
doc_path = repo_root / doc_rel
assert_true("command structure inventory doc exists", doc_path.exists(), f"missing {doc_rel}")
doc_text = doc_path.read_text(encoding="utf-8") if doc_path.exists() else ""
for marker in fixture["documentation"]["requiredMarkers"]:
    assert_true(f"inventory doc mentions {marker}", marker in doc_text, f"missing {marker}")
assert_true(
    "overlay deviations file records RECONCILE extra phase",
    "RECONCILE" in read_rel("docs/overlay-deviations.json"),
    "missing RECONCILE in docs/overlay-deviations.json",
)

print("")
print(f"Passed: {passed}")
print(f"Failed: {failed}")
if failed:
    print("FAILED")
    sys.exit(1)
print("ALL PASSED")
PY
