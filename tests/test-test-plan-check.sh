#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

COMPLETE="$ROOT_DIR/tests/fixtures/test-plan/cli-tooling-complete.json"
INCOMPLETE="$ROOT_DIR/tests/fixtures/test-plan/cli-tooling-incomplete.json"
LOW_RISK="$ROOT_DIR/tests/fixtures/test-plan/low-risk-incomplete.json"
UNKNOWN="$ROOT_DIR/tests/fixtures/test-plan/unknown-change-type.json"

COMPLETE_STDOUT="$WORK/complete.stdout.json"
COMPLETE_REPORT="$WORK/complete.report.json"
INCOMPLETE_REPORT="$WORK/incomplete.json"
LOW_RISK_REPORT="$WORK/low-risk.json"
UNKNOWN_REPORT="$WORK/unknown.json"

python3 "$ROOT_DIR/scripts/check_test_plan.py" "$COMPLETE" \
  --json-output "$COMPLETE_REPORT" \
  > "$COMPLETE_STDOUT"

if python3 "$ROOT_DIR/scripts/check_test_plan.py" "$INCOMPLETE" > "$INCOMPLETE_REPORT"; then
  echo "expected incomplete medium-risk plan to fail hard gate" >&2
  exit 1
fi

python3 "$ROOT_DIR/scripts/check_test_plan.py" "$LOW_RISK" > "$LOW_RISK_REPORT"

if python3 "$ROOT_DIR/scripts/check_test_plan.py" "$UNKNOWN" > "$UNKNOWN_REPORT"; then
  echo "expected unknown changeType to fail" >&2
  exit 1
fi

python3 - "$COMPLETE_STDOUT" "$COMPLETE_REPORT" "$INCOMPLETE_REPORT" "$LOW_RISK_REPORT" "$UNKNOWN_REPORT" <<'PY'
import json
import sys
from pathlib import Path

complete_stdout = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
complete_report = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
incomplete = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
low_risk = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
unknown = json.loads(Path(sys.argv[5]).read_text(encoding="utf-8"))

if complete_stdout != complete_report:
    raise SystemExit("stdout JSON and --json-output report differ")

required_fields = {
    "status",
    "changeType",
    "riskLevel",
    "requiredCoverageClasses",
    "coveredCoverageClasses",
    "missingCoverageClasses",
    "hardGatePassed",
    "violations",
}
for label, report in {
    "complete": complete_report,
    "incomplete": incomplete,
    "low_risk": low_risk,
    "unknown": unknown,
}.items():
    missing = sorted(required_fields - set(report))
    if missing:
        raise SystemExit(f"{label} report missing fields: {missing}")

if complete_report["status"] != "ok" or not complete_report["hardGatePassed"]:
    raise SystemExit(f"complete plan should pass: {complete_report}")
if complete_report["missingCoverageClasses"]:
    raise SystemExit(f"complete plan should have no missing classes: {complete_report}")

if incomplete["hardGatePassed"]:
    raise SystemExit("incomplete medium-risk plan should fail hard gate")
if "coverage.missing_required_adversarial_classes" not in incomplete["violations"]:
    raise SystemExit(f"incomplete report missing adversarial coverage violation: {incomplete}")
for expected in ("idempotency", "path_handling", "config_source_of_truth", "generated_output_isolation"):
    if expected not in incomplete["missingCoverageClasses"]:
        raise SystemExit(f"incomplete report missing class {expected}")

if not low_risk["hardGatePassed"]:
    raise SystemExit(f"low-risk incomplete plan should warn, not fail: {low_risk}")
if "coverage.missing_required_adversarial_classes" not in low_risk.get("warnings", []):
    raise SystemExit(f"low-risk incomplete plan should warn: {low_risk}")

if unknown["hardGatePassed"]:
    raise SystemExit("unknown changeType should fail hard gate")
if "change_type.unknown" not in unknown["violations"]:
    raise SystemExit(f"unknown report missing change_type.unknown: {unknown}")

blob = Path(sys.argv[2]).read_text(encoding="utf-8")
for forbidden in ("/Users/", "/private/", "/var/folders/", "/tmp/"):
    if forbidden in blob:
        raise SystemExit(f"report leaks absolute path marker: {forbidden}")
PY

echo "test-plan checker smoke passed"
