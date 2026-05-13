#!/usr/bin/env bash
# test-examples.sh -- guard first-class examples documentation fixtures
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"

ROOT_README="$REPO_ROOT/README.md"
DOCS_README="$REPO_ROOT/docs/README.md"
EXAMPLES_README="$REPO_ROOT/examples/README.md"
PROOFPACK_README="$REPO_ROOT/examples/proofpack-validation/README.md"
PROOFPACK_JSON="$REPO_ROOT/examples/proofpack-validation/valid-proofpack.json"
CI_GATE_README="$REPO_ROOT/examples/ci-gate/README.md"
BASIC_CONTRACT_README="$REPO_ROOT/examples/basic-contract/README.md"
BASIC_CONTRACT_JSON="$REPO_ROOT/examples/basic-contract/contract.json"

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

assert_file_exists() {
  local name="$1" file="$2"
  if [ -f "$file" ]; then
    pass "$name"
  else
    fail "$name" "missing $file"
  fi
}

assert_dir_exists() {
  local name="$1" dir="$2"
  if [ -d "$dir" ]; then
    pass "$name"
  else
    fail "$name" "missing $dir"
  fi
}

assert_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$name"
  else
    fail "$name" "$file does not contain $needle"
  fi
}

assert_ok() {
  local name="$1"
  shift
  local output
  if output=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

echo "=== Examples documentation fixtures ==="

assert_file_exists "examples index exists" "$EXAMPLES_README"
assert_dir_exists "proofpack validation example exists" "$REPO_ROOT/examples/proofpack-validation"
assert_dir_exists "CI gate example exists" "$REPO_ROOT/examples/ci-gate"
assert_dir_exists "basic contract example exists" "$REPO_ROOT/examples/basic-contract"

assert_contains "root README links examples index" "$ROOT_README" "examples/README.md"
assert_contains "docs README links examples index" "$DOCS_README" "../examples/README.md"
assert_contains "examples index documents canonical artifact root" "$EXAMPLES_README" ".signum/contracts/<contractId>/"

assert_contains "proofpack README references validator" "$PROOFPACK_README" "scripts/validate_proofpack.py"
assert_file_exists "valid proofpack example exists" "$PROOFPACK_JSON"
assert_ok "valid proofpack example validates" \
  python3 "$REPO_ROOT/scripts/validate_proofpack.py" "$PROOFPACK_JSON" --repo-root "$REPO_ROOT"

assert_contains "CI gate README references wrapper" "$CI_GATE_README" "lib/signum-ci.sh"
assert_contains "CI gate README references workflow template" "$CI_GATE_README" "lib/templates/signum-gate.yml"
assert_contains "CI gate README references AUTO_OK" "$CI_GATE_README" "AUTO_OK"
assert_contains "CI gate README references AUTO_BLOCK" "$CI_GATE_README" "AUTO_BLOCK"
assert_contains "CI gate README references HUMAN_REVIEW" "$CI_GATE_README" "HUMAN_REVIEW"

assert_file_exists "basic contract example exists" "$BASIC_CONTRACT_JSON"
assert_ok "basic contract example is valid JSON" python3 -m json.tool "$BASIC_CONTRACT_JSON"
assert_contains "basic contract README references reference docs" "$BASIC_CONTRACT_README" "docs/reference.md"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
