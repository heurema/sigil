#!/usr/bin/env bash
# test-artifact-path-inventory.sh -- guard classified root .signum usages
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
allowlist_path = repo_root / "tests" / "fixtures" / "artifact-path-allowlist.txt"
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


def live_files():
    files = [
        repo_root / "commands" / "signum.md",
        repo_root / "platforms" / "claude-code" / "commands" / "signum.md",
        repo_root / "README.md",
        repo_root / "docs" / "how-it-works.md",
        repo_root / "platforms" / "claude-code" / "docs" / "how-it-works.md",
    ]
    files.extend(sorted((repo_root / "lib").glob("*.sh")))
    files.extend(sorted((repo_root / "scripts").glob("*.py")))
    overlay_lib = repo_root / "platforms" / "claude-code" / "lib"
    if overlay_lib.exists():
        files.extend(sorted(overlay_lib.glob("*.sh")))
    overlay_scripts = repo_root / "platforms" / "claude-code" / "scripts"
    if overlay_scripts.exists():
        files.extend(sorted(overlay_scripts.glob("*.py")))

    seen = []
    for path in files:
        if path.exists() and path not in seen:
            seen.append(path)
    return seen


EXPLICIT_ROOT_RE = re.compile(r"\.signum/[A-Za-z0-9_.*-][A-Za-z0-9_./*-]*")
ARTIFACT_ROOT_FALLBACK = 'ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"'
DYNAMIC_ROOT_PATTERNS = (".signum/${rel}", ".signum/$rel")
IGNORED_PREFIXES = (
    ".signum/contracts",
    ".signum/archive",
    ".signum/archive-tmp",
)
ALLOWED_CATEGORIES = {
    "ci-legacy-fallback",
    "docs-legacy-note",
    "legacy-artifact-root-fallback",
    "legacy-compat-helper",
    "legacy-import",
    "legacy-proofpack-index-fallback",
    "legacy-restart-cleanup",
    "legacy-resume-restart",
    "legacy-scan-fallback",
    "project-bootstrap-input",
    "project-derived-cache",
    "project-metrics",
    "project-policy",
    "project-proofpack-index",
    "project-session",
    "scanner-exclusion",
}


def rel(path):
    return path.relative_to(repo_root).as_posix()


def scan_file(path):
    counts = Counter()
    lines = defaultdict(list)
    text = path.read_text(encoding="utf-8", errors="ignore")
    for line_number, line in enumerate(text.splitlines(), 1):
        if ARTIFACT_ROOT_FALLBACK in line:
            counts[ARTIFACT_ROOT_FALLBACK] += 1
            lines[ARTIFACT_ROOT_FALLBACK].append(line_number)

        masked = line
        for pattern in DYNAMIC_ROOT_PATTERNS:
            count = line.count(pattern)
            if count:
                counts[pattern] += count
                lines[pattern].extend([line_number] * count)
                masked = masked.replace(pattern, "")

        for match in EXPLICIT_ROOT_RE.finditer(masked):
            token = match.group(0).rstrip(".,:;")
            if token in {".signum", ".signum/", ".signum/$"}:
                continue
            if token.startswith(IGNORED_PREFIXES):
                continue
            counts[token] += 1
            lines[token].append(line_number)
    return counts, lines


def scan_live_root_usages():
    counts = Counter()
    lines = defaultdict(list)
    for path in live_files():
        file_counts, file_lines = scan_file(path)
        for pattern, count in file_counts.items():
            key = (rel(path), pattern)
            counts[key] += count
            lines[key].extend(file_lines[pattern])
    return counts, lines


def load_allowlist():
    entries = {}
    malformed = []
    duplicate = []
    if not allowlist_path.exists():
        return entries, [f"missing {allowlist_path}"], duplicate

    for line_number, raw in enumerate(allowlist_path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|", 3)
        if len(parts) != 4:
            malformed.append(f"line {line_number}: expected 4 pipe-separated fields")
            continue
        category, file_path, expected_count, pattern = parts
        if category not in ALLOWED_CATEGORIES:
            malformed.append(f"line {line_number}: unknown category {category!r}")
        if file_path.startswith("/") or ".." in Path(file_path).parts:
            malformed.append(f"line {line_number}: file path must be repo-relative")
        if pattern in {".signum", ".signum/"}:
            malformed.append(f"line {line_number}: pattern is too broad")
        try:
            expected = int(expected_count)
        except ValueError:
            malformed.append(f"line {line_number}: expected_count is not an integer")
            continue
        if expected < 1:
            malformed.append(f"line {line_number}: expected_count must be positive")
        key = (file_path, pattern)
        if key in entries:
            duplicate.append(f"line {line_number}: duplicate allowlist key {key}")
        entries[key] = {"category": category, "expected": expected, "line": line_number}
    return entries, malformed, duplicate


found, found_lines = scan_live_root_usages()
allowed, malformed, duplicate = load_allowlist()

assert_true("allowlist exists", allowlist_path.exists(), f"missing {allowlist_path}")
assert_true("allowlist has no malformed entries", not malformed, "\n".join(malformed))
assert_true("allowlist has no duplicate keys", not duplicate, "\n".join(duplicate))

unknown = sorted(set(found) - set(allowed))
stale = sorted(set(allowed) - set(found))
count_mismatches = []
for key, meta in sorted(allowed.items()):
    if key in found and found[key] != meta["expected"]:
        count_mismatches.append((key, meta["expected"], found[key], found_lines[key]))

assert_true(
    "no unclassified live root .signum usages",
    not unknown,
    "\n".join(f"{file}: {pattern} lines={found_lines[(file, pattern)]}" for file, pattern in unknown),
)
assert_true(
    "allowlist entries still match live usages",
    not stale,
    "\n".join(f"{file}: {pattern}" for file, pattern in stale),
)
assert_true(
    "allowlist counts match live usages",
    not count_mismatches,
    "\n".join(
        f"{file}: {pattern} expected={expected} actual={actual} lines={lines}"
        for (file, pattern), expected, actual, lines in count_mismatches
    ),
)

# Inventory doc checks.
doc_text = inventory_doc.read_text(encoding="utf-8") if inventory_doc.exists() else ""
assert_true("inventory doc exists", inventory_doc.exists(), f"missing {inventory_doc}")
assert_true("inventory doc defines canonical artifact root", ".signum/contracts/<contractId>/" in doc_text, "missing canonical root")
assert_true("inventory doc marks root artifacts as legacy migration inputs", "legacy migration" in doc_text, "missing legacy migration wording")
assert_true("inventory doc mentions contract-dir legacy helpers", "lib/contract-dir.sh" in doc_text and ".signum/${rel}" in doc_text, "missing contract-dir helper inventory")
assert_true("inventory doc mentions command cleanup/import", "commands/signum.md" in doc_text and ".signum/policy_scan.json" in doc_text, "missing command inventory")
assert_true("inventory doc separates project-level state", "project-level" in doc_text and ".signum/proofpack-index.jsonl" in doc_text, "missing project-level state classification")
assert_true("inventory doc notes historical references ignored", "docs/plans/" in doc_text and "synthetic fixtures" in doc_text, "missing historical ignore note")

# Root/overlay command cleanup should not drift for classified legacy policy artifacts.
root_policy_scan = found.get(("commands/signum.md", ".signum/policy_scan.json"), 0)
overlay_policy_scan = found.get(("platforms/claude-code/commands/signum.md", ".signum/policy_scan.json"), 0)
root_policy_violations = found.get(("commands/signum.md", ".signum/policy_violations.json"), 0)
overlay_policy_violations = found.get(("platforms/claude-code/commands/signum.md", ".signum/policy_violations.json"), 0)
assert_true(
    "root and Claude overlay cleanup both include policy scan artifacts",
    root_policy_scan == 1
    and overlay_policy_scan == 1
    and root_policy_violations == 1
    and overlay_policy_violations == 1,
    (
        f"policy_scan root={root_policy_scan} overlay={overlay_policy_scan}; "
        f"policy_violations root={root_policy_violations} overlay={overlay_policy_violations}"
    ),
)

# Root/overlay consistency checks for the high-risk runtime helper.
root_contract_dir = repo_root / "lib" / "contract-dir.sh"
overlay_contract_dir = repo_root / "platforms" / "claude-code" / "lib" / "contract-dir.sh"
if overlay_contract_dir.exists():
    assert_true(
        "root and Claude overlay contract-dir.sh match",
        root_contract_dir.read_text(encoding="utf-8") == overlay_contract_dir.read_text(encoding="utf-8"),
        "contract-dir mirror drift detected",
    )
    root_counts, _ = scan_file(root_contract_dir)
    overlay_counts, _ = scan_file(overlay_contract_dir)
    assert_true(
        "root and Claude overlay contract-dir root usage inventory matches",
        root_counts == overlay_counts,
        f"root={dict(root_counts)} overlay={dict(overlay_counts)}",
    )

print("")
print(f"Classified live root .signum usage keys: {len(found)}")
print(f"Classified live root .signum usage occurrences: {sum(found.values())}")
print(f"Passed: {passed}")
print(f"Failed: {failed}")

if failed:
    print("FAILED")
    sys.exit(1)

print("ALL PASSED")
PY
