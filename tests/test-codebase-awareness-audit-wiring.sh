#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
ROOT_FRAGMENT="$ROOT_DIR/commands/signum.fragments/90-phase-audit.md"
OVERLAY_FRAGMENT="$ROOT_DIR/platforms/claude-code/commands/signum.fragments/90-phase-audit.md"
ROOT_COMMAND="$ROOT_DIR/commands/signum.md"
OVERLAY_COMMAND="$ROOT_DIR/platforms/claude-code/commands/signum.md"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/basic-mixed"
CONTRACTS="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts"
WORK="$(mktemp -d)"
STEP_SCRIPT="$WORK/reuse-and-duplication-audit-step.sh"
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

check_audit_surface() {
  local file="$1" label="$2"

  assert_order "$file" \
    '### Step 3.1.3: Policy scanner' \
    '### Step 3.1.4: REUSE_AND_DUPLICATION_AUDIT' \
    '### Step 3.1.5: Holdout validation' \
    "$label inserts duplicate audit after policy and before holdout"
  assert_contains "$file" 'REUSE_AND_DUPLICATION_AUDIT' "$label names duplicate audit step"
  assert_contains "$file" 'scripts/audit_codebase_reuse.py' "$label runs duplicate audit script"
  assert_contains "$file" 'CODEBASE_INDEX_PATH=".signum/cache/codebase-index-v1.json"' "$label uses project codebase index cache"
  assert_contains "$file" 'STYLE_PROFILE_PATH=".signum/cache/style-profile-v1.json"' "$label uses project style profile cache"
  assert_contains "$file" 'COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"' "$label uses active-root combined patch"
  assert_contains "$file" 'REUSE_CANDIDATES_PATH="${ARTIFACT_ROOT}reuse_candidates.json"' "$label uses active-root reuse candidates"
  assert_contains "$file" 'REUSE_DECISION_PATH="${ARTIFACT_ROOT}reuse_decision.json"' "$label uses active-root reuse decision"
  assert_contains "$file" 'DUPLICATE_SCAN_PATH="${ARTIFACT_ROOT}duplicate_scan.json"' "$label writes active-root duplicate scan"
  assert_contains "$file" '--style-profile "$STYLE_PROFILE_PATH"' "$label passes style profile"
  assert_contains "$file" '--implementation-context "$IMPLEMENTATION_CONTEXT_PATH"' "$label passes implementation context"
  assert_contains "$file" 'continuing AUDIT' "$label hint/warn failures continue"
  assert_contains "$file" 'failed in gate mode' "$label gate failure blocks"
  case "$label" in
    *fragment)
      assert_not_contains "$file" 'reuse_summary.json' "$label does not produce reuse summary"
      ;;
  esac
}

extract_audit_step() {
  python3 - "$ROOT_FRAGMENT" "$STEP_SCRIPT" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
output = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")
heading = "### Step 3.1.4: REUSE_AND_DUPLICATION_AUDIT"
start = text.index(heading)
code_start = text.index("```bash", start) + len("```bash")
code_end = text.index("```", code_start)
output.write_text(text[code_start:code_end].lstrip(), encoding="utf-8")
PY
  if bash -n "$STEP_SCRIPT"; then
    pass "extracted REUSE_AND_DUPLICATION_AUDIT is valid bash"
  else
    fail "extracted REUSE_AND_DUPLICATION_AUDIT is valid bash" "bash -n failed"
  fi
  assert_not_contains "$STEP_SCRIPT" "AUTO_OK" "duplicate audit block does not emit AUTO_OK"
  assert_not_contains "$STEP_SCRIPT" "AUTO_BLOCK" "duplicate audit block does not emit AUTO_BLOCK"
  assert_not_contains "$STEP_SCRIPT" "HUMAN_REVIEW" "duplicate audit block does not emit HUMAN_REVIEW"
  assert_not_contains "$STEP_SCRIPT" "reuse_summary.json" "duplicate audit block does not write reuse summary"
  assert_not_contains "$STEP_SCRIPT" "proofpack" "duplicate audit block does not touch proofpack"
}

setup_project() {
  local project="$1"
  mkdir -p "$(dirname "$project")"
  cp -R "$FIXTURE" "$project"
  mkdir -p "$project/scripts" "$project/lib" "$project/.signum/contracts/example"
  cp "$ROOT_DIR/scripts/audit_codebase_reuse.py" "$project/scripts/audit_codebase_reuse.py"
  cp -R "$ROOT_DIR/scripts/codebase_awareness" "$project/scripts/codebase_awareness"
  cp "$ROOT_DIR/lib/contract-dir.sh" "$project/lib/contract-dir.sh"
  cp "$CONTRACTS/validation-contract.json" "$project/.signum/contracts/example/contract.json"
  cp "$CONTRACTS/validation-contract-engineer.json" "$project/.signum/contracts/example/contract-engineer.json"
  cat > "$project/.signum/contracts/index.json" <<'JSON'
{"activeContractId":"example","contracts":[{"contractId":"example","status":"active","directory":".signum/contracts/example/"}]}
JSON
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-v1.json" \
      --style-output ".signum/cache/style-profile-v1.json" \
      --generated-at "2026-01-01T00:00:00Z"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/example/contract.json" \
      --contract-engineer ".signum/contracts/example/contract-engineer.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/example/reuse_candidates.json" \
      --implementation-context ".signum/contracts/example/implementation_context.json" \
      --max-candidates 8 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

write_patch() {
  local project="$1"
  cat > "$project/.signum/contracts/example/combined.patch" <<'PATCH'
diff --git a/src/features/signup.ts b/src/features/signup.ts
index 1111111..2222222 100644
--- a/src/features/signup.ts
+++ b/src/features/signup.ts
@@ -1,3 +1,12 @@
+function isValidEmailAddress(email: string) {
+  const normalized = email.trim().toLowerCase();
+  if (!normalized.includes("@")) {
+    return { ok: false, reason: "missing-at-sign" };
+  }
+  return { ok: true };
+}
+
+export const signupValidationMode = "strict";
 export function createSignupPayload(email: string) {
   return { email };
 }
PATCH
}

write_valid_decision() {
  local project="$1"
  cat > "$project/.signum/contracts/example/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "gate",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "reuse",
      "action": "Call existing validateEmail helper",
      "rationale": "Candidate matches task intent and is already used by sibling signup flow."
    }
  ],
  "newCodeJustifications": [],
  "summary": "Reused existing validation helper and followed existing test pattern."
}
JSON
}

run_step() {
  local project="$1" mode="$2" output="$3"
  (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS="$mode" bash "$STEP_SCRIPT"
  ) >"$output" 2>&1
}

assert_duplicate_scan() {
  local project="$1" label="$2"
  if python3 - "$project/.signum/contracts/example/duplicate_scan.json" <<'PY'; then
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
if report.get("schemaVersion") != "1.0":
    raise SystemExit(1)
if report.get("recommendedOutcome") not in {"clean", "informational", "review-recommended"}:
    raise SystemExit(1)
if any(token in json.dumps(report, sort_keys=True) for token in ("AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW")):
    raise SystemExit(1)
PY
    pass "$label creates valid duplicate scan"
  else
    fail "$label creates valid duplicate scan" "missing or invalid duplicate_scan.json"
  fi
  assert_missing "$project/.signum/contracts/example/reuse_summary.json" "$label does not produce reuse summary"
}

run_valid_mode_fixture() {
  local mode="$1"
  local project="$WORK/$mode-valid/basic-mixed"
  local output="$WORK/$mode-valid.out"
  setup_project "$project"
  write_patch "$project"
  write_valid_decision "$project"

  if run_step "$project" "$mode" "$output"; then
    pass "$mode duplicate audit exits 0"
  else
    fail "$mode duplicate audit exits 0" "$(cat "$output")"
    return
  fi
  assert_contains "$output" "REUSE_AND_DUPLICATION_AUDIT: mode=$mode" "$mode reports duplicate audit mode"
  assert_duplicate_scan "$project" "$mode"
}

run_off_fixture() {
  local project="$WORK/off/basic-mixed"
  local output="$WORK/off.out"
  setup_project "$project"
  write_patch "$project"
  write_valid_decision "$project"

  if run_step "$project" off "$output"; then
    pass "off duplicate audit exits 0"
  else
    fail "off duplicate audit exits 0" "$(cat "$output")"
    return
  fi
  assert_contains "$output" "REUSE_AND_DUPLICATION_AUDIT: skipped" "off reports skip"
  assert_missing "$project/.signum/contracts/example/duplicate_scan.json" "off does not create duplicate scan"
  assert_missing "$project/.signum/contracts/example/reuse_summary.json" "off does not create reuse summary"
}

run_warn_missing_decision_fixture() {
  local project="$WORK/warn-missing-decision/basic-mixed"
  local output="$WORK/warn-missing-decision.out"
  setup_project "$project"
  write_patch "$project"
  rm -f "$project/.signum/contracts/example/reuse_decision.json"

  if run_step "$project" warn "$output"; then
    pass "warn missing decision exits 0"
  else
    fail "warn missing decision exits 0" "$(cat "$output")"
    return
  fi
  if python3 - "$project/.signum/contracts/example/duplicate_scan.json" <<'PY'; then
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text()).get("decisionStatus", {})
if status.get("present") is not False:
    raise SystemExit(1)
PY
    pass "warn missing decision writes degraded decisionStatus"
  else
    fail "warn missing decision writes degraded decisionStatus" "decisionStatus.present was not false"
  fi
  assert_missing "$project/.signum/contracts/example/reuse_summary.json" "warn missing decision does not create reuse summary"
}

run_gate_missing_decision_fixture() {
  local project="$WORK/gate-missing-decision/basic-mixed"
  local output="$WORK/gate-missing-decision.out"
  local actual=0
  setup_project "$project"
  write_patch "$project"
  rm -f "$project/.signum/contracts/example/reuse_decision.json"

  if run_step "$project" gate "$output"; then
    actual=0
  else
    actual=$?
  fi
  if [ "$actual" -eq 2 ]; then
    pass "gate missing decision exits 2"
  else
    fail "gate missing decision exits 2" "got $actual; output=$(cat "$output")"
  fi
}

run_failure_fixture() {
  local mode="$1" expected="$2"
  local project="$WORK/$mode-failure/basic-mixed"
  local output="$WORK/$mode-failure.out"
  local actual=0
  setup_project "$project"
  write_patch "$project"
  write_valid_decision "$project"
  rm -f "$project/.signum/cache/codebase-index-v1.json"

  if run_step "$project" "$mode" "$output"; then
    actual=0
  else
    actual=$?
  fi
  if [ "$actual" -eq "$expected" ]; then
    pass "$mode script failure exits $expected"
  else
    fail "$mode script failure exits $expected" "got $actual; output=$(cat "$output")"
  fi
  if [ "$mode" = "gate" ]; then
    assert_contains "$output" "failed in gate mode" "gate failure reports blocking error"
  else
    assert_contains "$output" "continuing AUDIT" "$mode failure reports warning and continuation"
  fi
}

echo "=== AUDIT surface checks ==="
check_audit_surface "$ROOT_FRAGMENT" "root fragment"
check_audit_surface "$OVERLAY_FRAGMENT" "Claude overlay fragment"
check_audit_surface "$ROOT_COMMAND" "root rendered command"
check_audit_surface "$OVERLAY_COMMAND" "Claude overlay rendered command"
extract_audit_step

echo ""
echo "=== Runtime fixtures ==="
run_off_fixture
run_valid_mode_fixture hint
run_valid_mode_fixture warn
run_warn_missing_decision_fixture
run_valid_mode_fixture gate
run_gate_missing_decision_fixture
run_failure_fixture hint 0
run_failure_fixture warn 0
run_failure_fixture gate 2

echo ""
printf "Passed: %s\n" "$passed"
printf "Failed: %s\n" "$failed"

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
