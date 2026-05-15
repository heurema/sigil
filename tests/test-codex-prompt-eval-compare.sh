#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CANDIDATE="$WORK/codex-candidate.json"
COMPARE="$WORK/codex-compare.json"

python3 "$ROOT_DIR/evals/codex_prompt/run_codex_prompt_eval.py" \
  --json-output "$CANDIDATE" \
  > "$WORK/codex-stdout.json"

python3 "$ROOT_DIR/evals/codex_prompt/compare_codex_prompt_eval.py" \
  --baseline "$ROOT_DIR/evals/codex_prompt/baselines/current.json" \
  --candidate "$CANDIDATE" \
  > "$COMPARE"

python3 - "$CANDIDATE" "$COMPARE" <<'PY'
import json
import sys
from pathlib import Path

candidate = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
report = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

summary = candidate.get("summary", {})
for key in (
    "detectedFalseAutoOkCount",
    "expectedFalseAutoOkCount",
    "unexpectedFalseAutoOkCount",
):
    if key not in summary:
        raise SystemExit(f"candidate summary missing {key}")

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
if report["harnessName"] != "codex_prompt":
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
    "agentReviewCoverageFailures",
    "invariantPassRate",
    "unexpectedFalseAutoOkCount",
    "approvalGateFailures",
    "artifactRootFailures",
    "auditDecisionFailures",
    "externalReviewDegradationFailures",
    "proofpackConsistencyFailures",
    "scopePolicyFailures",
    "testPlanFailures",
):
    if key not in deltas:
        raise SystemExit(f"missing delta metric: {key}")
PY
