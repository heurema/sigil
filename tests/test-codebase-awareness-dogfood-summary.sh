#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SUMMARIZER="$ROOT_DIR/scripts/codebase_awareness/summarize_dogfood_run.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

setup_full_run() {
  local project="$1"
  mkdir -p "$project/.signum/contracts/example" "$project/.signum/cache"
  cat > "$project/.signum/contracts/example/contract.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "goal": "Validate signup email reuse behavior"
}
JSON
  cat > "$project/.signum/contracts/example/reuse_candidates.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "candidateCount": 3,
  "candidates": [
    {
      "candidateId": "cand-001",
      "kind": "existing-helper",
      "path": "src/shared/validation.ts",
      "symbol": "validateEmail",
      "score": 0.91
    },
    {
      "candidateId": "cand-002",
      "kind": "test-pattern",
      "path": "tests/shared/validation.test.ts",
      "score": 0.74
    },
    {
      "candidateId": "cand-003",
      "kind": "shared-module",
      "path": "src/shared",
      "symbol": "validation",
      "confidence": 0.68
    }
  ]
}
JSON
  cat > "$project/.signum/contracts/example/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "mode": "warn",
  "summary": "Fixture decision summary.",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "reuse",
      "action": "Call validateEmail.",
      "rationale": "Candidate matches the task."
    },
    {
      "candidateId": "cand-002",
      "disposition": "inspect-only",
      "rationale": "Use only as test reference."
    },
    {
      "candidateId": "cand-003",
      "disposition": "inspect-only",
      "rationale": "Shared module was inspected."
    }
  ]
}
JSON
  cat > "$project/.signum/contracts/example/duplicate_scan.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "mode": "warn",
  "recommendedOutcome": "clean",
  "summaryCounts": {"critical": 0, "major": 1, "minor": 0, "info": 0, "total": 1},
  "findings": []
}
JSON
  cat > "$project/.signum/cache/codebase-index-v1.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "scanStats": {
    "filesReused": 120,
    "filesExtracted": 3
  }
}
JSON
}

setup_minimal_run() {
  local project="$1"
  mkdir -p "$project/.signum/contracts/minimal" "$project/.signum/cache"
  cat > "$project/.signum/contracts/minimal/contract.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "minimal"
}
JSON
}

snapshot_project() {
  local project="$1" output="$2"
  (
    cd "$project"
    find . -type f ! -name 'codebase_awareness_dogfood_summary*.json' \
      | LC_ALL=C sort \
      | while IFS= read -r path; do shasum "$path"; done
  ) > "$output"
}

run_summary() {
  local project="$1" contract="$2" output="$3"
  (
    cd "$project"
    python3 "$SUMMARIZER" \
      --contract-root ".signum/contracts/$contract" \
      --cache-root ".signum/cache" \
      --output "$output"
  )
}

assert_full_summary() {
  local project="$1" summary="$2"
  if python3 - "$project/$summary" "$project" <<'PY'; then
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project = sys.argv[2]

assert summary["schemaVersion"] == "1.0", summary
assert summary["contractId"] == "example", summary
assert summary["mode"] == "warn", summary
assert summary["candidateCount"] == 3, summary
assert summary["topCandidates"][0] == {
    "candidateId": "cand-001",
    "kind": "existing-helper",
    "path": "src/shared/validation.ts",
    "symbol": "validateEmail",
    "score": 0.91,
}, summary["topCandidates"][0]
assert summary["topCandidates"][2]["score"] == 0.68, summary["topCandidates"][2]
assert summary["reuseDecision"] == {
    "present": True,
    "decisionCount": 3,
    "dispositions": {"inspect-only": 2, "reuse": 1},
}, summary["reuseDecision"]
assert summary["duplicateScan"] == {
    "present": True,
    "recommendedOutcome": "clean",
    "majorOrCritical": 1,
}, summary["duplicateScan"]
assert summary["cacheStats"] == {
    "present": True,
    "filesReused": 120,
    "filesExtracted": 3,
}, summary["cacheStats"]

def walk(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from walk(item)

for text in walk(summary):
    if project in text:
        raise AssertionError(f"absolute temp path leaked: {text}")
PY
    pass "full summary is parseable, compact, and portable"
  else
    fail "full summary is parseable, compact, and portable" "Python assertion failed"
  fi
}

assert_minimal_summary() {
  local project="$1" summary="$2"
  if python3 - "$project/$summary" <<'PY'; then
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert summary["schemaVersion"] == "1.0", summary
assert summary["contractId"] == "minimal", summary
assert summary["candidateCount"] == 0, summary
assert summary["topCandidates"] == [], summary
assert summary["reuseDecision"]["present"] is False, summary
assert summary["duplicateScan"]["present"] is False, summary
assert summary["cacheStats"]["present"] is False, summary
PY
    pass "missing optional artifacts produce a degraded report"
  else
    fail "missing optional artifacts produce a degraded report" "Python assertion failed"
  fi
}

echo "=== Codebase Awareness dogfood summary ==="

FULL="$WORK/full"
mkdir -p "$FULL"
setup_full_run "$FULL"
snapshot_project "$FULL" "$WORK/full.before"
if run_summary "$FULL" "example" ".signum/contracts/example/codebase_awareness_dogfood_summary.json" > "$WORK/full.out"; then
  pass "summary script exits 0 for full artifacts"
else
  fail "summary script exits 0 for full artifacts" "command failed"
fi
snapshot_project "$FULL" "$WORK/full.after"
if diff -u "$WORK/full.before" "$WORK/full.after" > "$WORK/full.diff"; then
  pass "summary script does not mutate source artifacts"
else
  fail "summary script does not mutate source artifacts" "$(cat "$WORK/full.diff")"
fi
assert_full_summary "$FULL" ".signum/contracts/example/codebase_awareness_dogfood_summary.json"

if run_summary "$FULL" "example" ".signum/contracts/example/codebase_awareness_dogfood_summary.second.json" > "$WORK/full-second.out" \
  && diff -u \
    "$FULL/.signum/contracts/example/codebase_awareness_dogfood_summary.json" \
    "$FULL/.signum/contracts/example/codebase_awareness_dogfood_summary.second.json" \
    > "$WORK/deterministic.diff"; then
  pass "summary output is deterministic for fixed inputs"
else
  fail "summary output is deterministic for fixed inputs" "$(cat "$WORK/deterministic.diff" 2>/dev/null || true)"
fi

MINIMAL="$WORK/minimal"
mkdir -p "$MINIMAL"
setup_minimal_run "$MINIMAL"
if run_summary "$MINIMAL" "minimal" ".signum/contracts/minimal/codebase_awareness_dogfood_summary.json" > "$WORK/minimal.out"; then
  pass "summary script exits 0 with missing optional artifacts"
else
  fail "summary script exits 0 with missing optional artifacts" "command failed"
fi
assert_minimal_summary "$MINIMAL" ".signum/contracts/minimal/codebase_awareness_dogfood_summary.json"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
