#!/usr/bin/env bash
# test-eval-harness.sh -- tests for evals/run.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/../evals/run.py"

passed=0
failed=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_pass() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — exited non-zero: %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_equals() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

echo "=== Harness existence ==="
assert_pass "runner file exists" test -f "$RUNNER"
assert_pass "runner is executable after chmod" chmod +x "$RUNNER"
assert_pass "checks file exists" test -f "$SCRIPT_DIR/../evals/checks.py"
assert_pass "fixtures directory exists" test -d "$SCRIPT_DIR/../evals/fixtures"
assert_pass "snapshots directory exists" test -d "$SCRIPT_DIR/../evals/snapshots"

echo ""
echo "=== Success path ==="
SUCCESS_OUTPUT="$(python3 "$RUNNER")"
assert_equals "success status ok" "$(echo "$SUCCESS_OUTPUT" | jq -r '.status')" "ok"
assert_equals "fixture count is 6" "$(echo "$SUCCESS_OUTPUT" | jq -r '.fixtureCount')" "6"
assert_equals "no harness failures" "$(echo "$SUCCESS_OUTPUT" | jq -r '.failed')" "0"
assert_equals "malformed case stays pinned" "$(echo "$SUCCESS_OUTPUT" | jq -r '.results[] | select(.caseId=="06-malformed-artifact-shape") | .invariantStatus')" "violated"

echo ""
echo "=== Absolute runner path ==="
pushd "$WORK" >/dev/null
ABS_OUTPUT="$(python3 "$RUNNER")"
popd >/dev/null
assert_equals "absolute path runner status ok" "$(echo "$ABS_OUTPUT" | jq -r '.status')" "ok"
assert_equals "absolute path runner fixture count is 6" "$(echo "$ABS_OUTPUT" | jq -r '.fixtureCount')" "6"

echo ""
echo "=== Empty fixture directory ==="
mkdir -p "$WORK/empty-fixtures" "$WORK/empty-snapshots"
set +e
EMPTY_OUTPUT="$(python3 "$RUNNER" --fixtures-dir "$WORK/empty-fixtures" --snapshots-dir "$WORK/empty-snapshots" 2>&1)"
EMPTY_RC=$?
set -e
assert_equals "empty fixture dir exits non-zero" "$EMPTY_RC" "1"
assert_equals "empty fixture dir status error" "$(echo "$EMPTY_OUTPUT" | jq -r '.status')" "error"
assert_equals "empty fixture dir failure code" "$(echo "$EMPTY_OUTPUT" | jq -r '.results[0].failedChecks[0]')" "runner.no_fixtures"

echo ""
echo "=== Coverage semantics ==="
MEDIUM_MISSING_OUTPUT="$(python3 - "$SCRIPT_DIR/../evals/checks.py" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("eval_checks", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

fixture = {
    "caseId": "medium-missing-auto-ok",
    "riskLevel": "medium",
    "flags": {},
    "artifacts": {
        "contract": {
            "schemaVersion": "1.0",
            "goal": "fixture goal",
            "acceptanceCriteria": [{"id": "AC-1", "description": "placeholder"}],
            "openQuestions": [],
            "requiredInputsProvided": True,
        },
        "auditSummary": {
            "verdict": "AUTO_OK",
            "confidence": 88,
            "reducedAuditCoverage": True,
            "regressions": [],
            "criticalFindings": [],
            "notes": ["Both external CLIs are genuinely missing."],
            "externalAuditCoverage": {"codex": "missing", "gemini": "missing"},
        },
        "proofpack": {
            "runMetadata": {"runId": "fixture-run"},
            "contractSummary": {"acceptanceCriteria": 1},
            "baselineSummary": {"status": "captured"},
            "implementationSummary": {"status": "simulated"},
            "auditSummary": {"status": "simulated"},
            "reviewSummaries": {},
            "externalAuditCoverage": {"codex": "missing", "gemini": "missing"},
            "finalVerdict": "AUTO_OK",
        },
    },
}
print(json.dumps(module.evaluate_fixture(fixture)))
PY
)"
assert_equals "medium missing degradation stays valid" "$(echo "$MEDIUM_MISSING_OUTPUT" | jq -r '.invariantStatus')" "ok"
assert_equals "medium missing degradation has zero failed checks" "$(echo "$MEDIUM_MISSING_OUTPUT" | jq -r '.checkCounts.failed')" "0"

MEDIUM_TIMEOUT_OUTPUT="$(python3 - "$SCRIPT_DIR/../evals/checks.py" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("eval_checks", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

fixture = {
    "caseId": "medium-timeout-auto-ok",
    "riskLevel": "medium",
    "flags": {},
    "artifacts": {
        "contract": {
            "schemaVersion": "1.0",
            "goal": "fixture goal",
            "acceptanceCriteria": [{"id": "AC-1", "description": "placeholder"}],
            "openQuestions": [],
            "requiredInputsProvided": True,
        },
        "auditSummary": {
            "verdict": "AUTO_OK",
            "confidence": 88,
            "reducedAuditCoverage": True,
            "regressions": [],
            "criticalFindings": [],
            "notes": ["Gemini timed out."],
            "externalAuditCoverage": {"codex": "ready", "gemini": "timeout"},
        },
        "proofpack": {
            "runMetadata": {"runId": "fixture-run"},
            "contractSummary": {"acceptanceCriteria": 1},
            "baselineSummary": {"status": "captured"},
            "implementationSummary": {"status": "simulated"},
            "auditSummary": {"status": "simulated"},
            "reviewSummaries": {},
            "externalAuditCoverage": {"codex": "ready", "gemini": "timeout"},
            "finalVerdict": "AUTO_OK",
        },
    },
}
print(json.dumps(module.evaluate_fixture(fixture)))
PY
)"
assert_equals "medium timeout AUTO_OK is rejected" "$(echo "$MEDIUM_TIMEOUT_OUTPUT" | jq -r '.invariantStatus')" "violated"
assert_equals "medium timeout failure code is pinned" "$(echo "$MEDIUM_TIMEOUT_OUTPUT" | jq -r '.failedChecks | index("audit.medium_non_missing_reduced_coverage") != null')" "true"

HIGH_MISSING_KEY_OUTPUT="$(python3 - "$SCRIPT_DIR/../evals/checks.py" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("eval_checks", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

fixture = {
    "caseId": "high-missing-gemini-key",
    "riskLevel": "high",
    "flags": {},
    "artifacts": {
        "contract": {
            "schemaVersion": "1.0",
            "goal": "fixture goal",
            "acceptanceCriteria": [{"id": "AC-1", "description": "placeholder"}],
            "openQuestions": [],
            "requiredInputsProvided": True,
        },
        "auditSummary": {
            "verdict": "AUTO_OK",
            "confidence": 88,
            "reducedAuditCoverage": False,
            "regressions": [],
            "criticalFindings": [],
            "notes": ["Coverage key is missing."],
            "externalAuditCoverage": {"codex": "ready"},
        },
        "proofpack": {
            "runMetadata": {"runId": "fixture-run"},
            "contractSummary": {"acceptanceCriteria": 1},
            "baselineSummary": {"status": "captured"},
            "implementationSummary": {"status": "simulated"},
            "auditSummary": {"status": "simulated"},
            "reviewSummaries": {},
            "externalAuditCoverage": {"codex": "ready"},
            "finalVerdict": "AUTO_OK",
        },
    },
}
print(json.dumps(module.evaluate_fixture(fixture)))
PY
)"
assert_equals "high risk missing coverage key is rejected" "$(echo "$HIGH_MISSING_KEY_OUTPUT" | jq -r '.invariantStatus')" "violated"
assert_equals "high risk missing coverage key failure is pinned" "$(echo "$HIGH_MISSING_KEY_OUTPUT" | jq -r '.failedChecks | index("audit.coverage_keys") != null')" "true"

echo ""
echo "=== Broken snapshot path ==="
cp -R "$SCRIPT_DIR/../evals" "$WORK/evals"
python3 - "$WORK/evals/snapshots/01-low-risk-happy-path.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data['observedVerdict'] = 'HUMAN_REVIEW'
path.write_text(json.dumps(data, indent=2) + '\n')
PY

set +e
BROKEN_OUTPUT="$(python3 "$RUNNER" --fixtures-dir "$WORK/evals/fixtures" --snapshots-dir "$WORK/evals/snapshots" 2>&1)"
BROKEN_RC=$?
set -e
assert_equals "broken snapshot exits non-zero" "$BROKEN_RC" "1"
assert_equals "broken snapshot status error" "$(echo "$BROKEN_OUTPUT" | jq -r '.status')" "error"
assert_equals "broken snapshot mismatch count" "$(echo "$BROKEN_OUTPUT" | jq '[.results[] | select(.snapshotStatus=="mismatch")] | length')" "1"
assert_equals "broken snapshot case id" "$(echo "$BROKEN_OUTPUT" | jq -r '.results[] | select(.snapshotStatus=="mismatch") | .caseId')" "01-low-risk-happy-path"

echo ""
echo "=== Results ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
