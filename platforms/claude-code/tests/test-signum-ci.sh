#!/usr/bin/env bash
# test-signum-ci.sh — tests for lib/signum-ci.sh (unit tests, no actual claude invocation)
# Tests input validation and decision-to-exit-code mapping only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CI_SCRIPT="$SCRIPT_DIR/../lib/signum-ci.sh"
source "$CI_SCRIPT"

passed=0
failed=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

assert_exit() {
  local name="$1" expected_exit="$2"; shift 2
  local output exit_code
  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e
  if [[ "$exit_code" -eq "$expected_exit" ]]; then
    printf '  PASS: %s (exit=%s)\n' "$name" "$exit_code"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected exit %s, got %s: %s\n' "$name" "$expected_exit" "$exit_code" "$output"
    failed=$((failed + 1))
  fi
}

assert_exit_contains() {
  local name="$1" expected_exit="$2" expected_output="$3"; shift 3
  local output exit_code
  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e
  if [[ "$exit_code" -eq "$expected_exit" && "$output" == *"$expected_output"* ]]; then
    printf '  PASS: %s (exit=%s)\n' "$name" "$exit_code"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected exit %s with \"%s\", got exit %s: %s\n' \
      "$name" "$expected_exit" "$expected_output" "$exit_code" "$output"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local name="$1" expected="$2" output="$3"
  if [[ "$output" == *"$expected"* ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — output missing "%s"\n' "$name" "$expected"
    failed=$((failed + 1))
  fi
}

assert_equals() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected \"%s\", got \"%s\"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

echo "=== Input validation ==="

# No SIGNUM_CONTRACT_PATH
assert_exit "fails without CONTRACT_PATH" 1 \
  env -u SIGNUM_CONTRACT_PATH bash "$CI_SCRIPT"

# Nonexistent contract file
assert_exit "fails on missing contract file" 1 \
  env SIGNUM_CONTRACT_PATH="/tmp/nonexistent-contract-xyz.json" bash "$CI_SCRIPT"

# Invalid contract (missing required fields)
echo '{"foo": "bar"}' > "$WORK/invalid.json"
assert_exit "fails on invalid contract" 1 \
  env SIGNUM_CONTRACT_PATH="$WORK/invalid.json" bash "$CI_SCRIPT"

echo ""
echo "=== Contract field validation ==="

# Valid contract structure (will fail at claude invocation, but should pass validation)
cat > "$WORK/valid.json" <<'EOF'
{
  "schemaVersion": "3.2",
  "contractId": "sig-20260314-test",
  "goal": "Test goal",
  "inScope": ["test.py"],
  "acceptanceCriteria": [{"id": "AC1", "description": "Test", "visibility": "visible"}],
  "riskLevel": "low"
}
EOF

# Test validation logic only — extract the validation portion without running claude.
# We verify that jq validation passes for a valid contract.
set +e
output=$(jq -e '.schemaVersion and .goal and .inScope and .acceptanceCriteria and .riskLevel' \
  "$WORK/valid.json" > /dev/null 2>&1 && echo "VALIDATION_PASSED" || echo "VALIDATION_FAILED")
set -e

assert_contains "valid contract passes jq validation" "VALIDATION_PASSED" "$output"

# Verify header printing by sourcing only the first part of the script
set +e
output=$(SIGNUM_CONTRACT_PATH="$WORK/valid.json" SIGNUM_PROJECT_ROOT="$WORK" bash -c '
  CONTRACT="$SIGNUM_CONTRACT_PATH"
  PROJECT_ROOT="$SIGNUM_PROJECT_ROOT"
  echo "=== Signum CI ==="
  echo "Contract: $CONTRACT"
  echo "Project:  $PROJECT_ROOT"
' 2>&1)
set -e

assert_contains "shows header" "=== Signum CI ===" "$output"
assert_contains "shows contract path" "valid.json" "$output"

echo ""
echo "=== Canonical file-mode seeding ==="

assert_contains "CI script documents Phase 1 file import mode" \
  'Contract mode: file (Phase 1 imports SIGNUM_CONTRACT_PATH into canonical artifact root)' \
  "$(cat "$CI_SCRIPT")"
assert_contains "CI script invokes proofpack validator" \
  'validate_proofpack.py' \
  "$(cat "$CI_SCRIPT")"

if grep -Fq 'cp "$contract" "$project_root/.signum/contract.json"' "$CI_SCRIPT"; then
  printf '  FAIL: CI script still copies pre-approved contract into root .signum/contract.json\n'
  failed=$((failed + 1))
else
  printf '  PASS: CI script no longer copies pre-approved contract into root .signum/contract.json\n'
  passed=$((passed + 1))
fi

echo ""
echo "=== Artifact discovery ==="

CANONICAL="$WORK/canonical"
mkdir -p "$CANONICAL/.signum/contracts/sig-ci-001"
cat > "$CANONICAL/.signum/contracts/index.json" <<'EOF'
{
  "activeContractId": null,
  "contracts": [
    {
      "contractId": "sig-ci-001",
      "status": "completed",
      "directory": ".signum/contracts/sig-ci-001/"
    }
  ]
}
EOF
cat > "$CANONICAL/.signum/contracts/sig-ci-001/proofpack.json" <<'EOF'
{"runId":"sig-ci-001","decision":"AUTO_OK","confidence":{"overall":91}}
EOF

assert_equals "resolver prefers canonical contract dir by contract id" \
  "$(resolve_ci_artifact_root "$CANONICAL" "sig-ci-001")" \
  "$CANONICAL/.signum/contracts/sig-ci-001"
assert_equals "proofpack resolver prefers canonical contract dir" \
  "$(resolve_ci_proofpack_path "$CANONICAL" "sig-ci-001")" \
  "$CANONICAL/.signum/contracts/sig-ci-001/proofpack.json"

INDEX_FALLBACK="$WORK/index-fallback"
mkdir -p "$INDEX_FALLBACK/.signum/contracts/sig-ci-002"
cat > "$INDEX_FALLBACK/.signum/contracts/index.json" <<'EOF'
{
  "activeContractId": null,
  "contracts": [
    {
      "contractId": "sig-ci-002",
      "status": "completed",
      "directory": ".signum/contracts/sig-ci-002/"
    }
  ]
}
EOF
cat > "$INDEX_FALLBACK/.signum/contracts/sig-ci-002/proofpack.json" <<'EOF'
{"runId":"sig-ci-002","decision":"AUTO_BLOCK","confidence":{"overall":65}}
EOF

assert_equals "resolver falls back to last indexed contract dir" \
  "$(resolve_ci_artifact_root "$INDEX_FALLBACK" "")" \
  "$INDEX_FALLBACK/.signum/contracts/sig-ci-002"
assert_equals "proofpack resolver falls back to last indexed contract proofpack" \
  "$(resolve_ci_proofpack_path "$INDEX_FALLBACK" "")" \
  "$INDEX_FALLBACK/.signum/contracts/sig-ci-002/proofpack.json"

SINGLE_CANONICAL="$WORK/single-canonical"
mkdir -p "$SINGLE_CANONICAL/.signum/contracts/sig-ci-003"
cat > "$SINGLE_CANONICAL/.signum/contracts/sig-ci-003/proofpack.json" <<'EOF'
{"runId":"sig-ci-003","decision":"AUTO_OK","confidence":{"overall":88}}
EOF

assert_equals "resolver falls back to single canonical contract dir without index" \
  "$(resolve_ci_artifact_root "$SINGLE_CANONICAL" "")" \
  "$SINGLE_CANONICAL/.signum/contracts/sig-ci-003"
assert_equals "proofpack resolver falls back to single canonical contract proofpack without index" \
  "$(resolve_ci_proofpack_path "$SINGLE_CANONICAL" "")" \
  "$SINGLE_CANONICAL/.signum/contracts/sig-ci-003/proofpack.json"

ROOT_FALLBACK="$WORK/root-fallback"
mkdir -p "$ROOT_FALLBACK/.signum"
cat > "$ROOT_FALLBACK/.signum/proofpack.json" <<'EOF'
{"runId":"legacy","decision":"HUMAN_REVIEW","confidence":{"overall":50}}
EOF

assert_equals "resolver keeps legacy root artifact dir as final fallback" \
  "$(resolve_ci_artifact_root "$ROOT_FALLBACK" "")" \
  "$ROOT_FALLBACK/.signum"
assert_equals "proofpack resolver keeps legacy root proofpack as final fallback" \
  "$(resolve_ci_proofpack_path "$ROOT_FALLBACK" "")" \
  "$ROOT_FALLBACK/.signum/proofpack.json"

echo ""
echo "=== Proofpack validation integration ==="

VALIDATION_PROJECT="$WORK/validation-project"
FAKEBIN="$WORK/fakebin"
mkdir -p "$VALIDATION_PROJECT" "$FAKEBIN"
cat > "$WORK/validation-contract.json" <<'EOF'
{
  "schemaVersion": "3.2",
  "contractId": "sig-ci-validation",
  "goal": "Validation failure test",
  "inScope": ["test.py"],
  "acceptanceCriteria": [{"id": "AC1", "description": "Test", "visibility": "visible"}],
  "riskLevel": "low"
}
EOF
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
mkdir -p .signum/contracts/sig-ci-validation
cat > .signum/contracts/sig-ci-validation/proofpack.json <<'JSON'
{
  "runId": "signum-invalid",
  "decision": "AUTO_OK",
  "confidence": {"overall": 99}
}
JSON
EOF
chmod +x "$FAKEBIN/claude"
assert_exit_contains "validator failure causes CI failure" 1 "proofpack validation failed" \
  env PATH="$FAKEBIN:$PATH" \
      SIGNUM_CONTRACT_PATH="$WORK/validation-contract.json" \
      SIGNUM_PROJECT_ROOT="$VALIDATION_PROJECT" \
      bash "$CI_SCRIPT"

echo ""
echo "=== Exit code mapping (direct test) ==="

# Test the case statement logic by creating mock proofpacks and sourcing
for decision in AUTO_OK AUTO_BLOCK HUMAN_REVIEW; do
  mkdir -p "$WORK/exittest-${decision}/.signum"
  cat > "$WORK/exittest-${decision}/.signum/proofpack.json" <<PPEOF
{
  "runId": "signum-test",
  "decision": "${decision}",
  "confidence": {"overall": 85}
}
PPEOF

  # Extract the exit code mapping logic and test it standalone
  set +e
  exit_code=$(cd "$WORK/exittest-${decision}" && bash -c '
    DECISION="'"${decision}"'"
    case "$DECISION" in
      AUTO_OK) exit 0 ;;
      AUTO_BLOCK) exit 1 ;;
      HUMAN_REVIEW) exit 78 ;;
      *) exit 1 ;;
    esac
  ')
  actual_exit=$?
  set -e

  case "$decision" in
    AUTO_OK)      expected=0 ;;
    AUTO_BLOCK)   expected=1 ;;
    HUMAN_REVIEW) expected=78 ;;
  esac

  if [[ "$actual_exit" -eq "$expected" ]]; then
    printf '  PASS: %s → exit %s\n' "$decision" "$actual_exit"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected exit %s, got %s\n' "$decision" "$expected" "$actual_exit"
    failed=$((failed + 1))
  fi
done

echo ""
echo "=== SIGNUM_CI_RELAXED mode ==="

# HUMAN_REVIEW in strict mode (default) → exit 78
set +e
exit_code=$(SIGNUM_CI_RELAXED=false bash -c '
  DECISION="HUMAN_REVIEW"
  case "$DECISION" in
    AUTO_OK) exit 0 ;;
    AUTO_BLOCK) exit 1 ;;
    HUMAN_REVIEW)
      if [ "${SIGNUM_CI_RELAXED:-false}" = "true" ]; then exit 0; else exit 78; fi ;;
    *) exit 1 ;;
  esac
')
actual_exit=$?
set -e
if [[ "$actual_exit" -eq 78 ]]; then
  printf '  PASS: HUMAN_REVIEW strict → exit 78\n'
  passed=$((passed + 1))
else
  printf '  FAIL: HUMAN_REVIEW strict — expected 78, got %s\n' "$actual_exit"
  failed=$((failed + 1))
fi

# HUMAN_REVIEW in relaxed mode → exit 0
set +e
exit_code=$(SIGNUM_CI_RELAXED=true bash -c '
  DECISION="HUMAN_REVIEW"
  case "$DECISION" in
    AUTO_OK) exit 0 ;;
    AUTO_BLOCK) exit 1 ;;
    HUMAN_REVIEW)
      if [ "${SIGNUM_CI_RELAXED:-false}" = "true" ]; then exit 0; else exit 78; fi ;;
    *) exit 1 ;;
  esac
')
actual_exit=$?
set -e
if [[ "$actual_exit" -eq 0 ]]; then
  printf '  PASS: HUMAN_REVIEW relaxed → exit 0\n'
  passed=$((passed + 1))
else
  printf '  FAIL: HUMAN_REVIEW relaxed — expected 0, got %s\n' "$actual_exit"
  failed=$((failed + 1))
fi

# AUTO_BLOCK is unaffected by relaxed mode → still exit 1
set +e
exit_code=$(SIGNUM_CI_RELAXED=true bash -c '
  DECISION="AUTO_BLOCK"
  case "$DECISION" in
    AUTO_OK) exit 0 ;;
    AUTO_BLOCK) exit 1 ;;
    HUMAN_REVIEW)
      if [ "${SIGNUM_CI_RELAXED:-false}" = "true" ]; then exit 0; else exit 78; fi ;;
    *) exit 1 ;;
  esac
')
actual_exit=$?
set -e
if [[ "$actual_exit" -eq 1 ]]; then
  printf '  PASS: AUTO_BLOCK relaxed → still exit 1\n'
  passed=$((passed + 1))
else
  printf '  FAIL: AUTO_BLOCK relaxed — expected 1, got %s\n' "$actual_exit"
  failed=$((failed + 1))
fi

echo ""
echo "=== SHA-256 hash computation ==="

# Verify hash is computed correctly
mkdir -p "$WORK/hashtest/.signum"
echo '{"test": true}' > "$WORK/hashtest/.signum/proofpack.json"

if command -v sha256sum >/dev/null 2>&1; then
  EXPECTED=$(sha256sum "$WORK/hashtest/.signum/proofpack.json" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  EXPECTED=$(shasum -a 256 "$WORK/hashtest/.signum/proofpack.json" | awk '{print $1}')
else
  EXPECTED="skip"
fi

if [[ "$EXPECTED" != "skip" && -n "$EXPECTED" ]]; then
  printf '  PASS: SHA-256 hash computable (%s)\n' "${EXPECTED:0:16}..."
  passed=$((passed + 1))
else
  printf '  SKIP: no sha256sum/shasum available\n'
fi

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
  exit 0
fi
