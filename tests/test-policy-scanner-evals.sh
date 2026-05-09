#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPORT="$WORK/policy-scanner-eval.json"
STDOUT_JSON="$WORK/stdout.json"

python3 "$ROOT_DIR/evals/policy_scanner/run_policy_scanner_eval.py" \
  --repo-root "$ROOT_DIR" \
  --json-output "$REPORT" \
  > "$STDOUT_JSON"

python3 - "$REPORT" "$STDOUT_JSON" <<'PY'
import json
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
stdout_path = Path(sys.argv[2])

report = json.loads(report_path.read_text(encoding="utf-8"))
stdout_report = json.loads(stdout_path.read_text(encoding="utf-8"))
if report != stdout_report:
    raise SystemExit("stdout JSON and --json-output report differ")

summary = report.get("summary")
if not isinstance(summary, dict):
    raise SystemExit("summary must be an object")

required_metrics = {
    "fixtureCount",
    "passed",
    "failed",
    "truePositives",
    "falsePositives",
    "falseNegatives",
    "precision",
    "recall",
    "f1",
    "criticalRecall",
    "criticalFalseNegatives",
    "severityMismatches",
    "unexpectedCriticalFindings",
    "runtimeMsP50",
    "runtimeMsP95",
    "determinismScore",
}
missing = sorted(required_metrics - set(summary))
if missing:
    raise SystemExit(f"missing summary metrics: {missing}")

if summary["fixtureCount"] < 15:
    raise SystemExit(f"expected at least 15 fixtures, got {summary['fixtureCount']}")
if summary["fixtureCount"] <= 0:
    raise SystemExit("fixtureCount must be positive")
if "determinismScore" not in summary:
    raise SystemExit("determinismScore missing")
if summary["determinismScore"] != 1.0:
    raise SystemExit(f"determinismScore must be 1.0, got {summary['determinismScore']}")
if not summary.get("hardGatePassed"):
    raise SystemExit(f"hard gates failed: {summary.get('hardGateFailures')}")
if report.get("repeat", 0) < 2:
    raise SystemExit("default repeat must be at least 2")

blob = report_path.read_text(encoding="utf-8")
for forbidden in ("signum-policy-scanner-eval-", "/private/", "/var/folders/", "/tmp/"):
    if forbidden in blob:
        raise SystemExit(f"report leaks temp path marker: {forbidden}")
PY
