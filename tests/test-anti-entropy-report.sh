#!/usr/bin/env bash
# test-anti-entropy-report.sh -- tests for lib/anti-entropy-report.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORTER="$SCRIPT_DIR/../lib/anti-entropy-report.sh"

passed=0
failed=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_pass() {
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

assert_equals() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected \"%s\", got \"%s\"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected to find \"%s\"\n' "$name" "$needle"
    failed=$((failed + 1))
  fi
}

echo "=== Reporter existence ==="
assert_pass "reporter file exists" test -f "$REPORTER"
assert_pass "reporter is executable after chmod" chmod +x "$REPORTER"

setup_clean_project() {
  local dir="$1"
  mkdir -p "$dir/.signum" "$dir/docs"

  cat > "$dir/.signum/contract.json" <<'EOF'
{
  "schemaVersion": "3.8",
  "contractId": "sig-1",
  "cleanupObligations": [
    {
      "id": "CO01",
      "action": "update_imports",
      "target": "src/**/*.py",
      "description": "Remove old imports",
      "blocking": true
    }
  ],
  "removals": [
    {
      "id": "RM01",
      "path": "src/old-auth/",
      "reason": "Deprecated auth module",
      "type": "directory",
      "modulesYamlTransition": "deprecated_to_removed"
    }
  ]
}
EOF

  cat > "$dir/.signum/proofpack.json" <<'EOF'
{
  "schemaVersion": "4.7",
  "signumVersion": "4.17.0",
  "createdAt": "2026-04-10T10:00:00Z",
  "runId": "signum-test",
  "decision": "AUTO_OK",
  "summary": "ok",
  "contract": {"sha256":"x","sizeBytes":1,"status":"present"},
  "diff": {"sha256":"x","sizeBytes":1,"status":"present"},
  "checks": {
    "mechanic": {"sha256":"x","sizeBytes":1,"status":"present"},
    "reviews": {},
    "auditSummary": {"sha256":"x","sizeBytes":1,"status":"present"}
  },
  "removalEvidence": {
    "removals": [
      {"id":"RM01","path":"src/old-auth/","type":"directory","removed":true,"orphanReferences":0,"modulesYamlUpdated":true}
    ],
    "obligations": [
      {"id":"CO01","action":"update_imports","fulfilled":true,"blocking":true,"verifyOutput":"ok"}
    ]
  }
}
EOF

  cat > "$dir/modules.yaml" <<'EOF'
version: 1
modules:
  - path: src/auth/
    name: auth
    status: active
    owner: "@vi"
EOF
}

echo ""
echo "=== Clean case ==="
CLEAN="$WORK/clean"
setup_clean_project "$CLEAN"
CLEAN_OUT=$("$REPORTER" --project-root "$CLEAN" --as-of 2026-04-10 2>/dev/null)
assert_pass "clean project exits 0" "$REPORTER" --project-root "$CLEAN" --as-of 2026-04-10
assert_equals "clean status ok" "$(echo "$CLEAN_OUT" | jq -r '.status')" "ok"
assert_equals "clean findings empty" "$(echo "$CLEAN_OUT" | jq -r '.findings | length')" "0"
assert_contains "clean sources include cleanup" "$(echo "$CLEAN_OUT" | jq -r '.sources | join(",")')" "cleanup_obligations"
assert_contains "clean sources include modules" "$(echo "$CLEAN_OUT" | jq -r '.sources | join(",")')" "modules_yaml"

echo ""
echo "=== Cleanup and modules findings ==="
DIRTY="$WORK/dirty"
setup_clean_project "$DIRTY"
mkdir -p "$DIRTY/src/old-auth"
cat > "$DIRTY/modules.yaml" <<'EOF'
version: 1
modules:
  - path: src/old-auth/
    name: old-auth
    status: deprecated
    remove_after: "2026-04-01"
  - path: src/ghost/
    name: ghost
    status: removed
EOF
cat > "$DIRTY/.signum/proofpack.json" <<'EOF'
{
  "schemaVersion": "4.7",
  "signumVersion": "4.17.0",
  "createdAt": "2026-04-10T10:00:00Z",
  "runId": "signum-test",
  "decision": "AUTO_OK",
  "summary": "warn",
  "contract": {"sha256":"x","sizeBytes":1,"status":"present"},
  "diff": {"sha256":"x","sizeBytes":1,"status":"present"},
  "checks": {
    "mechanic": {"sha256":"x","sizeBytes":1,"status":"present"},
    "reviews": {},
    "auditSummary": {"sha256":"x","sizeBytes":1,"status":"present"}
  },
  "removalEvidence": {
    "removals": [
      {"id":"RM01","path":"src/old-auth/","type":"directory","removed":false,"orphanReferences":2,"modulesYamlUpdated":false}
    ],
    "obligations": [
      {"id":"CO01","action":"update_imports","fulfilled":false,"blocking":true,"verifyOutput":"imports remain"}
    ]
  }
}
EOF

DIRTY_OUT=$("$REPORTER" --project-root "$DIRTY" --as-of 2026-04-10 2>/dev/null)
assert_equals "dirty status warn" "$(echo "$DIRTY_OUT" | jq -r '.status')" "warn"
assert_equals "dirty findings count" "$(echo "$DIRTY_OUT" | jq -r '.findings | length')" "5"
assert_contains "unfulfilled cleanup finding present" "$(echo "$DIRTY_OUT" | jq -r '.findings[].category')" "cleanup_obligation_unfulfilled"
assert_contains "removal incomplete finding present" "$(echo "$DIRTY_OUT" | jq -r '.findings[].category')" "removal_incomplete"
assert_contains "orphan references finding present" "$(echo "$DIRTY_OUT" | jq -r '.findings[].category')" "removal_orphan_references"
assert_contains "modules sync finding present" "$(echo "$DIRTY_OUT" | jq -r '.findings[].category')" "module_manifest_sync_missing"
assert_contains "deadline finding present" "$(echo "$DIRTY_OUT" | jq -r '.findings[].category')" "module_deadline_passed"

echo ""
echo "=== Imported doc parity + metric ratchet ==="
IMPORTED="$WORK/imported"
setup_clean_project "$IMPORTED"
cat > "$IMPORTED/doc-parity.json" <<'EOF'
{
  "check": "doc_parity",
  "status": "warn",
  "summary": "1 finding",
  "findings": [
    {
      "code": "phase_inventory_mismatch",
      "file": "commands/signum.md",
      "message": "Phase inventory mismatch",
      "details": "root vs overlay differ"
    }
  ]
}
EOF
cat > "$IMPORTED/ratchet.json" <<'EOF'
{
  "status": "regression",
  "regressions": [
    {
      "metric": "AUTO_OK rate",
      "previous": 90,
      "current": 70,
      "delta": -20
    }
  ]
}
EOF
IMPORTED_OUT=$("$REPORTER" --project-root "$IMPORTED" --as-of 2026-04-10 --doc-parity-json "$IMPORTED/doc-parity.json" --metric-ratchet-json "$IMPORTED/ratchet.json" 2>/dev/null)
assert_contains "doc parity source imported" "$(echo "$IMPORTED_OUT" | jq -r '.sources | join(",")')" "doc_parity"
assert_contains "metric ratchet source imported" "$(echo "$IMPORTED_OUT" | jq -r '.sources | join(",")')" "metric_ratchet"
assert_contains "docs_sync category imported" "$(echo "$IMPORTED_OUT" | jq -r '.findings[].category')" "docs_sync"
assert_contains "metric_regression category imported" "$(echo "$IMPORTED_OUT" | jq -r '.findings[].category')" "metric_regression"

echo ""
echo "=== Output file ==="
OUT_FILE="$WORK/report.json"
assert_pass "reporter writes output file" "$REPORTER" --project-root "$CLEAN" --as-of 2026-04-10 --output "$OUT_FILE"
assert_pass "output file created" test -f "$OUT_FILE"
assert_equals "output file content is ok status" "$(jq -r '.status' "$OUT_FILE")" "ok"

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
fi
