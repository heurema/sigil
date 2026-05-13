#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPORT="$WORK/codex-prompt-eval.json"
STDOUT_JSON="$WORK/stdout.json"

python3 "$ROOT_DIR/evals/codex_prompt/run_codex_prompt_eval.py" \
  --fixtures-dir "$ROOT_DIR/evals/codex_prompt/fixtures" \
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

required = {
    "fixtureCount",
    "passed",
    "failed",
    "invariantPassRate",
    "falseAutoOkCount",
    "detectedFalseAutoOkCount",
    "expectedFalseAutoOkCount",
    "unexpectedFalseAutoOkCount",
    "detectedViolationCount",
    "expectedViolationCount",
    "unexpectedViolationCount",
    "missingExpectedViolationCount",
    "contractDisciplineFailures",
    "approvalGateFailures",
    "artifactRootFailures",
    "auditDecisionFailures",
    "externalReviewDegradationFailures",
    "proofpackConsistencyFailures",
    "scopePolicyFailures",
    "testPlanFailures",
    "hardGatePassed",
}
missing = sorted(required - set(summary))
if missing:
    raise SystemExit(f"missing summary fields: {missing}")
if summary["fixtureCount"] < 25:
    raise SystemExit(f"expected at least 25 fixtures, got {summary['fixtureCount']}")
if not summary["hardGatePassed"]:
    raise SystemExit(f"hard gates failed: {summary.get('hardGateFailures')}")
if summary["failed"] != 0:
    raise SystemExit(f"expected no runner failures, got {summary['failed']}")

blob = report_path.read_text(encoding="utf-8")
for forbidden in ("/Users/", "/private/", "/var/folders/", "/tmp/"):
    if forbidden in blob:
        raise SystemExit(f"report leaks absolute path marker: {forbidden}")
PY
