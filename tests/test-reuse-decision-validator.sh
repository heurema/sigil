#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT_DIR/scripts/validate_reuse_decision.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

write_contract() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/contract.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "goal": "Reuse existing validation helpers"
}
JSON
}

write_candidates() {
  local path="$1"
  local count="$2"
  mkdir -p "$(dirname "$path")"
  if [ "$count" -eq 0 ]; then
    cat > "$path" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "candidateCount": 0,
  "candidates": []
}
JSON
  else
    cat > "$path" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "candidateCount": 1,
  "candidates": [
    {
      "candidateId": "cand-001",
      "kind": "existing-helper",
      "path": "src/shared/validation.ts"
    }
  ]
}
JSON
  fi
}

write_valid_decision() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "reuse",
      "action": "Call existing validateEmail helper",
      "rationale": "Candidate matches task intent and is already used by sibling signup flow."
    }
  ],
  "newCodeJustifications": [],
  "summary": "Reused existing validation helper and followed existing test pattern."
}
JSON
}

write_four_candidates() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "candidateCount": 4,
  "candidates": [
    {
      "candidateId": "cand-001",
      "kind": "existing-helper",
      "path": "src/shared/validation.ts",
      "score": 0.91,
      "confidence": 0.88
    },
    {
      "candidateId": "cand-002",
      "kind": "shared-module",
      "path": "src/shared/account.ts",
      "score": 0.62,
      "confidence": 0.64
    },
    {
      "candidateId": "cand-003",
      "kind": "module-boundary",
      "path": "src/shared/",
      "score": 0.55,
      "confidence": 0.58
    },
    {
      "candidateId": "cand-004",
      "kind": "existing-helper",
      "path": "src/shared/optional.ts",
      "score": 0.2,
      "confidence": 0.2
    }
  ]
}
JSON
}

write_high_score_fourth_candidates() {
  local path="$1"
  write_four_candidates "$path"
  python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["candidates"][3]["score"] = 0.8
path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

write_high_confidence_fourth_candidates() {
  local path="$1"
  write_four_candidates "$path"
  python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["candidates"][3]["confidence"] = 0.8
path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

write_high_config_fourth_candidates() {
  local path="$1"
  write_four_candidates "$path"
  python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["candidates"][3]["kind"] = "config-pattern"
data["candidates"][3]["score"] = 0.95
data["candidates"][3]["confidence"] = 0.95
path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

write_top_three_decisions() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "reuse",
      "action": "Call existing validateEmail helper",
      "rationale": "Candidate matches task intent and is already used by sibling signup flow."
    },
    {
      "candidateId": "cand-002",
      "disposition": "adapt",
      "action": "Adapt the account module pattern where the helper boundary differs.",
      "rationale": "Candidate shows a nearby module pattern relevant to the change."
    },
    {
      "candidateId": "cand-003",
      "disposition": "respect-boundary",
      "action": "Keep new code inside the shared module boundary.",
      "rationale": "Candidate identifies the boundary that should constrain the implementation."
    }
  ],
  "newCodeJustifications": [],
  "summary": "Addressed the top three reuse candidates; the fourth candidate is low-score and optional."
}
JSON
}

run_validator() {
  local dir="$1"
  python3 "$VALIDATOR" \
    --contract "$dir/contract.json" \
    --reuse-candidates "$dir/reuse_candidates.json" \
    --reuse-decision "$dir/reuse_decision.json" \
    --mode "${2:-warn}" \
    >"$dir/stdout.txt" 2>"$dir/stderr.txt"
}

expect_exit() {
  local label="$1"
  local expected="$2"
  local dir="$3"
  local mode="${4:-warn}"
  local actual=0

  if run_validator "$dir" "$mode"; then
    actual=0
  else
    actual=$?
  fi

  if [ "$actual" -eq "$expected" ]; then
    pass "$label exits $expected"
  else
    fail "$label exits $expected" "actual exit $actual; stderr=$(cat "$dir/stderr.txt" 2>/dev/null || true)"
  fi
}

assert_stderr_contains() {
  local label="$1"
  local dir="$2"
  local needle="$3"

  if grep -Fq -- "$needle" "$dir/stderr.txt"; then
    pass "$label"
  else
    fail "$label" "missing $needle; stderr=$(cat "$dir/stderr.txt" 2>/dev/null || true)"
  fi
}

echo "=== Reuse decision validator ==="

VALID="$WORK/valid"
write_contract "$VALID"
write_candidates "$VALID/reuse_candidates.json" 1
write_valid_decision "$VALID/reuse_decision.json"
expect_exit "valid decision" 0 "$VALID"

COVERAGE_VALID="$WORK/coverage-valid"
write_contract "$COVERAGE_VALID"
write_four_candidates "$COVERAGE_VALID/reuse_candidates.json"
write_top_three_decisions "$COVERAGE_VALID/reuse_decision.json"
expect_exit "valid decision covering required candidates" 0 "$COVERAGE_VALID"

MISSING="$WORK/missing"
write_contract "$MISSING"
write_candidates "$MISSING/reuse_candidates.json" 1
expect_exit "missing decision" 2 "$MISSING"

INVALID_JSON="$WORK/invalid-json"
write_contract "$INVALID_JSON"
write_candidates "$INVALID_JSON/reuse_candidates.json" 1
printf '{not json\n' > "$INVALID_JSON/reuse_decision.json"
expect_exit "invalid JSON" 3 "$INVALID_JSON"

UNKNOWN="$WORK/unknown-candidate"
write_contract "$UNKNOWN"
write_candidates "$UNKNOWN/reuse_candidates.json" 1
write_valid_decision "$UNKNOWN/reuse_decision.json"
python3 - "$UNKNOWN/reuse_decision.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["decisions"][0]["candidateId"] = "cand-999"
path.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_exit "unknown candidate" 4 "$UNKNOWN"

TOP_OMITTED="$WORK/top-omitted"
write_contract "$TOP_OMITTED"
write_four_candidates "$TOP_OMITTED/reuse_candidates.json"
write_top_three_decisions "$TOP_OMITTED/reuse_decision.json"
python3 - "$TOP_OMITTED/reuse_decision.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["decisions"] = [item for item in data["decisions"] if item["candidateId"] != "cand-001"]
path.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_exit "top candidate omitted" 4 "$TOP_OMITTED"
assert_stderr_contains "top candidate omitted explains required coverage" "$TOP_OMITTED" "required reuse candidate 'cand-001' is not addressed"

SCORE_OMITTED="$WORK/score-omitted"
write_contract "$SCORE_OMITTED"
write_high_score_fourth_candidates "$SCORE_OMITTED/reuse_candidates.json"
write_top_three_decisions "$SCORE_OMITTED/reuse_decision.json"
expect_exit "score >= 0.75 candidate omitted" 4 "$SCORE_OMITTED"
assert_stderr_contains "score omission explains required coverage" "$SCORE_OMITTED" "required reuse candidate 'cand-004' is not addressed"

CONFIDENCE_OMITTED="$WORK/confidence-omitted"
write_contract "$CONFIDENCE_OMITTED"
write_high_confidence_fourth_candidates "$CONFIDENCE_OMITTED/reuse_candidates.json"
write_top_three_decisions "$CONFIDENCE_OMITTED/reuse_decision.json"
expect_exit "confidence >= 0.75 candidate omitted" 4 "$CONFIDENCE_OMITTED"
assert_stderr_contains "confidence omission explains required coverage" "$CONFIDENCE_OMITTED" "required reuse candidate 'cand-004' is not addressed"

LOW_OPTIONAL="$WORK/low-optional"
write_contract "$LOW_OPTIONAL"
write_four_candidates "$LOW_OPTIONAL/reuse_candidates.json"
write_top_three_decisions "$LOW_OPTIONAL/reuse_decision.json"
expect_exit "low-score low-confidence candidate outside top three omitted" 0 "$LOW_OPTIONAL"

CONFIG_OPTIONAL="$WORK/config-optional"
write_contract "$CONFIG_OPTIONAL"
write_high_config_fourth_candidates "$CONFIG_OPTIONAL/reuse_candidates.json"
write_top_three_decisions "$CONFIG_OPTIONAL/reuse_decision.json"
expect_exit "config-pattern candidate outside top three omitted" 0 "$CONFIG_OPTIONAL"

EMPTY_NONZERO="$WORK/empty-nonzero"
write_contract "$EMPTY_NONZERO"
write_candidates "$EMPTY_NONZERO/reuse_candidates.json" 1
cat > "$EMPTY_NONZERO/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "decisions": [],
  "summary": "Will inspect candidates later."
}
JSON
expect_exit "empty decisions with nonzero candidates" 4 "$EMPTY_NONZERO"

ZERO="$WORK/zero-candidates"
write_contract "$ZERO"
write_candidates "$ZERO/reuse_candidates.json" 0
cat > "$ZERO/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "decisions": [],
  "summary": "No reusable candidates were available for this task."
}
JSON
expect_exit "zero candidates" 0 "$ZERO"

MISSING_SUMMARY="$WORK/missing-summary"
write_contract "$MISSING_SUMMARY"
write_candidates "$MISSING_SUMMARY/reuse_candidates.json" 1
write_valid_decision "$MISSING_SUMMARY/reuse_decision.json"
python3 - "$MISSING_SUMMARY/reuse_decision.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.pop("summary", None)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_exit "missing summary" 4 "$MISSING_SUMMARY"

INVALID_DISPOSITION="$WORK/invalid-disposition"
write_contract "$INVALID_DISPOSITION"
write_candidates "$INVALID_DISPOSITION/reuse_candidates.json" 1
write_valid_decision "$INVALID_DISPOSITION/reuse_decision.json"
python3 - "$INVALID_DISPOSITION/reuse_decision.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["decisions"][0]["disposition"] = "copy"
path.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_exit "invalid disposition" 4 "$INVALID_DISPOSITION"

MISSING_RATIONALE="$WORK/missing-rationale"
write_contract "$MISSING_RATIONALE"
write_candidates "$MISSING_RATIONALE/reuse_candidates.json" 1
write_valid_decision "$MISSING_RATIONALE/reuse_decision.json"
python3 - "$MISSING_RATIONALE/reuse_decision.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["decisions"][0].pop("rationale", None)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_exit "missing rationale" 4 "$MISSING_RATIONALE"

MISSING_ACTION="$WORK/missing-action"
write_contract "$MISSING_ACTION"
write_candidates "$MISSING_ACTION/reuse_candidates.json" 1
write_valid_decision "$MISSING_ACTION/reuse_decision.json"
python3 - "$MISSING_ACTION/reuse_decision.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["decisions"][0].pop("action", None)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_exit "missing action for reuse" 4 "$MISSING_ACTION"

for disposition in reuse adapt follow-pattern respect-boundary; do
  ACTION_WITHOUT_ID="$WORK/action-without-id-${disposition//-/_}"
  write_contract "$ACTION_WITHOUT_ID"
  write_candidates "$ACTION_WITHOUT_ID/reuse_candidates.json" 1
  cat > "$ACTION_WITHOUT_ID/reuse_decision.json" <<JSON
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "decisions": [
    {
      "disposition": "$disposition",
      "action": "Use the relevant existing candidate.",
      "rationale": "The decision is action-bearing and must bind to a specific candidate."
    }
  ],
  "summary": "Attempted an action-bearing decision without candidateId."
}
JSON
  expect_exit "action-bearing $disposition without candidateId" 4 "$ACTION_WITHOUT_ID"
  assert_stderr_contains "action-bearing $disposition explains candidateId requirement" "$ACTION_WITHOUT_ID" "candidateId must be present for disposition $disposition"
done

for disposition in reject defer inspect-only; do
  NON_ACTION_WITH_ID="$WORK/non-action-with-id-${disposition//-/_}"
  write_contract "$NON_ACTION_WITH_ID"
  write_candidates "$NON_ACTION_WITH_ID/reuse_candidates.json" 1
  cat > "$NON_ACTION_WITH_ID/reuse_decision.json" <<JSON
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "$disposition",
      "rationale": "This candidate was considered and does not require an implementation action."
    }
  ],
  "summary": "Addressed the available candidate with $disposition."
}
JSON
  expect_exit "$disposition with candidateId and rationale" 0 "$NON_ACTION_WITH_ID"
done

CONTRACT_ID_MISMATCH="$WORK/contract-id-mismatch"
write_contract "$CONTRACT_ID_MISMATCH"
write_candidates "$CONTRACT_ID_MISMATCH/reuse_candidates.json" 1
write_valid_decision "$CONTRACT_ID_MISMATCH/reuse_decision.json"
python3 - "$CONTRACT_ID_MISMATCH/reuse_decision.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["contractId"] = "other-contract"
path.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_exit "contractId mismatch" 4 "$CONTRACT_ID_MISMATCH"

REPORT="$WORK/report"
write_contract "$REPORT"
write_candidates "$REPORT/reuse_candidates.json" 1
write_valid_decision "$REPORT/reuse_decision.json"
if python3 "$VALIDATOR" \
  --contract "$REPORT/contract.json" \
  --reuse-candidates "$REPORT/reuse_candidates.json" \
  --reuse-decision "$REPORT/reuse_decision.json" \
  --mode warn \
  --output "$REPORT/reuse_decision_check.json" >/dev/null; then
  if grep -Fq '"status": "valid"' "$REPORT/reuse_decision_check.json"; then
    pass "optional validation report is written"
  else
    fail "optional validation report is written" "missing valid status"
  fi
else
  fail "optional validation report is written" "validator failed"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: reuse_decision validator enforces PR2A schema"
