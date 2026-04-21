#!/usr/bin/env bash
# test-verifier-default-paths.sh -- default path discovery for boundary/transition verifiers
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
LIB_SRC="$ROOT_DIR/lib"
export SIGNUM_TRUST_LOCAL=1

passed=0
failed=0

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

make_repo() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/lib" "$dir/src" "$dir/.signum"
  cp "$LIB_SRC"/*.sh "$dir/lib/"
  chmod +x "$dir/lib/"*.sh
  cat > "$dir/.gitignore" <<'GITEOF'
.signum/
GITEOF
  git -C "$dir" init >/dev/null 2>&1
  printf 'baseline\n' > "$dir/README.md"
  git -C "$dir" add README.md .gitignore >/dev/null 2>&1
  printf '%s\n' "$dir"
}

write_contract_pair() {
  local contract_path="$1"
  local engineer_path="$2"
  local context_path="$3"
  cat > "$contract_path" <<'EOFJSON'
{
  "schemaVersion": "3.8",
  "contractId": "sig-20260421-1215-test",
  "goal": "Create a greeting artifact with deterministic receipt verification.",
  "inScope": ["src/greeting.txt"],
  "acceptanceCriteria": [
    {
      "id": "AC01",
      "description": "Greeting file exists",
      "visibility": "visible",
      "verify": {
        "steps": [
          {"exec": {"argv": ["test", "-f", "src/greeting.txt"]}}
        ],
        "timeout_ms": 5000
      }
    },
    {
      "id": "AC02",
      "description": "Greeting file contains hello",
      "visibility": "visible",
      "verify": {
        "steps": [
          {"exec": {"argv": ["cat", "src/greeting.txt"]}, "capture": "greeting"},
          {"expect": {"stdout_contains": "hello", "source": "greeting"}}
        ],
        "timeout_ms": 5000
      }
    }
  ],
  "riskLevel": "medium"
}
EOFJSON
  cp "$contract_path" "$engineer_path"
  cat > "$context_path" <<'EOFJSON'
{"base_commit":"no-git","started_at":"2026-04-21T12:15:00Z","run_id":"sig-20260421-1215-test"}
EOFJSON
}

simulate_engineer_success() {
  local workspace="$1"
  local signum_dir="$2"
  mkdir -p "$workspace/src"
  printf 'hello world\n' > "$workspace/src/greeting.txt"
  printf 'diff --git a/src/greeting.txt b/src/greeting.txt\n' > "$signum_dir/combined.patch"
  cat > "$signum_dir/execute_log.json" <<'EOFJSON'
{"status":"SUCCESS","totalAttempts":1,"maxAttempts":3}
EOFJSON
}

scenario_canonical_defaults() {
  local dir artifact_root
  dir=$(make_repo)
  artifact_root="$dir/.signum/contracts/sig-20260421-1215-test"
  mkdir -p "$artifact_root" "$dir/.signum/contracts"
  cat > "$dir/.signum/contracts/index.json" <<'EOFJSON'
{
  "activeContractId": "sig-20260421-1215-test",
  "contracts": [
    {
      "contractId": "sig-20260421-1215-test",
      "status": "executing",
      "directory": ".signum/contracts/sig-20260421-1215-test/"
    }
  ]
}
EOFJSON
  write_contract_pair "$artifact_root/contract.json" "$artifact_root/contract-engineer.json" "$artifact_root/execution_context.json"
  (cd "$dir" && lib/snapshot-tree.sh pre-execute --signum-dir "$artifact_root" >/dev/null)
  simulate_engineer_success "$dir" "$artifact_root"
  (cd "$dir" && lib/boundary-verifier.sh execute >/dev/null)
  (cd "$dir" && lib/transition-verifier.sh execute audit >/dev/null)
  test -f "$artifact_root/receipts/execute.json"
  test -f "$artifact_root/runs/sig-20260421-1215-test/execute-01.json"
}

scenario_legacy_fallback() {
  local dir
  dir=$(make_repo)
  mkdir -p "$dir/.signum"
  write_contract_pair "$dir/.signum/contract.json" "$dir/.signum/contract-engineer.json" "$dir/.signum/execution_context.json"
  (cd "$dir" && lib/snapshot-tree.sh pre-execute >/dev/null)
  simulate_engineer_success "$dir" "$dir/.signum"
  (cd "$dir" && lib/boundary-verifier.sh execute >/dev/null)
  (cd "$dir" && lib/transition-verifier.sh execute audit >/dev/null)
  test -f "$dir/.signum/receipts/execute.json"
  test -f "$dir/.signum/runs/sig-20260421-1215-test/execute-01.json"
}

echo "=== Verifier default paths ==="
assert_ok "boundary/transition default to canonical active contract root" scenario_canonical_defaults
assert_ok "boundary/transition still fall back to legacy root .signum" scenario_legacy_fallback

echo ""
echo "Passed: $passed"
echo "Failed: $failed"
if [[ "$failed" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
