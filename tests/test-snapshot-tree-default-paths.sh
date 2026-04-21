#!/usr/bin/env bash
# test-snapshot-tree-default-paths.sh -- default path discovery for lib/snapshot-tree.sh
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT_SCRIPT="$ROOT_DIR/lib/snapshot-tree.sh"

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

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

scenario_canonical_default() {
  local repo contract_id output summary_path manifest_path signum_dir
  repo="$WORK/canonical"
  contract_id="sig-20260421-1245-abcd"
  mkdir -p "$repo/.signum/contracts/$contract_id" "$repo/src"
  printf 'hello\n' > "$repo/src/greeting.txt"
  cat > "$repo/.signum/contracts/index.json" <<EOFJSON
{
  "activeContractId": "$contract_id",
  "contracts": [
    {
      "contractId": "$contract_id",
      "status": "executing",
      "directory": ".signum/contracts/$contract_id/"
    }
  ]
}
EOFJSON

  output=$(cd "$repo" && "$SNAPSHOT_SCRIPT" pre-execute)
  summary_path="$repo/.signum/contracts/$contract_id/snapshots/pre-execute.json"
  manifest_path="$repo/.signum/contracts/$contract_id/snapshots/pre-execute.manifest"
  signum_dir=$(jq -r '.signum_dir' "$summary_path")

  [[ "$output" == "$summary_path" ]]
  [[ -f "$summary_path" ]]
  [[ -f "$manifest_path" ]]
  [[ "$signum_dir" == "$repo/.signum/contracts/$contract_id" ]]
}

scenario_legacy_fallback() {
  local repo output summary_path manifest_path signum_dir
  repo="$WORK/legacy"
  mkdir -p "$repo/.signum" "$repo/src"
  printf 'hello\n' > "$repo/src/greeting.txt"

  output=$(cd "$repo" && "$SNAPSHOT_SCRIPT" pre-execute)
  summary_path="$repo/.signum/snapshots/pre-execute.json"
  manifest_path="$repo/.signum/snapshots/pre-execute.manifest"
  signum_dir=$(jq -r '.signum_dir' "$summary_path")

  [[ "$output" == "$summary_path" ]]
  [[ -f "$summary_path" ]]
  [[ -f "$manifest_path" ]]
  [[ "$signum_dir" == "$repo/.signum" ]]
}

scenario_single_contract_dir_without_index() {
  local repo contract_id output summary_path manifest_path signum_dir
  repo="$WORK/single-canonical"
  contract_id="sig-20260421-1305-ef01"
  mkdir -p "$repo/.signum/contracts/$contract_id" "$repo/src"
  printf 'hello\n' > "$repo/src/greeting.txt"

  output=$(cd "$repo" && "$SNAPSHOT_SCRIPT" pre-execute)
  summary_path="$repo/.signum/contracts/$contract_id/snapshots/pre-execute.json"
  manifest_path="$repo/.signum/contracts/$contract_id/snapshots/pre-execute.manifest"
  signum_dir=$(jq -r '.signum_dir' "$summary_path")

  [[ "$output" == "$summary_path" ]]
  [[ -f "$summary_path" ]]
  [[ -f "$manifest_path" ]]
  [[ "$signum_dir" == "$repo/.signum/contracts/$contract_id" ]]
}

echo "=== Snapshot tree default paths ==="
SCRIPT_TEXT="$(cat "$SNAPSHOT_SCRIPT")"
assert_contains "snapshot-tree example uses canonical artifact root variable" 'ARTIFACT_ROOT=".signum/contracts/<contractId>"' "$SCRIPT_TEXT"
assert_contains "snapshot-tree example uses canonical iterations lane path" 'lib/snapshot-tree.sh lane-A --workspace-root "$ARTIFACT_ROOT/iterations/01/lanes/A" \' "$SCRIPT_TEXT"
assert_contains "snapshot-tree example uses canonical signum-dir path" '--signum-dir "$ARTIFACT_ROOT"' "$SCRIPT_TEXT"
assert_not_contains "snapshot-tree example no longer uses root .signum lane dir" '--signum-dir .signum/iterations/01/lanes/A/.signum' "$SCRIPT_TEXT"
assert_ok "snapshot-tree defaults to canonical active contract root" scenario_canonical_default
assert_ok "snapshot-tree defaults to single canonical contract dir without index" scenario_single_contract_dir_without_index
assert_ok "snapshot-tree still falls back to legacy root .signum" scenario_legacy_fallback

echo ""
echo "Passed: $passed"
echo "Failed: $failed"
if [[ "$failed" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
