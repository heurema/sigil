#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
ROOT_FRAGMENT="$ROOT_DIR/commands/signum.fragments/100-phase-pack.md"
OVERLAY_FRAGMENT="$ROOT_DIR/platforms/claude-code/commands/signum.fragments/100-phase-pack.md"
ROOT_COMMAND="$ROOT_DIR/commands/signum.md"
OVERLAY_COMMAND="$ROOT_DIR/platforms/claude-code/commands/signum.md"
REFERENCE_DOC="$ROOT_DIR/docs/reference.md"
OVERLAY_REFERENCE_DOC="$ROOT_DIR/platforms/claude-code/docs/reference.md"
CODEX_SKILL="$ROOT_DIR/platforms/codex/SKILL.md"
WORK="$(mktemp -d)"
REUSE_STEP="$WORK/proofpack-reuse-summary-step.sh"
PACK_STEP="$WORK/proofpack-build-step.sh"
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

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label" "missing $needle"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$label" "unexpected $needle"
  else
    pass "$label"
  fi
}

assert_missing() {
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    fail "$label" "unexpected $path"
  else
    pass "$label"
  fi
}

assert_file() {
  local path="$1" label="$2"
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label" "missing $path"
  fi
}

assert_order() {
  local file="$1" before="$2" marker="$3" after="$4" label="$5"
  if python3 - "$file" "$before" "$marker" "$after" <<'PY'; then
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
positions = [text.find(item) for item in sys.argv[2:]]
if any(pos < 0 for pos in positions) or positions != sorted(positions):
    raise SystemExit(1)
PY
    pass "$label"
  else
    fail "$label" "markers are missing or out of order"
  fi
}

extract_block() {
  local heading="$1" output="$2"
  python3 - "$ROOT_FRAGMENT" "$heading" "$output" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
heading = sys.argv[2]
output = Path(sys.argv[3])
text = source.read_text(encoding="utf-8")
start = text.index(heading)
code_start = text.index("```bash", start) + len("```bash")
code_end = text.index("```", code_start)
output.write_text(text[code_start:code_end].lstrip(), encoding="utf-8")
PY
}

check_pack_surface() {
  local file="$1" label="$2"
  assert_order "$file" \
    '### Step 4.0: Transition contract status to completed' \
    '### Step 4.0.5: PROOFPACK_REUSE_SUMMARY' \
    '### Step 4.1: Collect metadata and build proofpack' \
    "$label inserts reuse summary before proofpack assembly"
  assert_contains "$file" 'PROOFPACK_REUSE_SUMMARY' "$label names reuse summary substep"
  assert_contains "$file" 'scripts/build_reuse_summary.py' "$label calls reuse summary wrapper"
  assert_contains "$file" 'IMPLEMENTATION_CONTEXT_PATH="${ARTIFACT_ROOT}implementation_context.json"' "$label uses active-root implementation context"
  assert_contains "$file" 'REUSE_CANDIDATES_PATH="${ARTIFACT_ROOT}reuse_candidates.json"' "$label uses active-root reuse candidates"
  assert_contains "$file" 'REUSE_DECISION_PATH="${ARTIFACT_ROOT}reuse_decision.json"' "$label uses active-root reuse decision"
  assert_contains "$file" 'DUPLICATE_SCAN_PATH="${ARTIFACT_ROOT}duplicate_scan.json"' "$label uses active-root duplicate scan"
  assert_contains "$file" 'REUSE_SUMMARY_PATH="${ARTIFACT_ROOT}reuse_summary.json"' "$label writes active-root reuse summary"
  assert_contains "$file" 'if [ "$CODEBASE_AWARENESS_MODE" = "off" ]; then' "$label skips when off"
  assert_contains "$file" 'rm -f "$REUSE_SUMMARY_PATH"' "$label clears stale summaries before enabled generation"
  assert_contains "$file" 'PACK_CODEBASE_AWARENESS_MODE' "$label resolves mode during proofpack assembly"
  assert_contains "$file" 'if [ "$PACK_CODEBASE_AWARENESS_MODE" != "off" ] && [ -f "$REUSE_SUMMARY_PATH" ]; then' "$label ignores stale summaries when off"
  assert_contains "$file" 'continuing PACK' "$label hint/warn failures continue"
  assert_contains "$file" 'failed in gate mode' "$label gate failure blocks"
  assert_contains "$file" '.codebaseAwareness = $codebaseAwarenessJson' "$label adds proofpack Codebase Awareness section"
  assert_contains "$file" '.artifactRefs = ((.artifactRefs // []) + ($codebaseAwarenessJson.artifactRefs // []))' "$label adds proofpack artifact references"
  assert_contains "$file" 'Project-level cache files under .signum/cache/ are rebuildable' "$label documents cache exclusion"
}

setup_project() {
  local project="$1"
  mkdir -p "$project/scripts/codebase_awareness" "$project/lib" "$project/.signum/contracts/sig-example" "$project/.signum/cache"
  cp "$ROOT_DIR/scripts/build_reuse_summary.py" "$project/scripts/build_reuse_summary.py"
  cp "$ROOT_DIR/scripts/codebase_awareness/build_reuse_summary.py" "$project/scripts/codebase_awareness/build_reuse_summary.py"
  cp "$ROOT_DIR/lib/contract-dir.sh" "$project/lib/contract-dir.sh"

  cat > "$project/.signum/contracts/index.json" <<'JSON'
{"activeContractId":"sig-example","contracts":[{"contractId":"sig-example","status":"active","directory":".signum/contracts/sig-example/"}]}
JSON
  cat > "$project/.signum/contracts/sig-example/contract.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "sig-example",
  "goal": "Validate signup email reuse behavior",
  "riskLevel": "medium",
  "status": "active",
  "timestamps": {"createdAt": "2026-01-01T00:00:00Z"}
}
JSON
  cat > "$project/.signum/contracts/sig-example/implementation_context.json" <<'JSON'
{"schemaVersion":"1.0","contractId":"sig-example","styleHints":["follow validation helper style"]}
JSON
  cat > "$project/.signum/contracts/sig-example/reuse_candidates.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "sig-example",
  "candidateCount": 1,
  "candidates": [
    {
      "candidateId": "cand-001",
      "kind": "existing-helper",
      "path": "src/shared/validation.ts",
      "symbol": "validateEmail",
      "score": 0.91,
      "whyRelevant": ["name and token overlap"],
      "sourceSnippet": "function validateEmail(email) { return email.includes('@'); }"
    }
  ]
}
JSON
  cat > "$project/.signum/contracts/sig-example/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "sig-example",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "reuse",
      "action": "Call validateEmail",
      "rationale": "Candidate matches task intent."
    }
  ],
  "newCodeJustifications": [],
  "summary": "Reuse existing helper."
}
JSON
  cat > "$project/.signum/contracts/sig-example/duplicate_scan.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "sig-example",
  "generatedAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "summaryCounts": {"critical": 0, "major": 1, "minor": 0, "info": 0, "total": 1},
  "recommendedOutcome": "review-recommended",
  "decisionStatus": {"present": true, "valid": true, "mode": "warn", "entries": 1, "notes": []},
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
    }
  ]
}
JSON
  cat > "$project/.signum/contracts/sig-example/audit_summary.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "sig-example",
  "decision": "HUMAN_REVIEW",
  "releaseVerdict": "HOLD",
  "mechanic": "pass",
  "confidence": {"overall": 82},
  "availableReviews": 0,
  "reasoning": ["fixture audit"],
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
  cat > "$project/.signum/contracts/sig-example/baseline.json" <<'JSON'
{"schemaVersion":"1.0","status":"pass"}
JSON
  cat > "$project/.signum/contracts/sig-example/combined.patch" <<'PATCH'
diff --git a/src/features/signup.ts b/src/features/signup.ts
index 1111111..2222222 100644
--- a/src/features/signup.ts
+++ b/src/features/signup.ts
@@ -1,3 +1,4 @@
+export const signupValidationMode = "strict";
 export function createSignupPayload(email: string) {
   return { email };
 }
PATCH
  cat > "$project/.signum/contracts/sig-example/execute_log.json" <<'JSON'
{"started_at":"2026-01-01T00:00:00Z","duration_ms":10,"totalAttempts":1}
JSON
  cat > "$project/.signum/contracts/sig-example/mechanic_report.json" <<'JSON'
{"status":"pass","checks":[]}
JSON
  cat > "$project/.signum/contracts/sig-example/holdout_report.json" <<'JSON'
{"status":"pass","checks":[]}
JSON
  cat > "$project/.signum/contracts/sig-example/policy_scan.json" <<'JSON'
{"summary":{"critical":0,"major":0,"minor":0},"findings":[]}
JSON
  cat > "$project/.signum/contracts/sig-example/approval.json" <<'JSON'
{"approved":true,"approvedAt":"2026-01-01T00:00:00Z"}
JSON
  cat > "$project/.signum/contracts/sig-example/execution_context.json" <<'JSON'
{"base_commit":"abc123","run_id":"run-001"}
JSON
  cat > "$project/.signum/contracts/sig-example/contract-hash.txt" <<'TXT'
contract_sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
approved_at: 2026-01-01T00:00:00Z
TXT
  cat > "$project/.signum/cache/codebase-index-v1.json" <<'JSON'
{"schemaVersion":"1.0","note":"project cache should not be packed"}
JSON
  cat > "$project/.signum/cache/style-profile-v1.json" <<'JSON'
{"schemaVersion":"1.0","note":"project cache should not be packed"}
JSON
}

run_reuse_step() {
  local project="$1" mode="$2" output="$3"
  (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS="$mode" bash "$REUSE_STEP"
  ) >"$output" 2>&1
}

run_pack_step() {
  local project="$1" mode="$2" output="$3"
  (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS="$mode" bash "$PACK_STEP"
  ) >"$output" 2>&1
}

assert_reuse_summary_status() {
  local project="$1" expected="$2" label="$3"
  if [ "$(jq -r '.status' "$project/.signum/contracts/sig-example/reuse_summary.json")" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "unexpected status"
  fi
}

assert_no_codebase_section() {
  local project="$1" label="$2"
  local proofpack="$project/.signum/contracts/sig-example/proofpack.json"
  if python3 - "$proofpack" <<'PY'; then
import json
import sys
from pathlib import Path

proofpack = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if "codebaseAwareness" in proofpack:
    raise SystemExit("unexpected top-level codebaseAwareness")
if "codebaseAwareness" in proofpack.get("checks", {}):
    raise SystemExit("unexpected checks.codebaseAwareness")
refs = [item.get("path") for item in proofpack.get("artifactRefs", []) if isinstance(item, dict)]
for forbidden in ("reuse_summary.json", "duplicate_scan.json", "reuse_candidates.json", "reuse_decision.json", "implementation_context.json"):
    if forbidden in refs:
        raise SystemExit(f"unexpected artifactRef: {forbidden}")
PY
    pass "$label"
  else
    fail "$label" "Codebase Awareness section was present"
  fi
}

assert_proofpack_codebase_section() {
  local project="$1" label="${2:-proofpack includes compact Codebase Awareness evidence}" duplicate_expected="${3:-yes}"
  local proofpack="$project/.signum/contracts/sig-example/proofpack.json"
  if python3 - "$proofpack" "$duplicate_expected" "$WORK" <<'PY'; then
import json
import sys
from pathlib import Path

proofpack = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
duplicate_expected = sys.argv[2] == "yes"
work_root = sys.argv[3]
awareness = proofpack.get("codebaseAwareness")
if not isinstance(awareness, dict):
    raise SystemExit("missing codebaseAwareness")
if awareness.get("reuseSummaryPath") != "reuse_summary.json":
    raise SystemExit("missing reuse summary path")
if duplicate_expected and awareness.get("duplicateScanPath") != "duplicate_scan.json":
    raise SystemExit("missing duplicate scan path")
if not duplicate_expected and awareness.get("duplicateScanPath") is not None:
    raise SystemExit("unexpected duplicate scan path")
checks = proofpack.get("checks", {}).get("codebaseAwareness", {})
if checks.get("reuseSummary", {}).get("status") != "present":
    raise SystemExit("reuse summary envelope missing")
if duplicate_expected and checks.get("duplicateScan", {}).get("status") != "present":
    raise SystemExit("duplicate scan envelope missing")
refs = [item.get("path") for item in proofpack.get("artifactRefs", []) if isinstance(item, dict)]
if refs.count("reuse_summary.json") != 1:
    raise SystemExit("reuse summary artifactRef missing or duplicated")
if "reuse_summary.json" not in refs:
    raise SystemExit("reuse summary artifactRef missing")
if duplicate_expected and refs.count("duplicate_scan.json") != 1:
    raise SystemExit("duplicate scan artifactRef missing")
if not duplicate_expected and "duplicate_scan.json" in refs:
    raise SystemExit("unexpected duplicate scan artifactRef")
contract_root = Path(sys.argv[1]).parent
for expected in ("implementation_context.json", "reuse_candidates.json", "reuse_decision.json"):
    if (contract_root / expected).exists() and refs.count(expected) != 1:
        raise SystemExit(f"run-scoped evidence artifactRef missing: {expected}")
    if not (contract_root / expected).exists() and expected in refs:
        raise SystemExit(f"missing evidence should not be referenced: {expected}")
if proofpack.get("decision") != "HUMAN_REVIEW":
    raise SystemExit("audit decision changed")
if proofpack.get("releaseVerdict") != "HOLD":
    raise SystemExit("releaseVerdict changed")
if proofpack.get("riskLevel") != "medium":
    raise SystemExit("unrelated riskLevel field changed")
if proofpack.get("checks", {}).get("mechanic", {}).get("status") != "present":
    raise SystemExit("unrelated mechanic envelope missing")
text = json.dumps(proofpack, sort_keys=True)
for forbidden in (
    ".signum/cache/codebase-index-v1.json",
    ".signum/cache/style-profile-v1.json",
    ".signum/cache/file-digests-v1.json",
):
    if forbidden in text:
        raise SystemExit(f"project cache path leaked: {forbidden}")
awareness_text = json.dumps(
    {
        "codebaseAwareness": proofpack.get("codebaseAwareness"),
        "checksCodebaseAwareness": proofpack.get("checks", {}).get("codebaseAwareness"),
    },
    sort_keys=True,
)
if work_root in awareness_text:
    raise SystemExit("temp absolute path leaked into Codebase Awareness proofpack section")
for snippet in ("function validateEmail", "sourceSnippet"):
    if snippet in awareness_text:
        raise SystemExit(f"source snippet leaked into Codebase Awareness proofpack section: {snippet}")
PY
    pass "$label"
  else
    fail "$label" "shape check failed"
  fi
}

extract_block '### Step 4.0.5: PROOFPACK_REUSE_SUMMARY' "$REUSE_STEP"
extract_block '### Step 4.1: Collect metadata and build proofpack' "$PACK_STEP"
if bash -n "$REUSE_STEP"; then
  pass "extracted PROOFPACK_REUSE_SUMMARY is valid bash"
else
  fail "extracted PROOFPACK_REUSE_SUMMARY is valid bash" "bash -n failed"
fi
if bash -n "$PACK_STEP"; then
  pass "extracted proofpack assembly step is valid bash"
else
  fail "extracted proofpack assembly step is valid bash" "bash -n failed"
fi

check_pack_surface "$ROOT_FRAGMENT" "root fragment"
check_pack_surface "$ROOT_COMMAND" "root command"
check_pack_surface "$OVERLAY_FRAGMENT" "Claude overlay fragment"
check_pack_surface "$OVERLAY_COMMAND" "Claude overlay command"

OFF_PROJECT="$WORK/off"
setup_project "$OFF_PROJECT"
run_reuse_step "$OFF_PROJECT" off "$OFF_PROJECT.out"
assert_missing "$OFF_PROJECT/.signum/contracts/sig-example/reuse_summary.json" "off mode does not create reuse summary"
run_pack_step "$OFF_PROJECT" off "$OFF_PROJECT/pack.out"
assert_no_codebase_section "$OFF_PROJECT" "off mode proofpack has no Codebase Awareness section"

STALE_OFF="$WORK/stale-off"
setup_project "$STALE_OFF"
run_reuse_step "$STALE_OFF" warn "$STALE_OFF/reuse-warn.out"
run_pack_step "$STALE_OFF" off "$STALE_OFF/pack-off.out"
assert_no_codebase_section "$STALE_OFF" "off mode ignores stale reuse summary"

STALE_OFF_ARTIFACTS="$WORK/stale-off-artifacts"
setup_project "$STALE_OFF_ARTIFACTS"
run_pack_step "$STALE_OFF_ARTIFACTS" off "$STALE_OFF_ARTIFACTS/pack-off.out"
assert_no_codebase_section "$STALE_OFF_ARTIFACTS" "off mode ignores stale duplicate and candidate artifacts"

HINT_PROJECT="$WORK/hint"
setup_project "$HINT_PROJECT"
run_reuse_step "$HINT_PROJECT" hint "$HINT_PROJECT.out"
assert_file "$HINT_PROJECT/.signum/contracts/sig-example/reuse_summary.json" "hint mode creates reuse summary"
assert_reuse_summary_status "$HINT_PROJECT" "complete" "hint summary is complete with full inputs"
run_pack_step "$HINT_PROJECT" hint "$HINT_PROJECT/pack.out"
assert_proofpack_codebase_section "$HINT_PROJECT" "hint mode proofpack includes generated summary"

HINT_DEGRADED="$WORK/hint-degraded"
setup_project "$HINT_DEGRADED"
rm -f "$HINT_DEGRADED/.signum/contracts/sig-example/reuse_decision.json" \
  "$HINT_DEGRADED/.signum/contracts/sig-example/duplicate_scan.json"
run_reuse_step "$HINT_DEGRADED" hint "$HINT_DEGRADED/reuse.out"
assert_reuse_summary_status "$HINT_DEGRADED" "degraded" "hint degraded summary status"
run_pack_step "$HINT_DEGRADED" hint "$HINT_DEGRADED/pack.out"
assert_proofpack_codebase_section "$HINT_DEGRADED" "hint degraded proofpack includes generated summary" "no"

HINT_FAIL="$WORK/hint-failure"
setup_project "$HINT_FAIL"
printf '{bad-json' > "$HINT_FAIL/.signum/contracts/sig-example/reuse_candidates.json"
run_reuse_step "$HINT_FAIL" warn "$HINT_FAIL/stale.out"
if run_reuse_step "$HINT_FAIL" hint "$HINT_FAIL.out"; then
  assert_contains "$HINT_FAIL.out" "continuing PACK" "hint summary failure warns and continues"
  assert_missing "$HINT_FAIL/.signum/contracts/sig-example/reuse_summary.json" "hint failure clears stale reuse summary"
else
  fail "hint summary failure warns and continues" "step exited non-zero"
fi

WARN_PROJECT="$WORK/warn"
setup_project "$WARN_PROJECT"
run_reuse_step "$WARN_PROJECT" warn "$WARN_PROJECT.out"
assert_file "$WARN_PROJECT/.signum/contracts/sig-example/reuse_summary.json" "warn mode creates reuse summary"
assert_reuse_summary_status "$WARN_PROJECT" "complete" "warn summary is complete with full inputs"
run_pack_step "$WARN_PROJECT" warn "$WARN_PROJECT/pack.out"
assert_proofpack_codebase_section "$WARN_PROJECT" "warn mode proofpack includes generated summary"

WARN_DEGRADED="$WORK/warn-degraded"
setup_project "$WARN_DEGRADED"
rm -f "$WARN_DEGRADED/.signum/contracts/sig-example/duplicate_scan.json"
run_reuse_step "$WARN_DEGRADED" warn "$WARN_DEGRADED/reuse.out"
assert_reuse_summary_status "$WARN_DEGRADED" "degraded" "warn degraded summary status"
run_pack_step "$WARN_DEGRADED" warn "$WARN_DEGRADED/pack.out"
assert_proofpack_codebase_section "$WARN_DEGRADED" "warn degraded proofpack includes generated summary" "no"

WARN_FAIL="$WORK/warn-failure"
setup_project "$WARN_FAIL"
printf '{bad-json' > "$WARN_FAIL/.signum/contracts/sig-example/duplicate_scan.json"
run_reuse_step "$WARN_FAIL" warn "$WARN_FAIL/stale.out"
if run_reuse_step "$WARN_FAIL" warn "$WARN_FAIL.out"; then
  assert_contains "$WARN_FAIL.out" "continuing PACK" "warn summary failure warns and continues"
  assert_missing "$WARN_FAIL/.signum/contracts/sig-example/reuse_summary.json" "warn failure clears stale reuse summary"
else
  fail "warn summary failure warns and continues" "step exited non-zero"
fi

GATE_PROJECT="$WORK/gate"
setup_project "$GATE_PROJECT"
run_reuse_step "$GATE_PROJECT" gate "$GATE_PROJECT.out"
assert_file "$GATE_PROJECT/.signum/contracts/sig-example/reuse_summary.json" "gate mode creates reuse summary with valid inputs"
run_pack_step "$GATE_PROJECT" gate "$GATE_PROJECT/pack.out"
assert_proofpack_codebase_section "$GATE_PROJECT" "gate mode proofpack includes generated summary"

GATE_MISSING="$WORK/gate-missing"
setup_project "$GATE_MISSING"
run_reuse_step "$GATE_MISSING" warn "$GATE_MISSING/stale.out"
rm -f "$GATE_MISSING/.signum/contracts/sig-example/reuse_decision.json"
set +e
run_reuse_step "$GATE_MISSING" gate "$GATE_MISSING.out"
gate_missing_status=$?
set -e
if [ "$gate_missing_status" -ne 0 ]; then
  pass "gate missing required input blocks PACK"
  assert_missing "$GATE_MISSING/.signum/contracts/sig-example/reuse_summary.json" "gate missing input clears stale reuse summary"
else
  fail "gate missing required input blocks PACK" "step exited 0"
fi

GATE_INVALID="$WORK/gate-invalid"
setup_project "$GATE_INVALID"
run_reuse_step "$GATE_INVALID" warn "$GATE_INVALID/stale.out"
printf '{bad-json' > "$GATE_INVALID/.signum/contracts/sig-example/duplicate_scan.json"
set +e
run_reuse_step "$GATE_INVALID" gate "$GATE_INVALID.out"
gate_invalid_status=$?
set -e
if [ "$gate_invalid_status" -ne 0 ]; then
  pass "gate invalid JSON blocks PACK"
  assert_missing "$GATE_INVALID/.signum/contracts/sig-example/reuse_summary.json" "gate invalid JSON clears stale reuse summary"
else
  fail "gate invalid JSON blocks PACK" "step exited 0"
fi

PACK_PROJECT="$WORK/pack-proofpack"
setup_project "$PACK_PROJECT"
cp "$PACK_PROJECT/.signum/contracts/sig-example/audit_summary.json" "$PACK_PROJECT/audit-before.json"
run_reuse_step "$PACK_PROJECT" warn "$PACK_PROJECT/reuse.out"
run_pack_step "$PACK_PROJECT" warn "$PACK_PROJECT/pack.out"
assert_file "$PACK_PROJECT/.signum/contracts/sig-example/proofpack.json" "proofpack is written"
assert_proofpack_codebase_section "$PACK_PROJECT"
if python3 "$ROOT_DIR/scripts/validate_proofpack.py" \
  "$PACK_PROJECT/.signum/contracts/sig-example/proofpack.json" \
  --repo-root "$ROOT_DIR" \
  --contract-root "$PACK_PROJECT/.signum/contracts/sig-example" \
  > "$PACK_PROJECT/validate.out" 2>&1; then
  pass "proofpack validator accepts Codebase Awareness inclusion"
else
  fail "proofpack validator accepts Codebase Awareness inclusion" "$(cat "$PACK_PROJECT/validate.out")"
fi
if cmp -s "$PACK_PROJECT/audit-before.json" "$PACK_PROJECT/.signum/contracts/sig-example/audit_summary.json"; then
  pass "PACK does not mutate audit summary"
else
  fail "PACK does not mutate audit summary" "audit_summary changed"
fi

jq '{decision, releaseVerdict, codebaseAwareness, artifactRefs, checksCodebaseAwareness: .checks.codebaseAwareness}' \
  "$PACK_PROJECT/.signum/contracts/sig-example/proofpack.json" > "$PACK_PROJECT/proofpack-semantic-before.json"
run_pack_step "$PACK_PROJECT" warn "$PACK_PROJECT/pack-second.out"
jq '{decision, releaseVerdict, codebaseAwareness, artifactRefs, checksCodebaseAwareness: .checks.codebaseAwareness}' \
  "$PACK_PROJECT/.signum/contracts/sig-example/proofpack.json" > "$PACK_PROJECT/proofpack-semantic-after.json"
if cmp -s "$PACK_PROJECT/proofpack-semantic-before.json" "$PACK_PROJECT/proofpack-semantic-after.json"; then
  pass "proofpack Codebase Awareness inclusion is semantically idempotent"
else
  fail "proofpack Codebase Awareness inclusion is semantically idempotent" "semantic section changed"
fi
assert_proofpack_codebase_section "$PACK_PROJECT" "second PACK run has one Codebase Awareness section and unique refs"

assert_not_contains "$PACK_PROJECT/.signum/contracts/sig-example/proofpack.json" ".signum/cache/codebase-index-v1.json" "proofpack does not embed codebase index cache"
assert_not_contains "$PACK_PROJECT/.signum/contracts/sig-example/proofpack.json" ".signum/cache/style-profile-v1.json" "proofpack does not embed style profile cache"
assert_not_contains "$PACK_PROJECT/.signum/contracts/sig-example/proofpack.json" ".signum/cache/file-digests-v1.json" "proofpack does not embed future digest cache"
assert_not_contains "$ROOT_FRAGMENT" "reuse_summary produced by AUDIT" "PACK wiring does not claim AUDIT produces reuse summary"
assert_not_contains "$ROOT_FRAGMENT" "evaluate_codebase_awareness_audit.py" "PACK does not run verdict evaluator"
assert_not_contains "$OVERLAY_FRAGMENT" "evaluate_codebase_awareness_audit.py" "overlay PACK does not run verdict evaluator"
for doc in "$REFERENCE_DOC" "$OVERLAY_REFERENCE_DOC" "$CODEX_SKILL"; do
  assert_not_contains "$doc" "Tree-sitter" "$(basename "$doc") does not overclaim Tree-sitter"
  assert_not_contains "$doc" "Semgrep" "$(basename "$doc") does not overclaim Semgrep"
  assert_not_contains "$doc" "CodeQL" "$(basename "$doc") does not overclaim CodeQL"
  assert_not_contains "$doc" "embeddings" "$(basename "$doc") does not overclaim embeddings"
  assert_not_contains "$doc" "auto-refactor" "$(basename "$doc") does not claim auto-refactor mode"
done

printf 'test-codebase-awareness-pack-wiring: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
