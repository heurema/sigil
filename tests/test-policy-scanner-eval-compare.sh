#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CANDIDATE="$WORK/policy-candidate.json"
COMPARE="$WORK/policy-compare.json"

python3 "$ROOT_DIR/evals/policy_scanner/run_policy_scanner_eval.py" \
  --repo-root "$ROOT_DIR" \
  --json-output "$CANDIDATE" \
  > "$WORK/policy-stdout.json"

python3 "$ROOT_DIR/evals/policy_scanner/compare_policy_scanner_eval.py" \
  --baseline "$ROOT_DIR/evals/policy_scanner/baselines/current.json" \
  --candidate "$CANDIDATE" \
  > "$COMPARE"

python3 - "$COMPARE" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

required = {
    "schemaVersion",
    "harnessName",
    "status",
    "decision",
    "hardGatePassed",
    "deltas",
    "regressions",
    "improvements",
}
missing = sorted(required - set(report))
if missing:
    raise SystemExit(f"missing comparison fields: {missing}")
if report["harnessName"] != "policy_scanner":
    raise SystemExit(f"unexpected harnessName: {report['harnessName']}")
if report["status"] not in {"equivalent", "accept", "better"}:
    raise SystemExit(f"current candidate should not regress: {report['status']}")
if report["decision"] == "reject":
    raise SystemExit("current candidate comparison rejected")
if not report["hardGatePassed"]:
    raise SystemExit(f"hard gates failed: {report.get('hardGateFailures')}")
if report["regressions"]:
    raise SystemExit(f"expected no regressions, got {report['regressions']}")

deltas = report.get("deltas")
if not isinstance(deltas, dict):
    raise SystemExit("deltas must be an object")
for key in (
    "precision",
    "recall",
    "f1",
    "criticalFalseNegatives",
    "falsePositives",
    "runtimeMsP95",
    "determinismScore",
):
    if key not in deltas:
        raise SystemExit(f"missing delta metric: {key}")
PY

SLOW_CANDIDATE="$WORK/policy-candidate-slow-runtime.json"
SLOW_COMPARE="$WORK/policy-compare-slow-runtime.json"
jq '.summary.runtimeMsP95 = (.summary.runtimeMsP95 * 10)' "$CANDIDATE" > "$SLOW_CANDIDATE"

python3 "$ROOT_DIR/evals/policy_scanner/compare_policy_scanner_eval.py" \
  --baseline "$ROOT_DIR/evals/policy_scanner/baselines/current.json" \
  --candidate "$SLOW_CANDIDATE" \
  > "$SLOW_COMPARE"

python3 - "$SLOW_COMPARE" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
runtime_regressions = [item for item in report.get("regressions", []) if item.get("metric") == "runtimeMsP95"]
if runtime_regressions:
    raise SystemExit(f"runtime delta should not create regressions: {runtime_regressions}")
if report["status"] == "worse":
    raise SystemExit("runtime-only delta should not make candidate worse")
if "runtimeMsP95" not in report.get("deltas", {}):
    raise SystemExit("runtime delta should remain visible in deltas")
PY
