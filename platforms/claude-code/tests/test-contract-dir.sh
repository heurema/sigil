#!/usr/bin/env bash
# test-contract-dir.sh — tests for lib/contract-dir.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/contract-dir.sh"

passed=0
failed=0

# Setup isolated temp workspace
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

source "$LIB"

assert_ok() {
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

assert_fail() {
  local name="$1"; shift
  local expected_substr="${1:-}"; shift || true
  local output
  if output=$("$@" 2>&1); then
    printf '  FAIL: %s — expected failure, got exit 0: %s\n' "$name" "$output"
    failed=$((failed + 1))
  else
    if [[ -n "$expected_substr" && "$output" != *"$expected_substr"* ]]; then
      printf '  FAIL: %s — stderr missing "%s": %s\n' "$name" "$expected_substr" "$output"
      failed=$((failed + 1))
    else
      printf '  PASS: %s\n' "$name"
      passed=$((passed + 1))
    fi
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

echo "=== contract_dir ==="

assert_eq "returns path for valid id" \
  ".signum/contracts/sig-20260314-abcd/" \
  "$(contract_dir "sig-20260314-abcd")"

assert_fail "rejects empty id" "contractId required" \
  contract_dir ""

assert_fail "rejects slash in id" "path traversal" \
  contract_dir "sig-../etc"

assert_fail "rejects double dot in id" "path traversal" \
  contract_dir "sig-..passwd"

assert_fail "rejects slashed path" "path traversal" \
  contract_dir "../../etc/passwd"

echo ""
echo "=== init_contract_dir ==="

assert_ok "creates directory" init_contract_dir "sig-test-001"
[ -d ".signum/contracts/sig-test-001" ]
assert_eq "contract dir exists" "true" \
  "$([ -d .signum/contracts/sig-test-001 ] && echo true || echo false)"
assert_eq "reviews subdir is not pre-created" "false" \
  "$([ -d .signum/contracts/sig-test-001/reviews ] && echo true || echo false)"

assert_fail "fails without id" "contractId required" \
  init_contract_dir ""

echo ""
echo "=== sync_contract_artifacts ==="

mkdir -p ".signum/reviews"
printf '{"goal":"test"}\n' > ".signum/contract.json"
printf '{"decision":"AUTO_OK"}\n' > ".signum/proofpack.json"
printf '{"verdict":"APPROVE"}\n' > ".signum/reviews/claude.json"

assert_ok "syncs selected working-set artifacts" \
  sync_contract_artifacts "sig-test-001" "contract.json" "proofpack.json" "reviews/claude.json"
assert_eq "contract snapshot copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/contract.json ] && echo true || echo false)"
assert_eq "proofpack snapshot copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/proofpack.json ] && echo true || echo false)"
assert_eq "nested review snapshot copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/reviews/claude.json ] && echo true || echo false)"

assert_fail "sync fails without id" "contractId required" \
  sync_contract_artifacts ""
assert_fail "sync fails without paths" "artifact path required" \
  sync_contract_artifacts "sig-test-001"

echo ""
echo "=== register_contract ==="

assert_ok "registers new contract" register_contract "sig-test-001" "draft"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "sets activeContractId" "sig-test-001" "$ACTIVE"

STATUS=$(jq -r '.contracts[] | select(.contractId == "sig-test-001") | .status' .signum/contracts/index.json)
assert_eq "status is draft" "draft" "$STATUS"

# Register second contract
assert_ok "registers second contract" register_contract "sig-test-002" "active"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "active switches to second" "sig-test-002" "$ACTIVE"

COUNT=$(jq '.contracts | length' .signum/contracts/index.json)
assert_eq "two contracts in index" "2" "$COUNT"

# Re-register updates existing (NOTE: this also sets activeContractId back to sig-test-001)
assert_ok "re-register updates existing" register_contract "sig-test-001" "completed"
STATUS=$(jq -r '.contracts[] | select(.contractId == "sig-test-001") | .status' .signum/contracts/index.json)
assert_eq "status updated to completed" "completed" "$STATUS"
COUNT=$(jq '.contracts | length' .signum/contracts/index.json)
assert_eq "still two contracts (no dup)" "2" "$COUNT"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "active switches back on re-register" "sig-test-001" "$ACTIVE"

assert_fail "register fails without id" "contractId required" \
  register_contract ""

echo ""
echo "=== update_contract_status ==="

assert_ok "updates existing status" update_contract_status "sig-test-002" "archived"
STATUS=$(jq -r '.contracts[] | select(.contractId == "sig-test-002") | .status' .signum/contracts/index.json)
assert_eq "status is archived" "archived" "$STATUS"

assert_fail "fails for missing contract" "not found in index" \
  update_contract_status "sig-nonexistent" "active"

assert_fail "fails without args" "contractId and newStatus required" \
  update_contract_status ""

echo ""
echo "=== get_active_contract ==="

ACTIVE=$(get_active_contract)
assert_eq "returns active id" "sig-test-001" "$ACTIVE"

echo ""
echo "=== current_contract_dir ==="

DIR=$(current_contract_dir)
assert_eq "returns active dir" ".signum/contracts/sig-test-001/" "$DIR"

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
