#!/usr/bin/env bash
# test-brownfield-harness-flow.sh -- downstream-style brownfield integration test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAFFOLD="$SCRIPT_DIR/../lib/init-harness-scaffold.sh"
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
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

setup_brownfield_repo() {
  local dir="$1"
  local contract_id="sig-20260410-1000-test"
  local artifact_root="$dir/.signum/contracts/$contract_id"
  mkdir -p "$dir/src/legacy" "$artifact_root" "$dir/.signum/contracts"

  cat > "$dir/README.md" <<'DOC'
# Downstream Example

Brownfield service repo used to validate Signum bootstrap and advisory anti-entropy behavior.
DOC

  cat > "$dir/project.intent.md" <<'DOC'
# Existing Intent

- Preserve this file in brownfield harness mode.
- Do not replace repo-specific language.
DOC

  cat > "$dir/project.glossary.json" <<'DOC'
{
  "schemaVersion": "1.0",
  "canonicalTerms": [
    {"term": "Tenant", "definition": "Top-level customer account"}
  ],
  "aliases": {
    "workspace": "Tenant"
  }
}
DOC

  cat > "$dir/modules.yaml" <<'DOC'
modules:
  - path: src/legacy
    name: legacy-worker
    status: deprecated
    remove_after: 2026-01-01
DOC

  cat > "$dir/.signum/contracts/index.json" <<EOF
{"activeContractId":"$contract_id","contracts":[{"contractId":"$contract_id","status":"auditing","directory":".signum/contracts/$contract_id"}]}
EOF

  cat > "$artifact_root/contract.json" <<'DOC'
{"schemaVersion":"3.8","cleanupObligations":[],"removals":[]}
DOC

  cat > "$artifact_root/proofpack.json" <<'DOC'
{
  "schemaVersion":"4.7",
  "signumVersion":"4.19.1",
  "createdAt":"2026-04-10T10:00:00Z",
  "runId":"downstream-brownfield-test",
  "decision":"AUTO_OK",
  "summary":"ok",
  "contract":{"sha256":"x","sizeBytes":1,"status":"present"},
  "diff":{"sha256":"x","sizeBytes":1,"status":"present"},
  "checks":{"mechanic":{"sha256":"x","sizeBytes":1,"status":"present"},"reviews":{},"auditSummary":{"sha256":"x","sizeBytes":1,"status":"present"}}
}
DOC
}

write_scaffold_files() {
  local dir="$1"
  local scaffold_file="$2"
  python3 - "$dir" "$scaffold_file" <<'PY'
import json, os, sys
root, scaffold_path = sys.argv[1:]
with open(scaffold_path, encoding="utf-8") as f:
    data = json.load(f)
for item in data.get("files", []):
    path = os.path.join(root, item["path"])
    os.makedirs(os.path.dirname(path) or root, exist_ok=True)
    with open(path, "w", encoding="utf-8") as out:
        out.write(item["content"])
PY
}

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

echo "=== Tooling existence ==="
assert_pass "scaffold exists" test -f "$SCAFFOLD"
assert_pass "packer exists" test -f "$PACKER"

BROWNFIELD="$WORK/downstream"
setup_brownfield_repo "$BROWNFIELD"
INTENT_HASH_BEFORE="$(hash_file "$BROWNFIELD/project.intent.md")"
GLOSSARY_HASH_BEFORE="$(hash_file "$BROWNFIELD/project.glossary.json")"

echo ""
echo "=== Brownfield harness scaffold ==="
SCAFFOLD_JSON="$($SCAFFOLD --project-root "$BROWNFIELD" --as-of 2026-04-10 2>/dev/null)"
SCAFFOLD_FILE="$WORK/scaffold.json"
printf '%s\n' "$SCAFFOLD_JSON" > "$SCAFFOLD_FILE"

assert_equals "scaffold emits six harness docs" "$(echo "$SCAFFOLD_JSON" | jq -r '.files | length')" "6"
assert_equals "all harness docs missing in brownfield repo" "$(echo "$SCAFFOLD_JSON" | jq -r '.missingCount')" "6"
assert_equals "intent file omitted from scaffold output" "$(echo "$SCAFFOLD_JSON" | jq -r '[.files[].path] | index("project.intent.md") == null')" "true"
assert_equals "glossary file omitted from scaffold output" "$(echo "$SCAFFOLD_JSON" | jq -r '[.files[].path] | index("project.glossary.json") == null')" "true"

write_scaffold_files "$BROWNFIELD" "$SCAFFOLD_FILE"

assert_pass "AGENTS scaffold written" test -f "$BROWNFIELD/AGENTS.md"
assert_pass "ARCHITECTURE scaffold written" test -f "$BROWNFIELD/ARCHITECTURE.md"
assert_pass "PLANS scaffold written" test -f "$BROWNFIELD/docs/PLANS.md"
assert_pass "RELIABILITY scaffold written" test -f "$BROWNFIELD/docs/RELIABILITY.md"
assert_pass "SECURITY scaffold written" test -f "$BROWNFIELD/docs/SECURITY.md"
assert_pass "QUALITY_SCORE scaffold written" test -f "$BROWNFIELD/docs/QUALITY_SCORE.md"
assert_equals "existing intent preserved" "$(hash_file "$BROWNFIELD/project.intent.md")" "$INTENT_HASH_BEFORE"
assert_equals "existing glossary preserved" "$(hash_file "$BROWNFIELD/project.glossary.json")" "$GLOSSARY_HASH_BEFORE"

echo ""
echo "=== Advisory anti-entropy artifact ==="
assert_pass "packer exits 0 for brownfield repo" "$PACKER" --project-root "$BROWNFIELD" --as-of 2026-04-10
assert_pass "anti-entropy report written in canonical artifact root" test -f "$BROWNFIELD/.signum/contracts/sig-20260410-1000-test/anti_entropy_report.json"
assert_equals "anti-entropy report is warn due to overdue module" "$(jq -r '.status' "$BROWNFIELD/.signum/contracts/sig-20260410-1000-test/anti_entropy_report.json")" "warn"
assert_equals "modules.yaml imported as source" "$(jq -r '.sources | index("modules_yaml") != null' "$BROWNFIELD/.signum/contracts/sig-20260410-1000-test/anti_entropy_report.json")" "true"
assert_equals "overdue module finding present" "$(jq -r '[.findings[] | select(.category=="module_deadline_passed")] | length' "$BROWNFIELD/.signum/contracts/sig-20260410-1000-test/anti_entropy_report.json")" "1"
assert_equals "finding targets legacy module path" "$(jq -r '.findings[] | select(.category=="module_deadline_passed") | .target' "$BROWNFIELD/.signum/contracts/sig-20260410-1000-test/anti_entropy_report.json")" "src/legacy"

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
