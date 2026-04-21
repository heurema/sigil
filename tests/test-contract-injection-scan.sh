#!/usr/bin/env bash
# test-contract-injection-scan.sh -- tests canonical and legacy path discovery for lib/contract-injection-scan.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_SCRIPT="$SCRIPT_DIR/../lib/contract-injection-scan.sh"

passed=0
failed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_exit() {
  local name="$1" expected_exit="$2"
  shift 2
  local output exit_code
  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e
  if [ "$exit_code" -eq "$expected_exit" ]; then
    printf '  PASS: %s (exit=%s)\n' "$name" "$exit_code"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- expected exit %s, got %s: %s\n' "$name" "$expected_exit" "$exit_code" "$output"
    failed=$((failed + 1))
  fi
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

write_clean_contract() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "schemaVersion": "3.8",
  "goal": "Ship clean contract",
  "inScope": ["src/app.py"],
  "acceptanceCriteria": [
    {"id": "AC1", "description": "Works", "verify": "pytest"}
  ],
  "riskLevel": "low"
}
JSON
}

write_injected_contract() {
  local path="$1"
  python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
data = {
    "schemaVersion": "3.8",
    "goal": "Ship\u200b injected contract",
    "inScope": ["src/app.py"],
    "acceptanceCriteria": [{"id": "AC1", "description": "Works", "verify": "pytest"}],
    "riskLevel": "low"
}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f)
PY
}

echo "=== Existence ==="
assert_exit "script exists and is executable after chmod" 0 chmod +x "$SCAN_SCRIPT"

echo ""
echo "=== Canonical default path ==="
CANONICAL="$WORK/canonical"
mkdir -p "$CANONICAL/.signum/contracts/sig-20260421-1200-abcd"
cat > "$CANONICAL/.signum/contracts/index.json" <<'JSON'
{
  "activeContractId": "sig-20260421-1200-abcd",
  "contracts": [
    {
      "contractId": "sig-20260421-1200-abcd",
      "status": "draft",
      "directory": ".signum/contracts/sig-20260421-1200-abcd/"
    }
  ]
}
JSON
write_clean_contract "$CANONICAL/.signum/contracts/sig-20260421-1200-abcd/contract.json"
assert_exit "default scan resolves canonical active contract path" 0 bash -lc "cd '$CANONICAL' && '$SCAN_SCRIPT'"

echo ""
echo "=== Legacy fallback ==="
LEGACY="$WORK/legacy"
mkdir -p "$LEGACY/.signum"
write_clean_contract "$LEGACY/.signum/contract.json"
assert_exit "default scan falls back to legacy root contract" 0 bash -lc "cd '$LEGACY' && '$SCAN_SCRIPT'"

echo ""
echo "=== Single canonical contract dir fallback ==="
SINGLE_CANONICAL="$WORK/single-canonical"
mkdir -p "$SINGLE_CANONICAL/.signum/contracts/sig-20260421-1315-cafe"
write_clean_contract "$SINGLE_CANONICAL/.signum/contracts/sig-20260421-1315-cafe/contract.json"
assert_exit "default scan falls back to single canonical contract dir without index" 0 bash -lc "cd '$SINGLE_CANONICAL' && '$SCAN_SCRIPT'"

echo ""
echo "=== Explicit path and blocked unicode ==="
BLOCKED="$WORK/blocked"
mkdir -p "$BLOCKED"
write_injected_contract "$BLOCKED/injected.json"
set +e
BLOCKED_OUTPUT=$("$SCAN_SCRIPT" "$BLOCKED/injected.json" 2>&1)
BLOCKED_EXIT=$?
set -e
if [ "$BLOCKED_EXIT" -eq 1 ]; then
  printf '  PASS: explicit injected contract is blocked (exit=1)\n'
  passed=$((passed + 1))
else
  printf '  FAIL: explicit injected contract -- expected exit 1, got %s: %s\n' "$BLOCKED_EXIT" "$BLOCKED_OUTPUT"
  failed=$((failed + 1))
fi
assert_contains "blocked output mentions invisible Unicode" 'BLOCKED: invisible Unicode' "$BLOCKED_OUTPUT"

echo ""
echo "=== Missing file ==="
MISSING="$WORK/missing"
mkdir -p "$MISSING"
assert_exit "missing default contract returns usage error" 2 bash -lc "cd '$MISSING' && '$SCAN_SCRIPT'"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
