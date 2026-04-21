#!/usr/bin/env bash
# test-pack-anti-entropy.sh -- tests for lib/pack-anti-entropy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKER="$SCRIPT_DIR/../lib/pack-anti-entropy.sh"

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

setup_project() {
  local dir="$1"
  local contract_id="sig-20260410-1000-test"
  local artifact_root="$dir/.signum/contracts/$contract_id"
  mkdir -p "$artifact_root" "$dir/.signum/contracts"
  cat > "$dir/.signum/contracts/index.json" <<EOF
{"activeContractId":"$contract_id","contracts":[{"contractId":"$contract_id","status":"auditing","directory":".signum/contracts/$contract_id"}]}
EOF
  cat > "$artifact_root/contract.json" <<'EOF'
{"schemaVersion":"3.8","cleanupObligations":[],"removals":[]}
EOF
  cat > "$artifact_root/proofpack.json" <<'EOF'
{
  "schemaVersion":"4.7",
  "signumVersion":"4.19.1",
  "createdAt":"2026-04-10T10:00:00Z",
  "runId":"signum-test",
  "decision":"AUTO_OK",
  "summary":"ok",
  "contract":{"sha256":"x","sizeBytes":1,"status":"present"},
  "diff":{"sha256":"x","sizeBytes":1,"status":"present"},
  "checks":{"mechanic":{"sha256":"x","sizeBytes":1,"status":"present"},"reviews":{},"auditSummary":{"sha256":"x","sizeBytes":1,"status":"present"}}
}
EOF
}

artifact_report() {
  local dir="$1"
  printf '%s\n' "$dir/.signum/contracts/sig-20260410-1000-test/anti_entropy_report.json"
}

artifact_contract() {
  local dir="$1"
  printf '%s\n' "$dir/.signum/contracts/sig-20260410-1000-test/contract.json"
}

echo "=== Packer existence ==="
assert_pass "packer file exists" test -f "$PACKER"
assert_pass "packer is executable after chmod" chmod +x "$PACKER"

echo ""
echo "=== Success path ==="
SUCCESS="$WORK/success"
setup_project "$SUCCESS"
assert_pass "packer exits 0 on success" "$PACKER" --project-root "$SUCCESS" --as-of 2026-04-10
assert_pass "report artifact written under active contract dir" test -f "$(artifact_report "$SUCCESS")"
assert_equals "report artifact status ok" "$(jq -r '.status' "$(artifact_report "$SUCCESS")")" "ok"

echo ""
echo "=== Fallback path ==="
FAILCASE="$WORK/fail"
setup_project "$FAILCASE"
printf '{bad json\n' > "$(artifact_contract "$FAILCASE")"
assert_pass "packer still exits 0 on reporter failure" "$PACKER" --project-root "$FAILCASE" --as-of 2026-04-10
assert_pass "fallback report artifact written in active contract dir" test -f "$(artifact_report "$FAILCASE")"
assert_equals "fallback report status error" "$(jq -r '.status' "$(artifact_report "$FAILCASE")")" "error"

echo ""
echo "=== Auto-import metric ratchet ==="
METRICCASE="$WORK/metric"
setup_project "$METRICCASE"
mkdir -p "$METRICCASE/.signum/metrics"
cat > "$METRICCASE/.signum/metrics/ratchet-report.json" <<'EOF'
{
  "status": "regression",
  "regressions": [
    {
      "metric": "AUTO_OK rate",
      "previous": 90,
      "current": 60,
      "delta": -30
    }
  ]
}
EOF
assert_pass "packer exits 0 with auto-discovered metrics" "$PACKER" --project-root "$METRICCASE" --as-of 2026-04-10
assert_equals "metric case report status warn" "$(jq -r '.status' "$(artifact_report "$METRICCASE")")" "warn"
assert_equals "metric ratchet source imported" "$(jq -r '.sources | index("metric_ratchet") != null' "$(artifact_report "$METRICCASE")")" "true"
assert_equals "metric regression finding present" "$(jq -r '[.findings[] | select(.category=="metric_regression")] | length' "$(artifact_report "$METRICCASE")")" "1"

echo ""
echo "=== Explicit doc parity import ==="
DOCCASE="$WORK/doc-parity"
setup_project "$DOCCASE"
cat > "$DOCCASE/doc-parity.json" <<'EOF'
{
  "status": "warn",
  "findings": [
    {
      "code": "canonical_source_missing",
      "file": "docs/reference.md",
      "message": "Canonical source policy missing",
      "details": "Root command policy section not found"
    }
  ]
}
EOF
assert_pass "packer exits 0 with explicit doc parity JSON" "$PACKER" --project-root "$DOCCASE" --doc-parity-json "$DOCCASE/doc-parity.json" --as-of 2026-04-10
assert_equals "doc parity case report status warn" "$(jq -r '.status' "$(artifact_report "$DOCCASE")")" "warn"
assert_equals "doc parity source imported" "$(jq -r '.sources | index("doc_parity") != null' "$(artifact_report "$DOCCASE")")" "true"
assert_equals "docs sync finding present" "$(jq -r '[.findings[] | select(.category=="docs_sync")] | length' "$(artifact_report "$DOCCASE")")" "1"
assert_equals "docs sync target file propagated" "$(jq -r '.findings[] | select(.category=="docs_sync") | .target' "$(artifact_report "$DOCCASE")")" "docs/reference.md"

echo ""
echo "=== Output path infers canonical inputs ==="
OUTPUTCASE="$WORK/output"
setup_project "$OUTPUTCASE"
OUTPUT_PATH="$OUTPUTCASE/.signum/contracts/sig-20260410-1000-test/anti_entropy_report.json"
rm -f "$OUTPUT_PATH"
assert_pass "packer infers contract and proofpack from output dir" "$PACKER" --project-root "$OUTPUTCASE" --output "$OUTPUT_PATH" --as-of 2026-04-10
assert_pass "explicit output path created" test -f "$OUTPUT_PATH"
assert_equals "explicit output status ok" "$(jq -r '.status' "$OUTPUT_PATH")" "ok"

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
