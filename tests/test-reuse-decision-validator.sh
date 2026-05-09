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

echo "=== Reuse decision validator ==="

VALID="$WORK/valid"
write_contract "$VALID"
write_candidates "$VALID/reuse_candidates.json" 1
write_valid_decision "$VALID/reuse_decision.json"
expect_exit "valid decision" 0 "$VALID"

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
