#!/usr/bin/env bash
# test-pipeline.sh — full pipeline E2E: contract → sanitize → holdout verify → report
# Replicates Steps 1.5 + 3.1.5 from commands/signum.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/../../lib/dsl-runner.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
PROJECT_ROOT="$SCRIPT_DIR/../.."
CONTRACT="$FIXTURES/pipeline-contract.json"

passed=0
failed=0

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

assert_ne() {
  local name="$1" actual="$2" not_expected="$3"
  if [[ "$actual" != "$not_expected" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — got unexpected "%s"\n' "$name" "$actual"
    failed=$((failed + 1))
  fi
}

printf 'Full pipeline E2E tests\n'
printf '========================\n'

TMPDIR_E2E=$(mktemp -d)
trap 'rm -rf "$TMPDIR_E2E"' EXIT

chmod +x "$RUNNER"

# ============================================================
# Phase 1: Contract Sanitization (Step 1.5)
# ============================================================
printf '\n--- Phase 1: Contract Sanitization ---\n'

# 1. Count visible and holdout ACs in original contract
TOTAL_ACS=$(jq '.acceptanceCriteria | length' "$CONTRACT")
VISIBLE_ACS=$(jq '[.acceptanceCriteria[] | select(.visibility != "holdout")] | length' "$CONTRACT")
HOLDOUT_ACS=$(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' "$CONTRACT")

assert_eq "total ACs in contract" "$TOTAL_ACS" "5"
assert_eq "visible ACs" "$VISIBLE_ACS" "2"
assert_eq "holdout ACs" "$HOLDOUT_ACS" "3"

# 2. Generate engineer contract (remove holdouts)
jq '{
  schemaVersion, goal, inScope, allowNewFilesUnder, outOfScope,
  acceptanceCriteria: [.acceptanceCriteria[] | select(.visibility != "holdout")],
  assumptions, openQuestions, riskLevel, riskSignals, requiredInputsProvided
} | with_entries(select(.value != null))' "$CONTRACT" > "$TMPDIR_E2E/contract-engineer.json"

ENG_ACS=$(jq '.acceptanceCriteria | length' "$TMPDIR_E2E/contract-engineer.json")
assert_eq "engineer contract has only visible ACs" "$ENG_ACS" "2"

# 3. Verify no holdout ACs leaked to engineer contract
ENG_HOLDOUT=$(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' "$TMPDIR_E2E/contract-engineer.json")
assert_eq "engineer contract has zero holdout ACs" "$ENG_HOLDOUT" "0"

# 4. Generate holdout manifest (count + hash)
HOLDOUT_HASH=$(jq -c '[.acceptanceCriteria[] | select(.visibility == "holdout")]' "$CONTRACT" | shasum -a 256 | cut -c1-16)
jq --argjson count "$HOLDOUT_ACS" --arg hash "sha256:$HOLDOUT_HASH" \
  '. + {holdoutManifest: {count: $count, hash: $hash}}' \
  "$TMPDIR_E2E/contract-engineer.json" > "$TMPDIR_E2E/contract-engineer-tmp.json"
mv "$TMPDIR_E2E/contract-engineer-tmp.json" "$TMPDIR_E2E/contract-engineer.json"

MANIFEST_COUNT=$(jq '.holdoutManifest.count' "$TMPDIR_E2E/contract-engineer.json")
MANIFEST_HASH=$(jq -r '.holdoutManifest.hash' "$TMPDIR_E2E/contract-engineer.json")

assert_eq "manifest count matches holdout count" "$MANIFEST_COUNT" "3"
assert_ne "manifest hash is not empty" "$MANIFEST_HASH" ""
assert_ne "manifest hash is not null" "$MANIFEST_HASH" "null"

# 5. Verify hash is deterministic (re-compute → same result)
HOLDOUT_HASH_2=$(jq -c '[.acceptanceCriteria[] | select(.visibility == "holdout")]' "$CONTRACT" | shasum -a 256 | cut -c1-16)
assert_eq "holdout hash is deterministic" "$HOLDOUT_HASH" "$HOLDOUT_HASH_2"

# ============================================================
# Phase 2: Holdout Verification (Step 3.1.5)
# ============================================================
printf '\n--- Phase 2: Holdout Verification ---\n'

PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0
RESULTS="[]"

for i in $(seq 0 $((HOLDOUT_ACS - 1))); do
  ID=$(jq -r "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].id" "$CONTRACT")
  DESC=$(jq -r "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].description" "$CONTRACT")

  VERIFY_FILE=$(mktemp)
  jq "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].verify" "$CONTRACT" > "$VERIFY_FILE"

  # Validate DSL
  if ! "$RUNNER" validate "$VERIFY_FILE" > /dev/null 2>&1; then
    ERROR_COUNT=$((ERROR_COUNT + 1))
    RESULTS=$(echo "$RESULTS" | jq --arg id "$ID" --arg desc "$DESC" \
      '. + [{"id": $id, "description": $desc, "status": "ERROR", "error": "DSL validation failed"}]')
    printf '  HOLDOUT ERROR: %s (invalid DSL)\n' "$DESC"
  else
    # Run DSL
    REPORT=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$VERIFY_FILE" 2>&1) || true
    STATUS=$(echo "$REPORT" | jq -r '.status // "ERROR"')
    ERROR=$(echo "$REPORT" | jq -r '.error // empty')

    if [ "$STATUS" = "PASS" ]; then
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf '  HOLDOUT FAIL: %s (%s)\n' "$DESC" "$ERROR"
    fi
    RESULTS=$(echo "$RESULTS" | jq --arg id "$ID" --arg desc "$DESC" --arg st "$STATUS" --arg err "$ERROR" \
      '. + [{"id": $id, "description": $desc, "status": $st, "error": (if $err == "" then null else $err end)}]')
  fi
  rm -f "$VERIFY_FILE"
done

# Build holdout_report.json
echo "$RESULTS" | jq --argjson pass "$PASS_COUNT" --argjson fail "$FAIL_COUNT" --argjson err "$ERROR_COUNT" \
  '{total: ($pass + $fail + $err), passed: $pass, failed: $fail, errors: $err, results: .}' \
  > "$TMPDIR_E2E/holdout_report.json"

# ============================================================
# Phase 3: Report Validation
# ============================================================
printf '\n--- Phase 3: Report Validation ---\n'

REPORT_TOTAL=$(jq '.total' "$TMPDIR_E2E/holdout_report.json")
REPORT_PASSED=$(jq '.passed' "$TMPDIR_E2E/holdout_report.json")
REPORT_FAILED=$(jq '.failed' "$TMPDIR_E2E/holdout_report.json")
REPORT_ERRORS=$(jq '.errors' "$TMPDIR_E2E/holdout_report.json")
REPORT_RESULTS_COUNT=$(jq '.results | length' "$TMPDIR_E2E/holdout_report.json")

assert_eq "report total = 3" "$REPORT_TOTAL" "3"
assert_eq "report passed = 3" "$REPORT_PASSED" "3"
assert_eq "report failed = 0" "$REPORT_FAILED" "0"
assert_eq "report errors = 0" "$REPORT_ERRORS" "0"
assert_eq "report results array has 3 entries" "$REPORT_RESULTS_COUNT" "3"

# Each holdout result has correct structure
for i in 0 1 2; do
  HAS_ID=$(jq -r ".results[$i] | has(\"id\")" "$TMPDIR_E2E/holdout_report.json")
  HAS_STATUS=$(jq -r ".results[$i] | has(\"status\")" "$TMPDIR_E2E/holdout_report.json")
  STATUS=$(jq -r ".results[$i].status" "$TMPDIR_E2E/holdout_report.json")
  assert_eq "result[$i] has id" "$HAS_ID" "true"
  assert_eq "result[$i] status = PASS" "$STATUS" "PASS"
done

# ============================================================
# Phase 4: Synthesizer Decision Rules
# ============================================================
printf '\n--- Phase 4: Synthesizer Decision Rules ---\n'

# AUTO_OK condition: failed == 0 AND errors == 0
if [[ "$REPORT_FAILED" -eq 0 && "$REPORT_ERRORS" -eq 0 ]]; then
  SYNTH_DECISION="AUTO_OK_ELIGIBLE"
else
  SYNTH_DECISION="BLOCK"
fi
assert_eq "synthesizer: holdout eligible for AUTO_OK" "$SYNTH_DECISION" "AUTO_OK_ELIGIBLE"

# ============================================================
# Phase 5: Negative Test — Holdout FAIL Scenario
# ============================================================
printf '\n--- Phase 5: Holdout Failure Detection ---\n'

# Create a contract where a holdout WILL fail
FAIL_CONTRACT="$TMPDIR_E2E/fail-contract.json"
cat > "$FAIL_CONTRACT" << 'FAILEOF'
{
  "schemaVersion": "3.1",
  "trust": "local",
  "goal": "Test that holdout failure is detected correctly",
  "inScope": ["lib/dsl-runner.sh"],
  "acceptanceCriteria": [
    {
      "id": "AC01",
      "description": "File exists",
      "visibility": "visible",
      "verify": {
        "steps": [{"exec": {"argv": ["test", "-f", "lib/dsl-runner.sh"]}}],
        "timeout_ms": 5000
      }
    },
    {
      "id": "HO1",
      "description": "Nonexistent file should not exist",
      "visibility": "holdout",
      "verify": {
        "steps": [
          {"exec": {"argv": ["test", "-f", "this-file-does-not-exist.xyz"]}}
        ],
        "timeout_ms": 5000
      }
    }
  ],
  "riskLevel": "low"
}
FAILEOF

# Run the failing holdout
FAIL_VERIFY=$(mktemp)
jq '[.acceptanceCriteria[] | select(.visibility == "holdout")][0].verify' "$FAIL_CONTRACT" > "$FAIL_VERIFY"
FAIL_REPORT=$(cd "$PROJECT_ROOT" && "$RUNNER" run "$FAIL_VERIFY" 2>&1) || true
FAIL_STATUS=$(echo "$FAIL_REPORT" | jq -r '.status // "ERROR"')
rm -f "$FAIL_VERIFY"

assert_eq "failing holdout detected" "$FAIL_STATUS" "FAIL"

# Synthesizer would BLOCK on this
if [[ "$FAIL_STATUS" != "PASS" ]]; then
  SYNTH_FAIL="BLOCK"
else
  SYNTH_FAIL="AUTO_OK_ELIGIBLE"
fi
assert_eq "synthesizer: failure triggers BLOCK" "$SYNTH_FAIL" "BLOCK"

# ============================================================
# Summary
# ============================================================
printf '\n========================\n'
printf 'Results: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]] || exit 1
