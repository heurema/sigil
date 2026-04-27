#!/usr/bin/env bash
# test-stabilization-summary.sh -- static guard for stabilization summary and finding inventory
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
summary_path = repo_root / "docs" / "stabilization-summary.md"
inventory_path = repo_root / "tests" / "fixtures" / "stabilization-findings.json"

required_ids = {
    "version-schema-drift",
    "dsl-exec-timeout",
    "deterministic-pr-ci",
    "unsafe-home-project-scan",
    "claude-cli-floating-install",
    "release-cross-repo-push",
    "root-artifact-legacy-drift",
    "normal-runtime-legacy-helper-calls",
    "proofpack-validation-gap",
    "policy-scanner-unstable-rules",
    "policy-scanner-false-positives",
    "init-harness-heredocs",
    "init-scanner-shell-heavy",
    "signum-command-monolith",
    "platform-overlay-drift",
    "github-actions-mutable-refs",
    "github-runner-latest-labels",
    "optional-removal-evidence",
    "final-output-root-cleanup",
    "full-runner-immutability",
}

allowed_statuses = {"fixed", "bounded", "deferred", "future"}
required_matrix_tests = [
    "tests/test-metadata-consistency.sh",
    "tests/test-dsl-runner.sh",
    "tests/test-ci-workflow.sh",
    "tests/test-project-root-resolution.sh",
    "tests/test-toolchain-pinning.sh",
    "tests/test-release-workflow-hardening.sh",
    "tests/test-cleanroom-smoke.sh",
    "tests/test-artifact-path-inventory.sh",
    "tests/test-legacy-root-helper-callsites.sh",
    "tests/test-proofpack-validation.sh",
    "tests/test-policy-scanner.sh",
    "tests/test-init-harness-scaffold.sh",
    "tests/test-init-scanner.sh",
    "tests/test-signum-command-renderer.sh",
    "tests/test-signum-fragment-parity.sh",
    "tests/test-github-action-pinning.sh",
    "tests/test-github-runner-pinning.sh",
]

errors: list[str] = []

def check(name: str, condition: bool, message: str) -> None:
    if condition:
        print(f"PASS: {name}")
    else:
        print(f"FAIL: {name}: {message}")
        errors.append(f"{name}: {message}")

check("summary doc exists", summary_path.is_file(), f"missing {summary_path.relative_to(repo_root)}")
check("finding inventory exists", inventory_path.is_file(), f"missing {inventory_path.relative_to(repo_root)}")

summary_text = summary_path.read_text(encoding="utf-8") if summary_path.is_file() else ""

try:
    inventory = json.loads(inventory_path.read_text(encoding="utf-8")) if inventory_path.is_file() else None
    check("finding inventory is valid JSON", True, "")
except json.JSONDecodeError as exc:
    inventory = None
    check("finding inventory is valid JSON", False, f"line {exc.lineno} column {exc.colno}: {exc.msg}")

findings = inventory.get("findings") if isinstance(inventory, dict) else None
check("inventory has findings list", isinstance(findings, list), "missing findings array")

seen_ids: set[str] = set()
statuses_seen: set[str] = set()
if isinstance(findings, list):
    for index, finding in enumerate(findings):
        prefix = f"findings[{index}]"
        check(f"{prefix} is object", isinstance(finding, dict), f"found {type(finding).__name__}")
        if not isinstance(finding, dict):
            continue

        fid = finding.get("id")
        status = finding.get("status")
        summary = finding.get("summary")
        evidence = finding.get("evidence")
        remaining = finding.get("remainingRisk")

        check(f"{prefix} has id", isinstance(fid, str) and bool(fid), f"invalid id {fid!r}")
        check(f"{prefix} has status", isinstance(status, str) and bool(status), f"invalid status {status!r}")
        check(f"{prefix} has summary", isinstance(summary, str) and bool(summary), "missing summary")
        check(f"{prefix} has evidence", isinstance(evidence, list) and bool(evidence), "evidence must be non-empty list")
        check(f"{prefix} has remainingRisk", isinstance(remaining, str), "missing remainingRisk string")

        if isinstance(fid, str):
            check(f"{prefix} id is unique", fid not in seen_ids, f"duplicate id {fid}")
            seen_ids.add(fid)
        if isinstance(status, str):
            check(f"{prefix} status is allowed", status in allowed_statuses, f"{status!r} not in {sorted(allowed_statuses)}")
            statuses_seen.add(status)
        if status in {"bounded", "deferred"} and isinstance(fid, str):
            title = finding.get("title")
            mentioned = fid in summary_text or (isinstance(title, str) and title in summary_text)
            check(f"summary mentions bounded/deferred {fid}", mentioned, "missing finding id or title in docs/stabilization-summary.md")

        if isinstance(evidence, list):
            for item_index, rel in enumerate(evidence):
                item_name = f"{prefix}.evidence[{item_index}]"
                check(item_name + " is string", isinstance(rel, str) and bool(rel), f"invalid evidence path {rel!r}")
                if not isinstance(rel, str) or not rel:
                    continue
                check(item_name + " is relative", not Path(rel).is_absolute(), f"absolute path not allowed: {rel}")
                parts = rel.split("/")
                no_traversal = all(p not in ("", ".", "..") for p in parts)
                check(item_name + " has no path traversal", no_traversal, f"path traversal or empty component not allowed: {rel}")
                if not no_traversal:
                    continue
                cur = repo_root
                case_exact = True
                case_detail = ""
                for part in parts:
                    try:
                        listing = os.listdir(cur)
                    except (FileNotFoundError, NotADirectoryError):
                        case_exact = False
                        case_detail = f"parent missing or not a directory: {cur.relative_to(repo_root)}"
                        break
                    if part not in listing:
                        case_exact = False
                        actual = next((x for x in listing if x.lower() == part.lower()), None)
                        if actual is not None:
                            case_detail = f"case mismatch at component {part!r} (actual: {actual!r})"
                        else:
                            case_detail = f"missing component {part!r} under {cur.relative_to(repo_root) if cur != repo_root else '.'}"
                        break
                    cur = cur / part
                check(item_name + " exists case-exact", case_exact, f"missing or wrong-case evidence file: {rel} ({case_detail})")

missing_required = sorted(required_ids - seen_ids)
check("all required finding IDs are present", not missing_required, "missing: " + ", ".join(missing_required))
missing_statuses = sorted(allowed_statuses - statuses_seen)
check("all required statuses are represented", not missing_statuses, "missing statuses: " + ", ".join(missing_statuses))

for rel in required_matrix_tests:
    check(f"guard matrix mentions {rel}", rel in summary_text, f"missing {rel}")
    check(f"guard test exists {rel}", (repo_root / rel).is_file(), f"missing {rel}")

for rel, text in (
    ("docs/stabilization-summary.md", summary_text),
    ("tests/fixtures/stabilization-findings.json", inventory_path.read_text(encoding="utf-8") if inventory_path.is_file() else ""),
):
    check(f"{rel} has no /Users absolute path", "/Users/" not in text, "machine-specific /Users path found")
    overclaim = re.search(r"\b(Signum\s+)?is\s+fully\s+production[- ]certified\b|\b(Signum\s+)?is\s+fully\s+production[- ]ready\b", text, re.IGNORECASE)
    check(f"{rel} has no production certification overclaim", overclaim is None, "overclaims production certification")

forbidden_repo_path = "/" + "/".join(["Users", "vi", "personal", "heurema", "signum"])
tests_dir = repo_root / "tests"
offenders = []
for test_path in sorted(tests_dir.glob("test-*.sh")):
    try:
        body = test_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    if forbidden_repo_path in body:
        offenders.append(test_path.relative_to(repo_root).as_posix())
check(
    "executable shell tests have no hardcoded local repo path",
    not offenders,
    "tests still contain hardcoded local repo path: " + ", ".join(offenders),
)

if errors:
    print(f"Failed: {len(errors)}")
    sys.exit(1)
print("ALL PASSED")
PY
