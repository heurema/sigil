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

  assert_contains "$file" 'CODEBASE_RECON' "$label names CODEBASE_RECON"
  assert_contains "$file" 'REUSE_MATCH' "$label names REUSE_MATCH"
  assert_contains "$file" 'scripts/build_codebase_index.py' "$label runs codebase scanner"
  assert_contains "$file" 'scripts/build_reuse_candidates.py' "$label runs reuse matcher"
  assert_contains "$file" '--style-output "$STYLE_PROFILE_PATH"' "$label uses canonical scanner style output flag"
  assert_contains "$file" '--style-profile "$STYLE_PROFILE_PATH"' "$label uses canonical matcher style input flag"
  assert_contains "$file" 'CODEBASE_INDEX_PATH=".signum/cache/codebase-index-v1.json"' "$label writes canonical codebase index cache"
  assert_contains "$file" 'STYLE_PROFILE_PATH=".signum/cache/style-profile-v1.json"' "$label writes canonical style profile cache"
  assert_contains "$file" 'IMPLEMENTATION_CONTEXT_PATH="${ARTIFACT_ROOT}implementation_context.json"' "$label writes implementation context under active artifact root"
  assert_contains "$file" 'REUSE_CANDIDATES_PATH="${ARTIFACT_ROOT}reuse_candidates.json"' "$label writes reuse candidates under active artifact root"
  assert_contains "$file" 'CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"' "$label resolves contract from active artifact root"
  assert_contains "$file" 'CONTRACT_ENGINEER_PATH="${ARTIFACT_ROOT}contract-engineer.json"' "$label resolves optional engineer contract"
  assert_contains "$file" '--contract-engineer "$CONTRACT_ENGINEER_PATH"' "$label passes contract-engineer only when present"
  assert_contains "$file" 'SIGNUM_CODEBASE_AWARENESS' "$label recognizes awareness mode env var"
  assert_contains "$file" 'SIGNUM_CODEBASE_MAX_CANDIDATES' "$label recognizes candidate limit env var"
  assert_contains "$file" 'codebase_awareness' "$label supports policy section"
  assert_contains "$file" 'max_candidates_in_prompt' "$label supports policy max candidates"
  assert_contains "$file" 'CODEBASE_AWARENESS_MODE="${SIGNUM_CODEBASE_AWARENESS:-${_POLICY_CODEBASE_MODE:-off}}"' "$label defaults mode to off"
  assert_contains "$file" 'off|hint|warn|gate)' "$label recognizes PR1C modes"
  assert_contains "$file" 'warn" ] || [ "$CODEBASE_AWARENESS_MODE" = "gate"' "$label treats warn/gate as hint-only"
  assert_contains "$file" 'continuing EXECUTE without Codebase Awareness hints' "$label scanner and matcher failures are non-blocking"
  assert_not_contains "$file" 'reuse_decision.json' "$label does not add reuse decision artifact"
  assert_not_contains "$file" 'duplicate_scan.json' "$label does not add duplicate scan artifact"
  assert_not_contains "$file" 'reuse_summary.json' "$label does not add reuse summary artifact"
}

extract_codebase_awareness_step() {
  local file="$1"
  local output="$2"
  python3 - "$file" "$output" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
output = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")
heading = "### Step 2.0.6: Codebase Awareness hint context"
start = text.index(heading)
code_start = text.index("```bash", start) + len("```bash")
code_end = text.index("```", code_start)
output.write_text(text[code_start:code_end].lstrip(), encoding="utf-8")
PY
}

run_hint_fixture() {
  local step_script="$WORK/codebase-awareness-step.sh"
  local project="$WORK/basic-mixed"
  extract_codebase_awareness_step "$ROOT_FRAGMENT" "$step_script"
  bash -n "$step_script"

  cp -R "$FIXTURE" "$project"
  mkdir -p "$project/scripts" "$project/lib" "$project/.signum/contracts/example"
  cp "$ROOT_DIR/scripts/build_codebase_index.py" "$project/scripts/build_codebase_index.py"
  cp "$ROOT_DIR/scripts/build_reuse_candidates.py" "$project/scripts/build_reuse_candidates.py"
  cp -R "$ROOT_DIR/scripts/codebase_awareness" "$project/scripts/codebase_awareness"
  cp "$ROOT_DIR/lib/contract-dir.sh" "$project/lib/contract-dir.sh"
  cp "$CONTRACTS/validation-contract.json" "$project/.signum/contracts/example/contract.json"
  cp "$CONTRACTS/validation-contract-engineer.json" "$project/.signum/contracts/example/contract-engineer.json"
  cat > "$project/.signum/contracts/index.json" <<'JSON'
{"activeContractId":"example","contracts":[{"contractId":"example","status":"active","directory":".signum/contracts/example/"}]}
JSON

  if (
    cd "$project"
    SIGNUM_CODEBASE_AWARENESS=hint \
      SIGNUM_CODEBASE_MAX_CANDIDATES=5 \
      bash "$step_script"
  ); then
    pass "hint-mode fixture executes Step 2.0.6"
  else
    fail "hint-mode fixture executes Step 2.0.6" "command failed"
    return
  fi

  assert_contains "$project/.signum/cache/codebase-index-v1.json" '"schemaVersion"' "hint fixture creates project codebase index"
  assert_contains "$project/.signum/cache/style-profile-v1.json" '"schemaVersion"' "hint fixture creates project style profile"
  assert_contains "$project/.signum/contracts/example/implementation_context.json" '"schemaVersion"' "hint fixture creates implementation context"
  assert_contains "$project/.signum/contracts/example/reuse_candidates.json" '"maxCandidates": 5' "hint fixture respects max candidates env var"
}

echo "=== EXECUTE Codebase Awareness wiring ==="
check_execute_surface "$ROOT_FRAGMENT" "root fragment"
check_execute_surface "$OVERLAY_FRAGMENT" "Claude overlay fragment"
check_execute_surface "$ROOT_COMMAND" "root rendered command"
check_execute_surface "$OVERLAY_COMMAND" "Claude overlay rendered command"

echo ""
echo "=== Hint-mode fixture ==="
run_hint_fixture

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Codebase Awareness EXECUTE wiring is present and hint-only"
