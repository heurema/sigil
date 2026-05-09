#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
ROOT_FRAGMENT="$ROOT_DIR/commands/signum.fragments/80-phase-execute.md"
OVERLAY_FRAGMENT="$ROOT_DIR/platforms/claude-code/commands/signum.fragments/80-phase-execute.md"
ROOT_COMMAND="$ROOT_DIR/commands/signum.md"
OVERLAY_COMMAND="$ROOT_DIR/platforms/claude-code/commands/signum.md"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/basic-mixed"
CONTRACTS="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts"
WORK="$(mktemp -d)"
STEP_SCRIPT="$WORK/codebase-awareness-step.sh"
VALIDATION_SCRIPT="$WORK/reuse-decision-validation-step.sh"
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
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label" "missing $needle"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$label" "unexpected $needle"
  else
    pass "$label"
  fi
}

assert_execute_section_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if python3 - "$file" "$needle" <<'PY'; then
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
needle = sys.argv[2]
start = text.find("## Phase 2: EXECUTE")
end = text.find("## Phase 3: AUDIT")
if start >= 0 and end > start:
    text = text[start:end]
if needle in text:
    raise SystemExit(1)
PY
    pass "$label"
  else
    fail "$label" "unexpected $needle in EXECUTE section"
  fi
}

assert_missing() {
  local path="$1"
  local label="$2"
  if [ -e "$path" ]; then
    fail "$label" "unexpected $path"
  else
    pass "$label"
  fi
}

assert_order() {
  local file="$1"
  local before="$2"
  local marker="$3"
  local after="$4"
  local label="$5"
  if python3 - "$file" "$before" "$marker" "$after" <<'PY'; then
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
positions = [text.find(item) for item in sys.argv[2:]]
if any(pos < 0 for pos in positions):
    raise SystemExit(1)
if positions != sorted(positions):
    raise SystemExit(1)
PY
    pass "$label"
  else
    fail "$label" "markers are missing or out of order"
  fi
}

check_execute_surface() {
  local file="$1"
  local label="$2"

  assert_order "$file" \
    '### Step 2.0.5: Capture pre-execute snapshot (receipt chain)' \
    '### Step 2.0.6: Codebase Awareness hint context' \
    '### Step 2.1: Launch Engineer' \
    "$label inserts Codebase Awareness before engineer launch"

  assert_order "$file" \
    '### Step 2.1: Launch Engineer' \
    '### Step 2.1.5: Validate Codebase Awareness reuse decision' \
    '### Step 2.2: Check result' \
    "$label validates reuse decision after engineer and before execute checks"

  assert_contains "$file" 'CODEBASE_RECON' "$label names CODEBASE_RECON"
  assert_contains "$file" 'REUSE_MATCH' "$label names REUSE_MATCH"
  assert_contains "$file" 'scripts/build_codebase_index.py' "$label runs codebase scanner"
  assert_contains "$file" 'scripts/build_reuse_candidates.py' "$label runs reuse matcher"
  assert_contains "$file" '--style-output "$STYLE_PROFILE_PATH"' "$label uses canonical scanner style output flag"
  assert_contains "$file" '--digests-output "$FILE_DIGESTS_PATH"' "$label writes scanner digest cache"
  assert_contains "$file" '--previous-digests "$FILE_DIGESTS_PATH"' "$label reuses previous digest input when present"
  assert_contains "$file" '--style-profile "$STYLE_PROFILE_PATH"' "$label uses canonical matcher style input flag"
  assert_contains "$file" 'CODEBASE_INDEX_PATH=".signum/cache/codebase-index-v1.json"' "$label writes canonical codebase index cache"
  assert_contains "$file" 'STYLE_PROFILE_PATH=".signum/cache/style-profile-v1.json"' "$label writes canonical style profile cache"
  assert_contains "$file" 'FILE_DIGESTS_PATH=".signum/cache/file-digests-v1.json"' "$label writes canonical file digest cache"
  assert_contains "$file" 'IMPLEMENTATION_CONTEXT_PATH="${ARTIFACT_ROOT}implementation_context.json"' "$label writes implementation context under active artifact root"
  assert_contains "$file" 'REUSE_CANDIDATES_PATH="${ARTIFACT_ROOT}reuse_candidates.json"' "$label writes reuse candidates under active artifact root"
  assert_contains "$file" 'REUSE_DECISION_PATH="${ARTIFACT_ROOT}reuse_decision.json"' "$label resolves reuse decision under active artifact root"
  assert_contains "$file" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label resolves contract from active artifact root"
  assert_contains "$file" 'CONTRACT_ENGINEER_PATH="${ARTIFACT_ROOT}contract-engineer.json"' "$label resolves optional engineer contract"
  assert_contains "$file" '--contract-engineer "$CONTRACT_ENGINEER_PATH"' "$label passes contract-engineer only when present"
  assert_contains "$file" 'SIGNUM_CODEBASE_AWARENESS' "$label recognizes awareness mode env var"
  assert_contains "$file" 'SIGNUM_CODEBASE_MAX_CANDIDATES' "$label recognizes candidate limit env var"
  assert_contains "$file" 'codebase_awareness' "$label supports policy section"
  assert_contains "$file" 'max_candidates_in_prompt' "$label supports policy max candidates"
  assert_contains "$file" 'CODEBASE_AWARENESS_MODE="${SIGNUM_CODEBASE_AWARENESS:-${_POLICY_CODEBASE_MODE:-off}}"' "$label defaults mode to off"
  assert_contains "$file" 'CODEBASE_MAX_CANDIDATES="${SIGNUM_CODEBASE_MAX_CANDIDATES:-${_POLICY_CODEBASE_MAX_CANDIDATES:-8}}"' "$label lets env override policy candidate limit"
  assert_contains "$file" 'off|hint|warn|gate)' "$label recognizes Codebase Awareness modes"
  assert_contains "$file" 'warn" ] || [ "$CODEBASE_AWARENESS_MODE" = "gate"' "$label announces warn/gate validation"
  assert_contains "$file" 'continuing EXECUTE without Codebase Awareness hints' "$label scanner and matcher failures are non-blocking"
  assert_contains "$file" 'scripts/validate_reuse_decision.py' "$label runs reuse decision validator"
  assert_contains "$file" 'continuing because mode is warn' "$label warn validation is non-blocking"
  assert_contains "$file" 'Codebase Awareness gate mode blocks EXECUTE' "$label gate validation blocks"
  assert_execute_section_not_contains "$file" 'duplicate_scan.json' "$label does not add duplicate scan artifact to EXECUTE"
  assert_execute_section_not_contains "$file" 'reuse_summary.json' "$label does not add reuse summary artifact to EXECUTE"
}

extract_bash_step() {
  local file="$1"
  local heading="$2"
  local output="$3"
  python3 - "$file" "$heading" "$output" <<'PY'
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

prepare_step_script() {
  extract_bash_step "$ROOT_FRAGMENT" "### Step 2.0.6: Codebase Awareness hint context" "$STEP_SCRIPT"
  if bash -n "$STEP_SCRIPT"; then
    pass "extracted Step 2.0.6 is valid bash"
  else
    fail "extracted Step 2.0.6 is valid bash" "bash -n failed"
    return 1
  fi
  assert_not_contains "$STEP_SCRIPT" "AUTO_BLOCK" "extracted Step 2.0.6 does not block verdicts"
  assert_not_contains "$STEP_SCRIPT" "HUMAN_REVIEW" "extracted Step 2.0.6 does not cap verdicts"
}

prepare_validation_script() {
  extract_bash_step "$ROOT_FRAGMENT" "### Step 2.1.5: Validate Codebase Awareness reuse decision" "$VALIDATION_SCRIPT"
  if bash -n "$VALIDATION_SCRIPT"; then
    pass "extracted Step 2.1.5 is valid bash"
  else
    fail "extracted Step 2.1.5 is valid bash" "bash -n failed"
    return 1
  fi
  assert_not_contains "$VALIDATION_SCRIPT" "AUTO_BLOCK" "extracted Step 2.1.5 does not set final verdict"
  assert_not_contains "$VALIDATION_SCRIPT" "HUMAN_REVIEW" "extracted Step 2.1.5 does not cap verdicts"
}

setup_fixture_project() {
  local project="$1"
  cp -R "$FIXTURE" "$project"
  mkdir -p "$project/scripts" "$project/lib" "$project/.signum/contracts/example"
  cp "$ROOT_DIR/scripts/build_codebase_index.py" "$project/scripts/build_codebase_index.py"
  cp "$ROOT_DIR/scripts/build_reuse_candidates.py" "$project/scripts/build_reuse_candidates.py"
  cp "$ROOT_DIR/scripts/validate_reuse_decision.py" "$project/scripts/validate_reuse_decision.py"
  cp -R "$ROOT_DIR/scripts/codebase_awareness" "$project/scripts/codebase_awareness"
  cp "$ROOT_DIR/lib/contract-dir.sh" "$project/lib/contract-dir.sh"
  cp "$CONTRACTS/validation-contract.json" "$project/.signum/contracts/example/contract.json"
  cp "$CONTRACTS/validation-contract-engineer.json" "$project/.signum/contracts/example/contract-engineer.json"
  cat > "$project/.signum/contracts/index.json" <<'JSON'
{"activeContractId":"example","contracts":[{"contractId":"example","status":"active","directory":".signum/contracts/example/"}]}
JSON
}

assert_pr1c_artifacts_present() {
  local project="$1"
  local label="$2"

  assert_contains "$project/.signum/cache/codebase-index-v1.json" '"schemaVersion"' "$label creates project codebase index"
  assert_contains "$project/.signum/cache/style-profile-v1.json" '"schemaVersion"' "$label creates project style profile"
  assert_contains "$project/.signum/cache/file-digests-v1.json" '"schemaVersion"' "$label creates project file digest cache"
  assert_contains "$project/.signum/contracts/example/implementation_context.json" '"schemaVersion"' "$label creates implementation context"
  assert_contains "$project/.signum/contracts/example/reuse_candidates.json" '"schemaVersion"' "$label creates reuse candidates"
}

assert_pr1c_artifacts_absent() {
  local project="$1"
  local label="$2"

  assert_missing "$project/.signum/cache/codebase-index-v1.json" "$label does not create project codebase index"
  assert_missing "$project/.signum/cache/style-profile-v1.json" "$label does not create project style profile"
  assert_missing "$project/.signum/cache/file-digests-v1.json" "$label does not create project file digest cache"
  assert_missing "$project/.signum/contracts/example/implementation_context.json" "$label does not create implementation context"
  assert_missing "$project/.signum/contracts/example/reuse_candidates.json" "$label does not create reuse candidates"
}

assert_future_artifacts_absent() {
  local project="$1"
  local label="$2"

  assert_missing "$project/.signum/contracts/example/duplicate_scan.json" "$label does not create duplicate scan"
  assert_missing "$project/.signum/contracts/example/reuse_summary.json" "$label does not create reuse summary"
}

write_valid_reuse_decision() {
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

write_invalid_reuse_decision() {
  local project="$1"
  cat > "$project/.signum/contracts/example/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "decisions": [
    {
      "candidateId": "cand-999",
      "disposition": "reuse",
      "action": "Call missing helper",
      "rationale": "This candidate does not exist."
    }
  ],
  "summary": "Invalid candidate reference."
}
JSON
}

run_unset_fixture() {
  local project="$WORK/basic-mixed-unset"
  local output="$WORK/basic-mixed-unset.out"
  setup_fixture_project "$project"

  if (
    cd "$project"
    unset SIGNUM_CODEBASE_AWARENESS SIGNUM_CODEBASE_MAX_CANDIDATES
    bash "$STEP_SCRIPT"
  ) >"$output" 2>&1; then
    pass "unset mode fixture executes Step 2.0.6"
  else
    fail "unset mode fixture executes Step 2.0.6" "command failed"
    return
  fi

  assert_contains "$output" "Codebase Awareness: off (skipping CODEBASE_RECON and REUSE_MATCH)" "unset mode reports scanner/matcher skip"
  assert_pr1c_artifacts_absent "$project" "unset mode"
  assert_future_artifacts_absent "$project" "unset mode"
}

run_off_fixture() {
  local project="$WORK/basic-mixed-off"
  local output="$WORK/basic-mixed-off.out"
  setup_fixture_project "$project"
  cat > "$project/.signum/policy.toml" <<'TOML'
[codebase_awareness]
mode = "hint"
max_candidates_in_prompt = 3
TOML

  if (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS=off bash "$STEP_SCRIPT"
  ) >"$output" 2>&1; then
    pass "off-mode fixture executes Step 2.0.6"
  else
    fail "off-mode fixture executes Step 2.0.6" "command failed"
    return
  fi

  assert_contains "$output" "Codebase Awareness: off (skipping CODEBASE_RECON and REUSE_MATCH)" "off mode reports scanner/matcher skip"
  assert_pr1c_artifacts_absent "$project" "off mode"
  assert_future_artifacts_absent "$project" "off mode"
}

run_hint_fixture() {
  local project="$WORK/basic-mixed-hint"
  local output="$WORK/basic-mixed-hint.out"
  setup_fixture_project "$project"

  if (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS=hint \
      SIGNUM_CODEBASE_MAX_CANDIDATES=5 \
      bash "$STEP_SCRIPT"
  ) >"$output" 2>&1; then
    pass "hint-mode fixture executes Step 2.0.6"
  else
    fail "hint-mode fixture executes Step 2.0.6" "command failed"
    return
  fi

  assert_pr1c_artifacts_present "$project" "hint mode"
  assert_contains "$project/.signum/contracts/example/reuse_candidates.json" '"maxCandidates": 5' "hint fixture respects max candidates env var"
  assert_future_artifacts_absent "$project" "hint mode"
}

run_warn_gate_fixture() {
  local mode="$1"
  local project="$WORK/basic-mixed-$mode"
  local output="$WORK/basic-mixed-$mode.out"
  setup_fixture_project "$project"

  if (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS="$mode" bash "$STEP_SCRIPT"
  ) >"$output" 2>&1; then
    pass "$mode-mode fixture executes Step 2.0.6"
  else
    fail "$mode-mode fixture executes Step 2.0.6" "command failed"
    return
  fi

  assert_contains "$output" "NOTE: Codebase Awareness $mode will validate" "$mode mode reports post-engineer validation note"
  assert_pr1c_artifacts_present "$project" "$mode mode"
  assert_future_artifacts_absent "$project" "$mode mode"
  assert_not_contains "$output" "AUTO_BLOCK" "$mode mode does not cap verdict"
}

prepare_validation_project() {
  local project="$1"
  local mode="$2"
  local output="$3"
  setup_fixture_project "$project"

  if (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS="$mode" bash "$STEP_SCRIPT"
  ) >"$output.context" 2>&1; then
    pass "$mode validation fixture creates Codebase Awareness context"
  else
    fail "$mode validation fixture creates Codebase Awareness context" "context command failed"
    return 1
  fi

  assert_pr1c_artifacts_present "$project" "$mode validation fixture"
}

run_validation_step() {
  local project="$1"
  local mode="$2"
  local output="$3"
  (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS="$mode" bash "$VALIDATION_SCRIPT"
  ) >"$output" 2>&1
}

run_hint_validation_missing_decision_fixture() {
  local project="$WORK/validate-hint-missing"
  local output="$WORK/validate-hint-missing.out"
  prepare_validation_project "$project" hint "$output" || return

  if run_validation_step "$project" hint "$output"; then
    pass "hint validation without reuse_decision continues"
  else
    fail "hint validation without reuse_decision continues" "command failed"
    return
  fi

  assert_contains "$output" "hint mode and no reuse_decision.json found; skipping validation" "hint missing decision skips validation"
  assert_future_artifacts_absent "$project" "hint validation"
}

run_hint_validation_invalid_decision_fixture() {
  local project="$WORK/validate-hint-invalid"
  local output="$WORK/validate-hint-invalid.out"
  prepare_validation_project "$project" hint "$output" || return
  write_invalid_reuse_decision "$project"

  if run_validation_step "$project" hint "$output"; then
    pass "hint validation with invalid reuse_decision continues"
  else
    fail "hint validation with invalid reuse_decision continues" "command failed"
    return
  fi

  assert_contains "$output" "WARNING: optional REUSE_DECISION validation failed with exit 4; continuing because mode is hint" "hint invalid decision emits optional warning"
  assert_future_artifacts_absent "$project" "hint invalid validation"
}

run_off_validation_skips_fixture() {
  local project="$WORK/validate-off-skips"
  local output="$WORK/validate-off-skips.out"
  setup_fixture_project "$project"
  write_invalid_reuse_decision "$project"

  if run_validation_step "$project" off "$output"; then
    pass "off validation skips reuse_decision checks"
  else
    fail "off validation skips reuse_decision checks" "command failed"
    return
  fi

  assert_contains "$output" "Codebase Awareness reuse decision validation: off" "off validation reports skip"
  assert_future_artifacts_absent "$project" "off validation"
}

run_warn_validation_missing_decision_fixture() {
  local project="$WORK/validate-warn-missing"
  local output="$WORK/validate-warn-missing.out"
  prepare_validation_project "$project" warn "$output" || return

  if run_validation_step "$project" warn "$output"; then
    pass "warn validation with missing reuse_decision continues"
  else
    fail "warn validation with missing reuse_decision continues" "command failed"
    return
  fi

  assert_contains "$output" "WARNING: REUSE_DECISION validation failed with exit 2; continuing because mode is warn" "warn missing decision emits warning"
  assert_future_artifacts_absent "$project" "warn missing validation"
}

run_warn_validation_invalid_decision_fixture() {
  local project="$WORK/validate-warn-invalid"
  local output="$WORK/validate-warn-invalid.out"
  prepare_validation_project "$project" warn "$output" || return
  write_invalid_reuse_decision "$project"

  if run_validation_step "$project" warn "$output"; then
    pass "warn validation with invalid reuse_decision continues"
  else
    fail "warn validation with invalid reuse_decision continues" "command failed"
    return
  fi

  assert_contains "$output" "WARNING: REUSE_DECISION validation failed with exit 4; continuing because mode is warn" "warn invalid decision emits warning"
  assert_future_artifacts_absent "$project" "warn invalid validation"
}

run_gate_validation_missing_decision_fixture() {
  local project="$WORK/validate-gate-missing"
  local output="$WORK/validate-gate-missing.out"
  local actual=0
  prepare_validation_project "$project" gate "$output" || return

  if run_validation_step "$project" gate "$output"; then
    actual=0
  else
    actual=$?
  fi

  if [ "$actual" -eq 2 ]; then
    pass "gate validation blocks missing reuse_decision"
  else
    fail "gate validation blocks missing reuse_decision" "expected exit 2, got $actual"
  fi
  assert_contains "$output" "Codebase Awareness gate mode blocks EXECUTE" "gate missing decision emits blocking error"
  assert_future_artifacts_absent "$project" "gate missing validation"
}

run_gate_validation_invalid_decision_fixture() {
  local project="$WORK/validate-gate-invalid"
  local output="$WORK/validate-gate-invalid.out"
  local actual=0
  prepare_validation_project "$project" gate "$output" || return
  write_invalid_reuse_decision "$project"

  if run_validation_step "$project" gate "$output"; then
    actual=0
  else
    actual=$?
  fi

  if [ "$actual" -eq 4 ]; then
    pass "gate validation blocks invalid reuse_decision"
  else
    fail "gate validation blocks invalid reuse_decision" "expected exit 4, got $actual"
  fi
  assert_contains "$output" "Codebase Awareness gate mode blocks EXECUTE" "gate invalid decision emits blocking error"
  assert_future_artifacts_absent "$project" "gate invalid validation"
}

run_gate_validation_valid_decision_fixture() {
  local project="$WORK/validate-gate-valid"
  local output="$WORK/validate-gate-valid.out"
  prepare_validation_project "$project" gate "$output" || return
  write_valid_reuse_decision "$project"

  if run_validation_step "$project" gate "$output"; then
    pass "gate validation accepts valid reuse_decision"
  else
    fail "gate validation accepts valid reuse_decision" "command failed"
    return
  fi

  assert_contains "$output" "REUSE_DECISION: valid" "gate valid decision reports success"
  assert_future_artifacts_absent "$project" "gate valid validation"
}

run_gate_validation_missing_artifacts_fixture() {
  local project="$WORK/validate-gate-missing-artifacts"
  local output="$WORK/validate-gate-missing-artifacts.out"
  local actual=0
  setup_fixture_project "$project"

  if run_validation_step "$project" gate "$output"; then
    actual=0
  else
    actual=$?
  fi

  if [ "$actual" -eq 5 ]; then
    pass "gate validation blocks when reuse artifacts are missing"
  else
    fail "gate validation blocks when reuse artifacts are missing" "expected exit 5, got $actual"
  fi
  assert_contains "$output" "Required reuse-candidates JSON not found" "gate missing artifacts reports missing reuse candidates"
}

run_scanner_failure_fixture() {
  local project="$WORK/basic-mixed-scanner-failure"
  local output="$WORK/basic-mixed-scanner-failure.out"
  setup_fixture_project "$project"
  printf '%s\n' 'import sys' 'sys.exit(23)' > "$project/scripts/build_codebase_index.py"

  if (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS=hint bash "$STEP_SCRIPT"
  ) >"$output" 2>&1; then
    pass "hint-mode scanner failure fixture remains non-blocking"
  else
    fail "hint-mode scanner failure fixture remains non-blocking" "command failed"
    return
  fi

  assert_contains "$output" "WARNING: CODEBASE_RECON failed with exit 23; continuing EXECUTE without Codebase Awareness hints" "scanner failure emits non-blocking warning"
  assert_missing "$project/.signum/cache/codebase-index-v1.json" "scanner failure does not create codebase index"
  assert_missing "$project/.signum/contracts/example/reuse_candidates.json" "scanner failure does not run matcher"
}

run_matcher_failure_fixture() {
  local project="$WORK/basic-mixed-matcher-failure"
  local output="$WORK/basic-mixed-matcher-failure.out"
  setup_fixture_project "$project"
  printf '%s\n' 'import sys' 'sys.exit(24)' > "$project/scripts/build_reuse_candidates.py"

  if (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS=hint bash "$STEP_SCRIPT"
  ) >"$output" 2>&1; then
    pass "hint-mode matcher failure fixture remains non-blocking"
  else
    fail "hint-mode matcher failure fixture remains non-blocking" "command failed"
    return
  fi

  assert_contains "$output" "WARNING: REUSE_MATCH failed with exit 24; continuing EXECUTE without Codebase Awareness hints" "matcher failure emits non-blocking warning"
  assert_contains "$project/.signum/cache/codebase-index-v1.json" '"schemaVersion"' "matcher failure still creates project codebase index"
  assert_contains "$project/.signum/cache/style-profile-v1.json" '"schemaVersion"' "matcher failure still creates project style profile"
  assert_missing "$project/.signum/contracts/example/reuse_candidates.json" "matcher failure does not create reuse candidates"
}

echo "=== EXECUTE Codebase Awareness wiring ==="
check_execute_surface "$ROOT_FRAGMENT" "root fragment"
check_execute_surface "$OVERLAY_FRAGMENT" "Claude overlay fragment"
check_execute_surface "$ROOT_COMMAND" "root rendered command"
check_execute_surface "$OVERLAY_COMMAND" "Claude overlay rendered command"
assert_contains "$ROOT_DIR/lib/templates/policy.toml" 'mode = "off"' "policy template defaults Codebase Awareness to off"

echo ""
echo "=== Runtime mode fixtures ==="
prepare_step_script
prepare_validation_script
run_unset_fixture
run_off_fixture
run_hint_fixture
run_warn_gate_fixture warn
run_warn_gate_fixture gate

echo ""
echo "=== Reuse decision validation fixtures ==="
run_off_validation_skips_fixture
run_hint_validation_missing_decision_fixture
run_hint_validation_invalid_decision_fixture
run_warn_validation_missing_decision_fixture
run_warn_validation_invalid_decision_fixture
run_gate_validation_missing_decision_fixture
run_gate_validation_invalid_decision_fixture
run_gate_validation_valid_decision_fixture
run_gate_validation_missing_artifacts_fixture

echo ""
echo "=== Non-blocking failure fixtures ==="
run_scanner_failure_fixture
run_matcher_failure_fixture

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Codebase Awareness EXECUTE wiring validates reuse decisions for PR2A"
