#!/usr/bin/env bash
# test-api-reference.sh -- guard concise API reference navigation and surfaces
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"

API_REFERENCE="$REPO_ROOT/docs/api-reference.md"
ROOT_README="$REPO_ROOT/README.md"
DOCS_README="$REPO_ROOT/docs/README.md"

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

assert_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$name"
  else
    fail "$name" "$file does not contain $needle"
  fi
}

echo "=== API reference documentation ==="

assert_file_exists "API reference exists" "$API_REFERENCE"

assert_contains "API reference links signum command" "$API_REFERENCE" "commands/signum.md"
assert_contains "API reference links init command" "$API_REFERENCE" "commands/init.md"
assert_contains "API reference links runtime reference" "$API_REFERENCE" "docs/reference.md"
assert_contains "API reference links contract schema" "$API_REFERENCE" "lib/schemas/contract.schema.json"
assert_contains "API reference links proofpack schema" "$API_REFERENCE" "lib/schemas/proofpack.schema.json"
assert_contains "API reference links proofpack validator" "$API_REFERENCE" "scripts/validate_proofpack.py"
assert_contains "API reference links CI wrapper" "$API_REFERENCE" "lib/signum-ci.sh"
assert_contains "API reference links gate template" "$API_REFERENCE" "lib/templates/signum-gate.yml"
assert_contains "API reference links policy scanner" "$API_REFERENCE" "lib/policy-scanner.sh"
assert_contains "API reference links init scanner wrapper" "$API_REFERENCE" "lib/init-scanner.sh"
assert_contains "API reference links init scanner implementation" "$API_REFERENCE" "scripts/init_scanner.py"
assert_contains "API reference documents AUTO_OK" "$API_REFERENCE" "AUTO_OK"
assert_contains "API reference documents AUTO_BLOCK" "$API_REFERENCE" "AUTO_BLOCK"
assert_contains "API reference documents HUMAN_REVIEW" "$API_REFERENCE" "HUMAN_REVIEW"
assert_contains "API reference shows canonical proofpack path" "$API_REFERENCE" ".signum/contracts/<contractId>/proofpack.json"

assert_contains "root README links API reference" "$ROOT_README" "docs/api-reference.md"
assert_contains "docs README links API reference" "$DOCS_README" "api-reference.md"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
