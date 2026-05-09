#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
BUILDER="$ROOT_DIR/scripts/build_reuse_summary.py"
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

setup_inputs() {
  local project="$1"
  mkdir -p "$project/.signum/contracts/example" "$project/.signum/cache"
  cat > "$project/.signum/contracts/example/contract.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "goal": "Validate signup email reuse behavior",
  "riskLevel": "medium"
}
JSON
  cat > "$project/.signum/contracts/example/implementation_context.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "styleHints": ["follow existing validation helper style"]
}
JSON
  cat > "$project/.signum/contracts/example/reuse_candidates.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "candidateCount": 5,
  "candidates": [
    {
      "candidateId": "cand-001",
      "kind": "existing-helper",
      "path": "src/shared/validation.ts",
      "symbol": "validateEmail",
      "score": 0.91,
      "whyRelevant": ["name and token overlap repeated across validation helper call sites with enough detail to exercise compact summary truncation for reviewer-facing proofpack output without carrying unnecessary source context", "shared helper already used"],
      "sourceSnippet": "function validateEmail(email) { return email.includes('@'); }"
    },
    {
      "candidateId": "cand-002",
      "kind": "test-pattern",
      "path": "tests/signup.test.ts",
      "symbol": null,
      "score": 0.7,
      "whyRelevant": ["sibling test pattern"],
      "sourceSnippet": "expect(validateEmail('a@example.com')).toBe(true)"
    },
    {
      "candidateId": "cand-003",
      "kind": "shared-module",
      "path": "src/shared/normalizers.ts",
      "symbol": "normalizeEmail",
      "score": 0.86,
      "whyRelevant": ["shared normalizer already handles email casing"],
      "sourceSnippet": "export function normalizeEmail(value) { return value.trim().toLowerCase(); }"
    },
    {
      "candidateId": "cand-004",
      "kind": "existing-helper",
      "path": "src/shared/errors.ts",
      "symbol": "validationError",
      "score": 0.72,
      "whyRelevant": ["error helper follows local convention"],
      "sourceSnippet": "export function validationError(message) { return { ok: false, message }; }"
    },
    {
      "candidateId": "cand-005",
      "kind": "boundary",
      "path": "src/features/signup/index.ts",
      "symbol": null,
      "score": 0.51,
      "whyRelevant": ["feature boundary fixture"],
      "sourceSnippet": "export * from './signup';"
    }
  ]
}
JSON
  cat > "$project/.signum/contracts/example/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "reuse",
      "action": "Call validateEmail",
      "rationale": "Candidate matches task intent."
    },
    {
      "candidateId": "cand-002",
      "disposition": "follow-pattern",
      "action": "Mirror sibling test layout",
      "rationale": "Candidate matches test convention."
    }
  ],
  "newCodeJustifications": ["Fixture justifies one local wrapper."],
  "summary": "Fixture decision summary."
}
JSON
  cat > "$project/.signum/contracts/example/duplicate_scan.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "generatedAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "summaryCounts": {"critical": 0, "major": 1, "minor": 1, "info": 0, "total": 2},
  "recommendedOutcome": "review-recommended",
  "decisionStatus": {"present": true, "valid": true, "mode": "warn", "entries": 2, "notes": []},
  "findings": [
    {
      "findingId": "dup-001",
      "kind": "new-helper-similar-to-existing-candidate",
      "severity": "major",
      "path": "src/features/signup.ts",
      "candidateIds": ["cand-001"],
      "score": 0.86,
      "why": ["token overlap", "candidate high confidence"],
      "matches": [],
      "decisionAddressed": false,
      "recommendedAction": "reuse-existing-or-justify"
    },
    {
      "findingId": "dup-002",
      "kind": "possible-convention-drift",
      "severity": "minor",
      "path": "tests/signup.test.ts",
      "candidateIds": [],
      "score": 0.3,
      "why": ["minor convention hint"],
      "matches": [],
      "decisionAddressed": true,
      "recommendedAction": "inspect"
    }
  ]
}
JSON
  cat > "$project/.signum/contracts/example/audit_summary.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "decision": "HUMAN_REVIEW",
  "releaseVerdict": "HOLD",
  "reasoning": "Fixture audit.",
  "codebaseAwareness": {
    "mode": "warn",
    "duplicateScanPresent": true,
    "duplicateScanValid": true,
    "appliedOutcomeCap": "HUMAN_REVIEW",
    "reason": "warn mode caps unresolved major or critical duplicate findings at HUMAN_REVIEW",
    "unresolvedMajorFindings": 1,
    "unresolvedCriticalFindings": 0
  }
}
JSON
}

run_builder() {
  local project="$1" mode="$2"
  (
    cd "$project"
    python3 "$BUILDER" \
      --project-root "." \
      --contract ".signum/contracts/example/contract.json" \
      --implementation-context ".signum/contracts/example/implementation_context.json" \
      --reuse-candidates ".signum/contracts/example/reuse_candidates.json" \
      --reuse-decision ".signum/contracts/example/reuse_decision.json" \
      --duplicate-scan ".signum/contracts/example/duplicate_scan.json" \
      --audit-summary ".signum/contracts/example/audit_summary.json" \
      --output ".signum/contracts/example/reuse_summary.json" \
      --mode "$mode" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

expect_exit() {
  local label="$1" expected="$2" project="$3" mode="$4"
  local status=0
  set +e
  run_builder "$project" "$mode" > "$project/$label.out" 2> "$project/$label.err"
  status=$?
  set -e
  if [ "$status" -eq "$expected" ]; then
    pass "$label exits $expected"
  else
    fail "$label exits $expected" "got $status"
  fi
}

assert_summary() {
  local project="$1" expected_status="$2" label="$3"
  if python3 - "$project/.signum/contracts/example/reuse_summary.json" "$expected_status" <<'PY'; then
import sys
import json
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if summary.get("status") != sys.argv[2]:
    raise SystemExit(f"status={summary.get('status')}")
expected = {
    "schemaVersion",
    "contractId",
    "generatedAt",
    "mode",
    "status",
    "inputs",
    "candidateSummary",
    "decisionSummary",
    "duplicateAuditSummary",
    "verdictImpact",
    "evidenceRefs",
    "notes",
}
if set(summary) != expected:
    raise SystemExit(f"unexpected top-level keys={sorted(summary)}")
if summary.get("status") not in {"disabled", "complete", "degraded", "missing"}:
    raise SystemExit(f"unknown status={summary.get('status')}")
for key in ("candidateSummary", "decisionSummary", "duplicateAuditSummary", "verdictImpact", "evidenceRefs"):
    if key not in summary:
        raise SystemExit(f"missing {key}")
top = summary["candidateSummary"].get("topCandidates", [])
if len(top) > 3:
    raise SystemExit(f"too many top candidates={len(top)}")
if "sourceSnippet" in json.dumps(summary, sort_keys=True):
    raise SystemExit("source snippet leaked into summary")
for item in top:
    reason = item.get("firstReason")
    if isinstance(reason, str) and len(reason) > 160:
        raise SystemExit("firstReason was not compacted")
if ".signum/cache" in json.dumps(summary, sort_keys=True):
    raise SystemExit("project cache leaked into summary")
if str(Path(sys.argv[1]).parents[3]) in json.dumps(summary, sort_keys=True):
    raise SystemExit("absolute temp path leaked into summary")
PY
    pass "$label"
  else
    fail "$label" "summary shape mismatch"
  fi
}

COMPLETE="$WORK/complete"
setup_inputs "$COMPLETE"
if run_builder "$COMPLETE" warn; then
  pass "complete summary exits 0"
else
  fail "complete summary exits 0" "builder failed"
fi
assert_summary "$COMPLETE" "complete" "complete summary has compact sections"

cp "$COMPLETE/.signum/contracts/example/reuse_summary.json" "$WORK/reuse-summary-first.json"
run_builder "$COMPLETE" warn >/dev/null
if cmp -s "$WORK/reuse-summary-first.json" "$COMPLETE/.signum/contracts/example/reuse_summary.json"; then
  pass "reuse summary is byte-stable with fixed generatedAt"
else
  fail "reuse summary is byte-stable with fixed generatedAt" "output changed"
fi

HINT_DEGRADED="$WORK/hint-degraded"
setup_inputs "$HINT_DEGRADED"
rm -f "$HINT_DEGRADED/.signum/contracts/example/reuse_decision.json" \
  "$HINT_DEGRADED/.signum/contracts/example/duplicate_scan.json"
expect_exit "degraded-hint" 0 "$HINT_DEGRADED" hint
assert_summary "$HINT_DEGRADED" "degraded" "hint missing evidence writes degraded summary"

WARN_DEGRADED="$WORK/warn-degraded"
setup_inputs "$WARN_DEGRADED"
rm -f "$WARN_DEGRADED/.signum/contracts/example/duplicate_scan.json"
expect_exit "warn-degraded" 0 "$WARN_DEGRADED" warn
assert_summary "$WARN_DEGRADED" "degraded" "warn missing optional evidence writes degraded summary"

GATE_MISSING="$WORK/gate-missing"
setup_inputs "$GATE_MISSING"
rm -f "$GATE_MISSING/.signum/contracts/example/reuse_decision.json"
expect_exit "gate-missing" 2 "$GATE_MISSING" gate

INVALID_JSON="$WORK/invalid-json"
setup_inputs "$INVALID_JSON"
printf '{not-json' > "$INVALID_JSON/.signum/contracts/example/reuse_candidates.json"
expect_exit "invalid-json" 3 "$INVALID_JSON" warn

GATE_INVALID_JSON="$WORK/gate-invalid-json"
setup_inputs "$GATE_INVALID_JSON"
printf '{not-json' > "$GATE_INVALID_JSON/.signum/contracts/example/duplicate_scan.json"
expect_exit "gate-invalid-json" 3 "$GATE_INVALID_JSON" gate

if ! grep -R "$WORK" "$COMPLETE/.signum/contracts/example/reuse_summary.json" >/dev/null 2>&1; then
  pass "reuse summary contains no temp absolute paths"
else
  fail "reuse summary contains no temp absolute paths" "absolute path found"
fi

if ! grep -Fq ".signum/cache/codebase-index-v1.json" "$COMPLETE/.signum/contracts/example/reuse_summary.json" \
  && ! grep -Fq ".signum/cache/style-profile-v1.json" "$COMPLETE/.signum/contracts/example/reuse_summary.json"; then
  pass "reuse summary does not package project cache paths"
else
  fail "reuse summary does not package project cache paths" "cache path found"
fi

if ! grep -Fq "function validateEmail" "$COMPLETE/.signum/contracts/example/reuse_summary.json" \
  && ! grep -Fq "sourceSnippet" "$COMPLETE/.signum/contracts/example/reuse_summary.json"; then
  pass "reuse summary does not include source snippets"
else
  fail "reuse summary does not include source snippets" "source snippet found"
fi

printf 'test-codebase-reuse-summary: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
