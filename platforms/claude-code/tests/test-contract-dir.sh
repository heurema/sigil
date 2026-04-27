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
  ".signum/contracts/sig-20260314-1030-abcd/" \
  "$(contract_dir "sig-20260314-1030-abcd")"

assert_fail "rejects empty id" "contractId required" \
  contract_dir ""

assert_fail "rejects slash in id" "path traversal" \
  contract_dir "sig-../etc"

assert_fail "rejects double dot in id" "path traversal" \
  contract_dir "sig-..passwd"

assert_fail "rejects slashed path" "path traversal" \
  contract_dir "../../etc/passwd"

echo ""
echo "=== new_contract_id ==="

ID1=$(new_contract_id)
ID2=$(new_contract_id)
if [[ "$ID1" =~ ^sig-[0-9]{8}-[0-9]{4}-[0-9a-f]{4}$ ]]; then
  printf '  PASS: new_contract_id format includes HHMM\n'
  passed=$((passed + 1))
else
  printf '  FAIL: new_contract_id format includes HHMM - got "%s"\n' "$ID1"
  failed=$((failed + 1))
fi

if [[ "$ID1" != "$ID2" ]]; then
  printf '  PASS: new_contract_id produces unique values\n'
  passed=$((passed + 1))
else
  printf '  FAIL: new_contract_id produces unique values - both were "%s"\n' "$ID1"
  failed=$((failed + 1))
fi

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
mkdir -p ".signum/receipts" ".signum/runs/run-01" ".signum/snapshots"
printf '{"status":"PASS"}\n' > ".signum/receipts/execute.json"
printf '{"attempt":1}\n' > ".signum/runs/run-01/execute-01.json"
printf '{"tree_hash":"sha256:test"}\n' > ".signum/snapshots/pre-execute.json"

assert_ok "syncs selected working-set artifacts" \
  sync_contract_artifacts "sig-test-001" "contract.json" "proofpack.json" "reviews/claude.json" "receipts" "runs/run-01" "snapshots"
assert_eq "contract snapshot copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/contract.json ] && echo true || echo false)"
assert_eq "proofpack snapshot copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/proofpack.json ] && echo true || echo false)"
assert_eq "nested review snapshot copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/reviews/claude.json ] && echo true || echo false)"
assert_eq "receipts dir copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/receipts/execute.json ] && echo true || echo false)"
assert_eq "runs dir copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/runs/run-01/execute-01.json ] && echo true || echo false)"
assert_eq "snapshots dir copied" "true" \
  "$([ -f .signum/contracts/sig-test-001/snapshots/pre-execute.json ] && echo true || echo false)"

printf '{"status":"PASS","attempt":2}\n' > ".signum/receipts/execute.json"
assert_ok "re-sync updates dirs without nesting" \
  sync_contract_artifacts "sig-test-001" "receipts"
assert_eq "re-sync does not create nested receipts dir" "false" \
  "$([ -d .signum/contracts/sig-test-001/receipts/receipts ] && echo true || echo false)"

assert_fail "sync fails without id" "contractId required" \
  sync_contract_artifacts ""
assert_fail "sync fails without paths" "artifact path required" \
  sync_contract_artifacts "sig-test-001"
printf '{"canonical":"only"}\n' > ".signum/contracts/sig-test-001/canonical_only.json"
rm -f ".signum/canonical_only.json"
assert_ok "sync skips missing root source without touching canonical" \
  sync_contract_artifacts "sig-test-001" "canonical_only.json"
assert_eq "sync does not materialize root from canonical" "false" \
  "$([ -e .signum/canonical_only.json ] && echo true || echo false)"
assert_eq "sync leaves canonical-only artifact untouched" '{"canonical":"only"}' \
  "$(cat ".signum/contracts/sig-test-001/canonical_only.json")"

echo ""
echo "=== register_contract ==="

assert_ok "registers new contract" register_contract "sig-test-001" "draft"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "register does not set activeContractId" "null" "$ACTIVE"

STATUS=$(jq -r '.contracts[] | select(.contractId == "sig-test-001") | .status' .signum/contracts/index.json)
assert_eq "status is draft" "draft" "$STATUS"

# Register second contract
assert_ok "registers second contract" register_contract "sig-test-002" "active"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "register still leaves active unset" "null" "$ACTIVE"

COUNT=$(jq '.contracts | length' .signum/contracts/index.json)
assert_eq "two contracts in index" "2" "$COUNT"

# Re-register updates existing without stealing active selection
assert_ok "sets active contract explicitly" set_active_contract "sig-test-002"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "active switches only via explicit setter" "sig-test-002" "$ACTIVE"

assert_ok "re-register updates existing" register_contract "sig-test-001" "completed"
STATUS=$(jq -r '.contracts[] | select(.contractId == "sig-test-001") | .status' .signum/contracts/index.json)
assert_eq "status updated to completed" "completed" "$STATUS"
COUNT=$(jq '.contracts | length' .signum/contracts/index.json)
assert_eq "still two contracts (no dup)" "2" "$COUNT"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "re-register does not change active" "sig-test-002" "$ACTIVE"

assert_fail "register fails without id" "contractId required" \
  register_contract ""
assert_fail "set_active_contract fails without id" "contractId required" \
  set_active_contract ""
assert_fail "set_active_contract fails for missing contract" "not found in index" \
  set_active_contract "sig-missing"

echo ""
echo "=== clear_active_contract ==="

assert_ok "clears active contract explicitly" clear_active_contract
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "activeContractId is null after clear" "null" "$ACTIVE"

echo ""
echo "=== update_contract_status ==="

assert_ok "re-sets active contract for terminal status test" set_active_contract "sig-test-002"
assert_ok "updates existing status to completed" update_contract_status "sig-test-002" "completed"
STATUS=$(jq -r '.contracts[] | select(.contractId == "sig-test-002") | .status' .signum/contracts/index.json)
assert_eq "status is completed" "completed" "$STATUS"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "completed status keeps active contract" "sig-test-002" "$ACTIVE"
ACTIVE_ROOT=$(active_artifact_root)
assert_eq "completed contract still resolves active artifact root" ".signum/contracts/sig-test-002/" "$ACTIVE_ROOT"

assert_ok "updates existing status" update_contract_status "sig-test-002" "archived"
STATUS=$(jq -r '.contracts[] | select(.contractId == "sig-test-002") | .status' .signum/contracts/index.json)
assert_eq "status is archived" "archived" "$STATUS"
ACTIVE=$(jq -r '.activeContractId' .signum/contracts/index.json)
assert_eq "terminal status clears active contract" "null" "$ACTIVE"

assert_fail "fails for missing contract" "not found in index" \
  update_contract_status "sig-nonexistent" "active"

assert_fail "fails without args" "contractId and newStatus required" \
  update_contract_status ""

echo ""
echo "=== get_active_contract ==="

ACTIVE=$(get_active_contract)
assert_eq "returns empty when no active id is set" "" "$ACTIVE"

STATUS=$(get_contract_status "sig-test-002")
assert_eq "get_contract_status returns archived status" "archived" "$STATUS"
assert_fail "get_contract_status fails without id" "contractId required" \
  get_contract_status ""
assert_fail "get_contract_status fails for missing contract" "not found in index" \
  get_contract_status "sig-missing"

echo ""
echo "=== describe_active_contract_state ==="

STATE_JSON=$(describe_active_contract_state)
assert_eq "describe_active_contract_state returns NONE without active contract" "NONE" \
  "$(printf '%s' "$STATE_JSON" | jq -r '.state')"
assert_eq "describe_active_contract_state returns null contractId when inactive" "null" \
  "$(printf '%s' "$STATE_JSON" | jq -r '.contractId')"

echo ""
echo "=== active_artifact_root / current_contract_dir ==="

ACTIVE_ID="sig-active-001"
assert_ok "creates active draft contract dir" init_contract_dir "$ACTIVE_ID"
printf '{"goal":"active"}\n' > ".signum/contracts/${ACTIVE_ID}/contract.json"
assert_ok "registers active draft contract" register_contract "$ACTIVE_ID" "draft"
assert_ok "sets active contract for root lookup" set_active_contract "$ACTIVE_ID"
DIR=$(active_artifact_root)
assert_eq "returns active artifact root" ".signum/contracts/${ACTIVE_ID}/" "$DIR"
DIR=$(current_contract_dir)
assert_eq "current_contract_dir remains alias" ".signum/contracts/${ACTIVE_ID}/" "$DIR"
PATH_TO_CONTRACT=$(active_artifact_path "contract.json")
assert_eq "active_artifact_path returns active file path" ".signum/contracts/${ACTIVE_ID}/contract.json" "$PATH_TO_CONTRACT"
STATE_JSON=$(describe_active_contract_state)
assert_eq "active contract with only contract.json is CONTRACT_ONLY" "CONTRACT_ONLY" \
  "$(printf '%s' "$STATE_JSON" | jq -r '.state')"
assert_eq "describe_active_contract_state includes active contract id" "$ACTIVE_ID" \
  "$(printf '%s' "$STATE_JSON" | jq -r '.contractId')"
assert_eq "describe_active_contract_state includes active artifact root" ".signum/contracts/${ACTIVE_ID}/" \
  "$(printf '%s' "$STATE_JSON" | jq -r '.artifactRoot')"

echo ""
echo "=== link_active_artifact / promote_root_artifact_to_active ==="

printf '{"goal":"canonical"}\n' > .signum/contract.json
assert_ok "promotes root contract into active root" promote_root_artifact_to_active "contract.json"
assert_eq "promoted contract now exists in active root" "true" \
  "$([ -f .signum/contracts/${ACTIVE_ID}/contract.json ] && echo true || echo false)"
assert_eq "root contract path is removed after one-time promotion" "false" \
  "$([ -e .signum/contract.json ] || [ -L .signum/contract.json ] && echo true || echo false)"
PROMOTED_CONTENT=$(cat ".signum/contracts/${ACTIVE_ID}/contract.json")
assert_eq "promoted contract content preserved" '{"goal":"canonical"}' "$PROMOTED_CONTENT"

assert_ok "links phase1 spec artifact into active root" link_active_artifact "spec_quality.json"
assert_eq "root spec_quality path becomes symlink" "true" \
  "$([ -L .signum/spec_quality.json ] && echo true || echo false)"
printf '{"total":91}\n' > .signum/spec_quality.json
assert_eq "writing through symlink lands in active root" '{"total":91}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/spec_quality.json")"
assert_ok "links execution context into active root" link_active_artifact "execution_context.json"
printf '{"run_id":"run-01"}\n' > .signum/execution_context.json
STATE_JSON=$(describe_active_contract_state)
assert_eq "active contract with execution_context becomes RESUMABLE" "RESUMABLE" \
  "$(printf '%s' "$STATE_JSON" | jq -r '.state')"

assert_ok "links execute patch into active root" link_active_artifact "combined.patch"
printf 'diff --git a/foo b/foo\n' > .signum/combined.patch
assert_eq "execute patch is written to active root" 'diff --git a/foo b/foo' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/combined.patch")"
rm -f .signum/combined.patch
assert_ok "re-links execute patch after cleanup" link_active_artifact "combined.patch"
printf 'diff --git a/bar b/bar\n' > .signum/combined.patch
assert_eq "relinked execute patch still writes canonically" 'diff --git a/bar b/bar' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/combined.patch")"

assert_ok "links audit summary into active root" link_active_artifact "audit_summary.json"
printf '{"decision":"AUTO_OK"}\n' > .signum/audit_summary.json
assert_eq "audit summary is written to active root" '{"decision":"AUTO_OK"}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/audit_summary.json")"

assert_ok "links proofpack into active root" link_active_artifact "proofpack.json"
printf '{"runId":"sig-active-001"}\n' > .signum/proofpack.json
assert_eq "proofpack is written to active root" '{"runId":"sig-active-001"}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/proofpack.json")"
assert_ok "sync of symlinked active proofpack is a no-op" \
  sync_contract_artifacts "$ACTIVE_ID" "proofpack.json"
assert_eq "self-copy sync keeps canonical proofpack content" '{"runId":"sig-active-001"}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/proofpack.json")"

echo ""
echo "=== ensure_active_artifact_dir / remove_root_artifact_view / reset_active_artifact ==="

assert_ok "creates active reviews dir bridge" ensure_active_artifact_dir "reviews"
assert_eq "root reviews path becomes symlink" "true" \
  "$([ -L .signum/reviews ] && echo true || echo false)"
mkdir -p .signum/reviews
printf '{"decision":"APPROVE"}\n' > .signum/reviews/claude.json
assert_eq "reviews dir writes into active root" '{"decision":"APPROVE"}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/reviews/claude.json")"
assert_ok "sync of symlinked active reviews dir is a no-op" \
  sync_contract_artifacts "$ACTIVE_ID" "reviews"
assert_eq "self-copy sync keeps canonical reviews content" '{"decision":"APPROVE"}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/reviews/claude.json")"

assert_ok "removes only root reviews view" remove_root_artifact_view "reviews"
assert_eq "root reviews view removed" "false" \
  "$([ -e .signum/reviews ] && echo true || echo false)"
assert_eq "canonical reviews dir preserved" "true" \
  "$([ -f ".signum/contracts/${ACTIVE_ID}/reviews/claude.json" ] && echo true || echo false)"

assert_ok "resets dir artifact without re-linking root view" reset_active_artifact "reviews" "dir"
assert_eq "reviews root view stays absent after reset" "false" \
  "$([ -e .signum/reviews ] || [ -L .signum/reviews ] && echo true || echo false)"
assert_eq "reviews canonical contents cleared on reset" "false" \
  "$([ -f ".signum/contracts/${ACTIVE_ID}/reviews/claude.json" ] && echo true || echo false)"
assert_eq "reviews canonical dir exists after reset" "true" \
  "$([ -d ".signum/contracts/${ACTIVE_ID}/reviews" ] && echo true || echo false)"
printf '{"decision":"RETRY"}\n' > ".signum/contracts/${ACTIVE_ID}/reviews/codex.json"
assert_eq "reviews dir can be reused after reset" '{"decision":"RETRY"}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/reviews/codex.json")"

assert_ok "resets file artifact without re-linking root view" reset_active_artifact "iteration_delta.patch"
assert_eq "iteration delta root view stays absent after reset" "false" \
  "$([ -e .signum/iteration_delta.patch ] || [ -L .signum/iteration_delta.patch ] && echo true || echo false)"
assert_eq "iteration delta target cleared on reset" "false" \
  "$([ -e ".signum/contracts/${ACTIVE_ID}/iteration_delta.patch" ] && echo true || echo false)"
printf 'delta-v2\n' > ".signum/contracts/${ACTIVE_ID}/iteration_delta.patch"
assert_eq "iteration delta writes canonically after reset" 'delta-v2' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/iteration_delta.patch")"

assert_fail "reset_active_artifact rejects invalid kind" "kind must be file or dir" \
  reset_active_artifact "proofpack.json" "weird"

echo ""
echo "=== reset_canonical_active_artifact ==="

printf 'root-delta\n' > .signum/iteration_delta.patch
printf 'canonical-delta\n' > ".signum/contracts/${ACTIVE_ID}/iteration_delta.patch"
assert_ok "canonical reset clears only active file artifact" reset_canonical_active_artifact "iteration_delta.patch"
assert_eq "canonical reset leaves root file view untouched" 'root-delta' \
  "$(cat .signum/iteration_delta.patch)"
assert_eq "canonical reset removes active file artifact" "false" \
  "$([ -e ".signum/contracts/${ACTIVE_ID}/iteration_delta.patch" ] && echo true || echo false)"

mkdir -p .signum/reviews ".signum/contracts/${ACTIVE_ID}/reviews"
printf '{"legacy":"root"}\n' > .signum/reviews/claude.json
printf '{"canonical":"active"}\n' > ".signum/contracts/${ACTIVE_ID}/reviews/claude.json"
assert_ok "canonical reset handles nested file artifact" reset_canonical_active_artifact "reviews/claude.json"
assert_eq "canonical reset leaves nested root artifact untouched" '{"legacy":"root"}' \
  "$(cat .signum/reviews/claude.json)"
assert_eq "canonical reset removes nested active file artifact" "false" \
  "$([ -e ".signum/contracts/${ACTIVE_ID}/reviews/claude.json" ] && echo true || echo false)"

printf '{"canonical":"active-dir"}\n' > ".signum/contracts/${ACTIVE_ID}/reviews/codex.json"
assert_ok "canonical reset recreates active directory artifact" reset_canonical_active_artifact "reviews" "dir"
assert_eq "canonical reset leaves root directory artifact untouched" '{"legacy":"root"}' \
  "$(cat .signum/reviews/claude.json)"
assert_eq "canonical reset clears active directory contents" "false" \
  "$([ -e ".signum/contracts/${ACTIVE_ID}/reviews/codex.json" ] && echo true || echo false)"
assert_eq "canonical reset keeps active directory available" "true" \
  "$([ -d ".signum/contracts/${ACTIVE_ID}/reviews" ] && echo true || echo false)"

assert_fail "canonical reset rejects unsafe relative path" "invalid relative path" \
  reset_canonical_active_artifact "../escape.patch"
assert_fail "canonical reset rejects invalid kind" "kind must be file or dir" \
  reset_canonical_active_artifact "proofpack.json" "weird"

echo ""
echo "=== verify_canonical_contract_artifacts ==="

printf 'root-verify\n' > .signum/verify_only.json
printf 'canonical-verify\n' > ".signum/contracts/${ACTIVE_ID}/verify_only.json"
assert_ok "canonical verification leaves root and canonical files untouched" \
  verify_canonical_contract_artifacts "$ACTIVE_ID" "verify_only.json"
assert_eq "canonical verification preserves root file" 'root-verify' \
  "$(cat .signum/verify_only.json)"
assert_eq "canonical verification preserves canonical file" 'canonical-verify' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/verify_only.json")"

printf 'root-only-verify\n' > .signum/root_only_verify.json
rm -f ".signum/contracts/${ACTIVE_ID}/root_only_verify.json"
assert_ok "canonical verification does not import root-only artifact" \
  verify_canonical_contract_artifacts "$ACTIVE_ID" "root_only_verify.json"
assert_eq "canonical verification preserves root-only artifact" 'root-only-verify' \
  "$(cat .signum/root_only_verify.json)"
assert_eq "canonical verification leaves missing canonical artifact missing" "false" \
  "$([ -e ".signum/contracts/${ACTIVE_ID}/root_only_verify.json" ] && echo true || echo false)"

mkdir -p ".signum/contracts/${ACTIVE_ID}/runs/run-verify"
printf '{"run":"verify"}\n' > ".signum/contracts/${ACTIVE_ID}/runs/run-verify/execute.json"
assert_ok "canonical verification handles nested directory artifact" \
  verify_canonical_contract_artifacts "$ACTIVE_ID" "runs/run-verify"
assert_eq "canonical verification preserves nested directory artifact" '{"run":"verify"}' \
  "$(cat ".signum/contracts/${ACTIVE_ID}/runs/run-verify/execute.json")"

assert_fail "canonical verification rejects missing contract id" "contractId required" \
  verify_canonical_contract_artifacts ""
assert_fail "canonical verification rejects missing paths" "artifact path required" \
  verify_canonical_contract_artifacts "$ACTIVE_ID"
assert_fail "canonical verification rejects unsafe relative path" "invalid relative path" \
  verify_canonical_contract_artifacts "$ACTIVE_ID" "../escape.json"

echo ""
echo "=== archive_contract_artifacts / purge_root_working_set_views ==="

assert_ok "re-links proofpack before archive helper" link_active_artifact "proofpack.json"
printf '{"runId":"sig-active-001-archive"}\n' > .signum/proofpack.json
printf '{"resolved":1}\n' > ".signum/contracts/${ACTIVE_ID}/reconcile_report.json"
printf '{"risk":"medium"}\n' > ".signum/contracts/${ACTIVE_ID}/retro.json"
mkdir -p ".signum/contracts/${ACTIVE_ID}/receipts"
printf '{"status":"PASS"}\n' > ".signum/contracts/${ACTIVE_ID}/receipts/execute.json"
ARCHIVE_OUT=".signum/archive/${ACTIVE_ID}"
assert_ok "archives canonical contract payload" archive_contract_artifacts "$ACTIVE_ID" "$ARCHIVE_OUT"
assert_eq "archive copies canonical contract" "true" \
  "$([ -f "${ARCHIVE_OUT}/contract.json" ] && echo true || echo false)"
assert_eq "archive copies canonical proofpack" "true" \
  "$([ -f "${ARCHIVE_OUT}/proofpack.json" ] && echo true || echo false)"
assert_eq "archive copies reconcile report" "true" \
  "$([ -f "${ARCHIVE_OUT}/reconcile_report.json" ] && echo true || echo false)"
assert_eq "archive copies retro" "true" \
  "$([ -f "${ARCHIVE_OUT}/retro.json" ] && echo true || echo false)"
assert_eq "archive copies receipts dir contents" "true" \
  "$([ -f "${ARCHIVE_OUT}/receipts/execute.json" ] && echo true || echo false)"
assert_fail "archive helper rejects missing contract id" "contractId and archive_dir required" \
  archive_contract_artifacts ""

printf '{"baseline":true}\n' > .signum/repo_contract_baseline.json
printf 'prompt\n' > .signum/review_prompt_codex.txt
mkdir -p ".signum/contracts/${ACTIVE_ID}/reviews"
printf '{"decision":"PRESERVE"}\n' > ".signum/contracts/${ACTIVE_ID}/reviews/claude.json"
printf '{"decision":"PRESERVE"}\n' > ".signum/contracts/${ACTIVE_ID}/reviews/codex.json"
assert_ok "re-links review context before purge" link_active_artifact "review_context.json"
printf '{"issue_refs":[]}\n' > .signum/review_context.json
assert_ok "purges root working set compatibility surface" purge_root_working_set_views
assert_eq "root proofpack view removed" "false" \
  "$([ -e .signum/proofpack.json ] && echo true || echo false)"
assert_eq "root reviews view removed" "false" \
  "$([ -e .signum/reviews ] && echo true || echo false)"
assert_eq "root repo baseline removed" "false" \
  "$([ -e .signum/repo_contract_baseline.json ] && echo true || echo false)"
assert_eq "root review prompt removed" "false" \
  "$([ -e .signum/review_prompt_codex.txt ] && echo true || echo false)"
assert_eq "root review context removed" "false" \
  "$([ -e .signum/review_context.json ] && echo true || echo false)"
assert_eq "canonical proofpack preserved after purge" "true" \
  "$([ -f ".signum/contracts/${ACTIVE_ID}/proofpack.json" ] && echo true || echo false)"
assert_eq "canonical reviews preserved after purge" "true" \
  "$([ -f ".signum/contracts/${ACTIVE_ID}/reviews/codex.json" ] && echo true || echo false)"
assert_eq "canonical review context preserved after purge" "true" \
  "$([ -f ".signum/contracts/${ACTIVE_ID}/review_context.json" ] && echo true || echo false)"

assert_ok "marks contract terminal for stale-active cleanup test" update_contract_status "$ACTIVE_ID" "completed"
assert_ok "re-sets completed contract as active to simulate stale index" set_active_contract "$ACTIVE_ID"
STATE_JSON=$(describe_active_contract_state)
assert_eq "terminal active contract is treated as NONE" "NONE" \
  "$(printf '%s' "$STATE_JSON" | jq -r '.state')"
assert_eq "terminal active contract is cleared from index" "" \
  "$(get_active_contract)"

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
