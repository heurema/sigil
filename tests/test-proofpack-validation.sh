#!/usr/bin/env bash
# test-proofpack-validation.sh -- deterministic tests for scripts/validate_proofpack.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate_proofpack.py"
OVERLAY_VALIDATOR="$REPO_ROOT/platforms/claude-code/scripts/validate_proofpack.py"
FIXTURES="$REPO_ROOT/tests/fixtures/proofpack"

passed=0
failed=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

assert_ok() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

assert_fail_contains() {
  local name="$1" expected="$2"; shift 2
  local output exit_code
  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e
  if [ "$exit_code" -eq 0 ]; then
    fail "$name" "expected failure, got exit 0: $output"
  elif [[ "$output" == *"$expected"* ]]; then
    pass "$name"
  else
    fail "$name" "missing '$expected' in: $output"
  fi
}

assert_contains_file() {
  local name="$1" needle="$2" path="$3"
  if grep -Fq "$needle" "$path"; then
    pass "$name"
  else
    fail "$name" "$path does not contain $needle"
  fi
}

echo "=== Validator wiring ==="
assert_file "root validator exists" "$VALIDATOR"
assert_file "overlay validator exists" "$OVERLAY_VALIDATOR"
assert_ok "overlay validator mirrors root" cmp -s "$VALIDATOR" "$OVERLAY_VALIDATOR"
assert_contains_file "root signum-ci invokes proofpack validator" "validate_proofpack.py" "$REPO_ROOT/lib/signum-ci.sh"
assert_contains_file "overlay signum-ci invokes proofpack validator" "validate_proofpack.py" "$REPO_ROOT/platforms/claude-code/lib/signum-ci.sh"
assert_contains_file "validator requires releaseVerdict" '"releaseVerdict": str' "$VALIDATOR"
assert_contains_file "validator requires timing" '"timing": dict' "$VALIDATOR"
assert_contains_file "validator requires reviewCoverage" '"reviewCoverage": dict' "$VALIDATOR"
assert_contains_file "root proofpack assembly emits releaseVerdict" 'releaseVerdict: $releaseVerdict' "$REPO_ROOT/commands/signum.md"
assert_contains_file "root proofpack assembly emits timing" 'timing: { startedAt:' "$REPO_ROOT/commands/signum.md"
assert_contains_file "root proofpack assembly emits reviewCoverage" 'reviewCoverage: { availableReviews:' "$REPO_ROOT/commands/signum.md"
assert_contains_file "overlay proofpack assembly emits releaseVerdict" 'releaseVerdict: $releaseVerdict' "$REPO_ROOT/platforms/claude-code/commands/signum.md"
assert_contains_file "overlay proofpack assembly emits timing" 'timing: { startedAt:' "$REPO_ROOT/platforms/claude-code/commands/signum.md"
assert_contains_file "overlay proofpack assembly emits reviewCoverage" 'reviewCoverage: { availableReviews:' "$REPO_ROOT/platforms/claude-code/commands/signum.md"

echo ""
echo "=== Valid proofpacks ==="
assert_ok "valid minimal proofpack passes" \
  python3 "$VALIDATOR" "$FIXTURES/valid-minimal.json" --repo-root "$REPO_ROOT"
assert_ok "valid proofpack with optional removalEvidence passes" \
  python3 "$VALIDATOR" "$FIXTURES/valid-with-removal-evidence.json" --repo-root "$REPO_ROOT"

CONTRACT_ROOT="$WORK/contract-root"
mkdir -p "$CONTRACT_ROOT"
printf '{"goal":"fixture"}\n' > "$CONTRACT_ROOT/contract.json"
assert_ok "valid proofpack with artifact ref passes with explicit contract root" \
  python3 "$VALIDATOR" "$FIXTURES/valid-with-artifact-ref.json" --repo-root "$REPO_ROOT" --contract-root "$CONTRACT_ROOT"

INFER_ROOT="$WORK/project/.signum/contracts/sig-proofpack-001"
mkdir -p "$INFER_ROOT"
cp "$FIXTURES/valid-with-artifact-ref.json" "$INFER_ROOT/proofpack.json"
printf '{"goal":"fixture"}\n' > "$INFER_ROOT/contract.json"
assert_ok "validator infers canonical contract root from proofpack path" \
  python3 "$VALIDATOR" "$INFER_ROOT/proofpack.json" --repo-root "$REPO_ROOT"

echo ""
echo "=== Invalid proofpacks ==="
assert_fail_contains "malformed JSON fails" "invalid JSON" \
  python3 "$VALIDATOR" "$FIXTURES/malformed.json" --repo-root "$REPO_ROOT"
assert_fail_contains "missing required field fails" "missing required field: decision" \
  python3 "$VALIDATOR" "$FIXTURES/missing-required.json" --repo-root "$REPO_ROOT"
assert_fail_contains "wrong primitive type fails" "confidence.overall must be number" \
  python3 "$VALIDATOR" "$FIXTURES/wrong-type.json" --repo-root "$REPO_ROOT"
assert_fail_contains "schemaVersion mismatch fails" "schemaVersion mismatch" \
  python3 "$VALIDATOR" "$FIXTURES/schema-version-mismatch.json" --repo-root "$REPO_ROOT"
assert_fail_contains "signumVersion mismatch fails" "signumVersion mismatch" \
  python3 "$VALIDATOR" "$FIXTURES/signum-version-mismatch.json" --repo-root "$REPO_ROOT"
assert_fail_contains "unsafe artifact path fails" "unsafe artifact path" \
  python3 "$VALIDATOR" "$FIXTURES/unsafe-artifact-path.json" --repo-root "$REPO_ROOT" --contract-root "$CONTRACT_ROOT"
assert_fail_contains "missing referenced artifact fails" "referenced artifact missing" \
  python3 "$VALIDATOR" "$FIXTURES/missing-artifact-ref.json" --repo-root "$REPO_ROOT" --contract-root "$CONTRACT_ROOT"
assert_fail_contains "invalid removalEvidence shape fails" "removalEvidence.removals[0].id must match" \
  python3 "$VALIDATOR" "$FIXTURES/invalid-removal-evidence.json" --repo-root "$REPO_ROOT"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
