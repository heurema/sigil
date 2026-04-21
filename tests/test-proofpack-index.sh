#!/usr/bin/env bash
# test-proofpack-index.sh -- canonical and legacy path behavior for lib/proofpack-index.sh
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
INDEX_LIB="$ROOT_DIR/lib/proofpack-index.sh"

passed=0
failed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_ok() {
  local name="$1"
  shift
  if "$@" >/tmp/test_out.$$ 2>&1; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s\n' "$name"
    sed 's/^/    /' /tmp/test_out.$$
    failed=$((failed + 1))
  fi
  rm -f /tmp/test_out.$$
}

assert_equals() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

make_proofpack() {
  local path="$1"
  local run_id="$2"
  local contract_id="$3"
  cat > "$path" <<EOFJSON
{
  "schemaVersion": "4.7",
  "createdAt": "2026-04-21T12:30:00Z",
  "runId": "$run_id",
  "contractId": "$contract_id",
  "decision": "AUTO_OK",
  "releaseVerdict": "GO",
  "riskLevel": "low",
  "confidence": {"overall": 93},
  "reviewCoverage": {"availableReviews": 2},
  "summary": "ok"
}
EOFJSON
}

scenario_canonical_append_from_outside() {
  local repo outside canonical_pp index_file
  repo="$WORK/canonical-repo"
  outside="$WORK/outside"
  canonical_pp="$repo/.signum/contracts/sig-20260421-1230-abcd/proofpack.json"
  index_file="$repo/.signum/proofpack-index.jsonl"
  mkdir -p "$(dirname "$canonical_pp")" "$outside"
  make_proofpack "$canonical_pp" "sig-run-001" "sig-20260421-1230-abcd"

  (
    cd "$outside"
    source "$INDEX_LIB"
    proofpack_index_append "$canonical_pp"
  )

  test -f "$index_file"
  test ! -f "$outside/.signum/proofpack-index.jsonl"
  local run_id contract_id
  run_id="$(jq -r '.runId' "$index_file")"
  contract_id="$(jq -r '.contractId' "$index_file")"
  [[ "$run_id" == "sig-run-001" ]]
  [[ "$contract_id" == "sig-20260421-1230-abcd" ]]

  local verify_out
  verify_out="$(SIGNUM_PROJECT_ROOT="$repo" bash -lc 'source "$1"; proofpack_index_verify' _ "$INDEX_LIB")"
  [[ "$verify_out" == OK:* ]]
}

scenario_legacy_root_append() {
  local repo legacy_pp index_file query_count
  repo="$WORK/legacy-repo"
  legacy_pp="$repo/.signum/proofpack.json"
  index_file="$repo/.signum/proofpack-index.jsonl"
  mkdir -p "$repo/.signum"
  make_proofpack "$legacy_pp" "sig-run-legacy" "sig-legacy-001"

  (
    cd "$repo"
    source "$INDEX_LIB"
    proofpack_index_append ".signum/proofpack.json"
  )

  test -f "$index_file"
  query_count="$(SIGNUM_PROJECT_ROOT="$repo" bash -lc 'source "$1"; proofpack_index_query --last 1 | jq length' _ "$INDEX_LIB")"
  [[ "$query_count" == "1" ]]
  [[ "$(jq -r '.runId' "$index_file")" == "sig-run-legacy" ]]
}

scenario_canonical_relative_append_inside_contract_dir() {
  local repo contract_dir canonical_pp index_file query_count verify_out
  repo="$WORK/inside-contract-dir"
  contract_dir="$repo/.signum/contracts/sig-20260421-1240-beef"
  canonical_pp="$contract_dir/proofpack.json"
  index_file="$repo/.signum/proofpack-index.jsonl"
  mkdir -p "$contract_dir"
  make_proofpack "$canonical_pp" "sig-run-002" "sig-20260421-1240-beef"

  (
    cd "$contract_dir"
    source "$INDEX_LIB"
    proofpack_index_append "proofpack.json"
  )

  test -f "$index_file"
  test ! -f "$contract_dir/.signum/proofpack-index.jsonl"
  [[ "$(jq -r '.runId' "$index_file")" == "sig-run-002" ]]

  query_count="$(
    cd "$contract_dir" && \
    bash -lc 'source "$1"; proofpack_index_query --last 1 | jq length' _ "$INDEX_LIB"
  )"
  [[ "$query_count" == "1" ]]

  verify_out="$(
    cd "$contract_dir" && \
    bash -lc 'source "$1"; proofpack_index_verify' _ "$INDEX_LIB"
  )"
  [[ "$verify_out" == OK:* ]]
}

echo "=== Proofpack index paths ==="
assert_ok "canonical proofpack append resolves project-level index from proofpack path" scenario_canonical_append_from_outside
assert_ok "canonical relative proofpack append from inside contract dir still resolves project-level index" scenario_canonical_relative_append_inside_contract_dir
assert_ok "legacy root proofpack append still works" scenario_legacy_root_append

echo ""
echo "Passed: $passed"
echo "Failed: $failed"
if [[ "$failed" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
