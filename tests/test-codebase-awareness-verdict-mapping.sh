#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/evaluate_codebase_awareness_audit.py"
ROOT_FRAGMENT="$ROOT_DIR/commands/signum.fragments/90-phase-audit.md"
OVERLAY_FRAGMENT="$ROOT_DIR/platforms/claude-code/commands/signum.fragments/90-phase-audit.md"
ROOT_COMMAND="$ROOT_DIR/commands/signum.md"
OVERLAY_COMMAND="$ROOT_DIR/platforms/claude-code/commands/signum.md"
ROOT_PACK="$ROOT_DIR/commands/signum.fragments/100-phase-pack.md"
OVERLAY_PACK="$ROOT_DIR/platforms/claude-code/commands/signum.fragments/100-phase-pack.md"
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

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label" "missing $needle"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$label" "unexpected $needle"
  else
    pass "$label"
  fi
}

assert_order() {
  local file="$1" before="$2" marker="$3" after="$4" label="$5"
  if python3 - "$file" "$before" "$marker" "$after" <<'PY'; then
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
positions = [text.find(item) for item in sys.argv[2:]]
if any(pos < 0 for pos in positions) or positions != sorted(positions):
    raise SystemExit(1)
PY
    pass "$label"
  else
    fail "$label" "markers are missing or out of order"
  fi
}

release_for() {
  case "$1" in
    AUTO_OK) printf 'PROMOTE' ;;
    HUMAN_REVIEW) printf 'HOLD' ;;
    AUTO_BLOCK) printf 'REJECT' ;;
    *) printf 'HOLD' ;;
  esac
}

write_summary() {
  local project="$1" decision="$2"
  local release
  release="$(release_for "$decision")"
  mkdir -p "$project"
  cat > "$project/audit_summary.json" <<JSON
{
  "schemaVersion": "1.0",
  "mechanic": "clean",
  "reviews": {
    "claude": {"verdict": "APPROVE", "findings": []},
    "codex": {"verdict": "APPROVE", "findings": []},
    "gemini": {"verdict": "APPROVE", "findings": []}
  },
  "availableReviews": 3,
  "holdout": {"passed": 0, "failed": 0, "total": 0},
  "consensus": "approve",
  "confidence": {"overall": 90},
  "decision": "$decision",
  "releaseVerdict": "$release",
  "reasoning": "Fixture starting point.",
  "fixturePreservedField": {"kept": true}
}
JSON
}

write_scan() {
  local project="$1" variant="$2"
  local findings counts outcome
  mkdir -p "$project"
  case "$variant" in
    clean)
      findings='[]'
      counts='{"critical":0,"major":0,"minor":0,"info":0,"total":0}'
      outcome='clean'
      ;;
    minor-info)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"possible-convention-drift",
          "severity":"minor",
          "path":"src/example.ts",
          "candidateIds":[],
          "score":0.4,
          "why":["style profile differs in a low-risk fixture"],
          "matches":[],
          "decisionAddressed":false,
          "recommendedAction":"inspect"
        },
        {
          "findingId":"dup-002",
          "kind":"unaddressed-high-confidence-candidate",
          "severity":"info",
          "path":"src/example.ts",
          "candidateIds":["cand-001"],
          "score":0.5,
          "why":["candidate was nearby but no duplicate evidence was found"],
          "matches":[],
          "decisionAddressed":false,
          "recommendedAction":"inspect"
        }
      ]'
      counts='{"critical":0,"major":0,"minor":1,"info":1,"total":2}'
      outcome='informational'
      ;;
    major-high)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"new-helper-similar-to-existing-candidate",
          "severity":"major",
          "path":"src/features/signup.ts",
          "candidateIds":["cand-001"],
          "score":0.9,
          "why":["added helper tokens overlap existing candidate validateEmail","candidate is high-confidence existing-helper"],
          "matches":[{"candidateId":"cand-001","path":"src/shared/validation.ts","symbol":"validateEmail"}],
          "decisionAddressed":false,
          "recommendedAction":"reuse-existing-or-justify"
        }
      ]'
      counts='{"critical":0,"major":1,"minor":0,"info":0,"total":1}'
      outcome='review-recommended'
      ;;
    major-low)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"new-helper-similar-to-existing-candidate",
          "severity":"major",
          "path":"src/features/signup.ts",
          "candidateIds":["cand-001"],
          "score":0.72,
          "why":["added helper tokens overlap existing candidate validateEmail","candidate is existing-helper"],
          "matches":[{"candidateId":"cand-001","path":"src/shared/validation.ts","symbol":"validateEmail"}],
          "decisionAddressed":false,
          "recommendedAction":"reuse-existing-or-justify"
        }
      ]'
      counts='{"critical":0,"major":1,"minor":0,"info":0,"total":1}'
      outcome='review-recommended'
      ;;
    critical)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"added-block-token-overlap",
          "severity":"critical",
          "path":"src/features/signup.ts",
          "candidateIds":["cand-001"],
          "score":0.93,
          "why":["fingerprint overlap is exact","candidate was not addressed"],
          "matches":[{"candidateId":"cand-001","path":"src/shared/validation.ts","symbol":"validateEmail"}],
          "decisionAddressed":false,
          "recommendedAction":"reuse-existing-or-justify"
        }
      ]'
      counts='{"critical":1,"major":0,"minor":0,"info":0,"total":1}'
      outcome='review-recommended'
      ;;
    addressed-major)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"new-helper-similar-to-existing-candidate",
          "severity":"major",
          "path":"src/features/signup.ts",
          "candidateIds":["cand-001"],
          "score":0.91,
          "why":["added helper tokens overlap existing candidate validateEmail","candidate is high-confidence existing-helper"],
          "matches":[{"candidateId":"cand-001","path":"src/shared/validation.ts","symbol":"validateEmail"}],
          "decisionAddressed":true,
          "decisionDisposition":"reject",
          "decisionRationalePresent":true,
          "recommendedAction":"inspect"
        }
      ]'
      counts='{"critical":0,"major":1,"minor":0,"info":0,"total":1}'
      outcome='review-recommended'
      ;;
    unaddressed-candidate-major)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"unaddressed-high-confidence-candidate",
          "severity":"major",
          "path":"src/features/signup.ts",
          "candidateIds":["cand-001"],
          "score":0.96,
          "why":["candidate has high confidence","target area appears related"],
          "matches":[{"candidateId":"cand-001","path":"src/shared/validation.ts","symbol":"validateEmail"}],
          "decisionAddressed":false,
          "recommendedAction":"inspect"
        }
      ]'
      counts='{"critical":0,"major":1,"minor":0,"info":0,"total":1}'
      outcome='review-recommended'
      ;;
    convention-drift-major)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"possible-convention-drift",
          "severity":"major",
          "path":"src/features/signup.ts",
          "candidateIds":[],
          "score":0.91,
          "why":["test file name differs from convention","directory placement differs from convention"],
          "matches":[],
          "decisionAddressed":false,
          "recommendedAction":"inspect"
        }
      ]'
      counts='{"critical":0,"major":1,"minor":0,"info":0,"total":1}'
      outcome='review-recommended'
      ;;
    path-name-only)
      findings='[
        {
          "findingId":"dup-001",
          "kind":"new-helper-similar-to-existing-candidate",
          "severity":"major",
          "path":"src/features/signup-validation-alias.ts",
          "candidateIds":["cand-001"],
          "score":0.92,
          "why":["candidate path/name overlaps target path","directory name matches signup domain"],
          "matches":[{"candidateId":"cand-001","path":"src/shared/validation.ts","symbol":"validateEmail"}],
          "decisionAddressed":false,
          "recommendedAction":"inspect"
        }
      ]'
      counts='{"critical":0,"major":1,"minor":0,"info":0,"total":1}'
      outcome='review-recommended'
      ;;
    *)
      fail "write scan fixture" "unknown variant $variant"
      return 1
      ;;
  esac
  cat > "$project/duplicate_scan.json" <<JSON
{
  "schemaVersion": "1.0",
  "contractId": "example",
  "generatedAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "inputs": {},
  "decisionStatus": {"present": true, "valid": true, "mode": "warn", "entries": 1, "notes": []},
  "scanStats": {"changedFiles": 1, "addedLines": 1, "addedBlocks": 1, "candidatesConsidered": 1, "decisionEntries": 1},
  "summaryCounts": $counts,
  "findings": $findings,
  "recommendedOutcome": "$outcome"
}
JSON
}

run_mapping() {
  local label="$1" mode="$2" variant="$3" start_decision="$4" expected_decision="$5" expected_release="$6"
  local project="$WORK/$label"
  write_summary "$project" "$start_decision"
  write_scan "$project" "$variant"
  if python3 "$HELPER" \
      --audit-summary "$project/audit_summary.json" \
      --duplicate-scan "$project/duplicate_scan.json" \
      --mode "$mode" \
      --output "$project/audit_summary.json" \
      > "$project/stdout.txt" 2> "$project/stderr.txt"; then
    if python3 - "$project/audit_summary.json" "$expected_decision" "$expected_release" <<'PY'; then
import sys
import json
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if summary.get("decision") != sys.argv[2]:
    raise SystemExit(f"decision={summary.get('decision')}")
if summary.get("releaseVerdict") != sys.argv[3]:
    raise SystemExit(f"releaseVerdict={summary.get('releaseVerdict')}")
if "codebaseAwareness" not in summary:
    raise SystemExit("missing codebaseAwareness")
if summary.get("fixturePreservedField") != {"kept": True}:
    raise SystemExit("fixture field was not preserved")
PY
      pass "$label maps to $expected_decision"
    else
      fail "$label maps to $expected_decision" "unexpected audit_summary.json"
    fi
  else
    fail "$label maps to $expected_decision" "helper exited non-zero"
  fi
}

run_missing_or_invalid() {
  local label="$1" mode="$2" scan_state="$3" expected_decision="$4"
  local project="$WORK/$label"
  write_summary "$project" "AUTO_OK"
  if [ "$scan_state" = "invalid" ]; then
    printf '{not-json' > "$project/duplicate_scan.json"
  fi
  local scan_path="$project/duplicate_scan.json"
  if [ "$scan_state" = "missing" ]; then
    scan_path="$project/missing-duplicate-scan.json"
  fi
  if python3 "$HELPER" \
      --audit-summary "$project/audit_summary.json" \
      --duplicate-scan "$scan_path" \
      --mode "$mode" \
      --output "$project/audit_summary.json" \
      > "$project/stdout.txt" 2> "$project/stderr.txt"; then
    if python3 - "$project/audit_summary.json" "$expected_decision" "$scan_state" <<'PY'; then
import sys
import json
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
awareness = summary.get("codebaseAwareness", {})
if summary.get("decision") != sys.argv[2]:
    raise SystemExit(f"decision={summary.get('decision')}")
if sys.argv[3] == "missing" and awareness.get("duplicateScanPresent") is not False:
    raise SystemExit("missing scan not recorded")
if sys.argv[3] == "invalid" and awareness.get("duplicateScanValid") is not False:
    raise SystemExit("invalid scan not recorded")
PY
      pass "$label maps missing/invalid scan to $expected_decision"
    else
      fail "$label maps missing/invalid scan to $expected_decision" "unexpected audit_summary.json"
    fi
  else
    fail "$label maps missing/invalid scan to $expected_decision" "helper exited non-zero"
  fi
}

run_preserved_auto_block() {
  local project="$WORK/preserve-auto-block-warn-major"
  write_summary "$project" "AUTO_BLOCK"
  write_scan "$project" "major-high"
  if python3 "$HELPER" \
      --audit-summary "$project/audit_summary.json" \
      --duplicate-scan "$project/duplicate_scan.json" \
      --mode "warn" \
      --output "$project/audit_summary.json" \
      > "$project/stdout.txt" 2> "$project/stderr.txt"; then
    if python3 - "$project/audit_summary.json" <<'PY'; then
import sys
import json
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
awareness = summary.get("codebaseAwareness", {})
if summary.get("decision") != "AUTO_BLOCK":
    raise SystemExit(f"decision={summary.get('decision')}")
if summary.get("releaseVerdict") != "REJECT":
    raise SystemExit(f"releaseVerdict={summary.get('releaseVerdict')}")
if awareness.get("appliedOutcomeCap") != "HUMAN_REVIEW":
    raise SystemExit(f"appliedOutcomeCap={awareness.get('appliedOutcomeCap')}")
if awareness.get("preservedStricterExistingDecision") is not True:
    raise SystemExit("stricter existing decision was not recorded")
if "existing AUTO_BLOCK preserved" not in awareness.get("reason", ""):
    raise SystemExit(f"reason={awareness.get('reason')}")
if "existing AUTO_BLOCK preserved" not in summary.get("reasoning", ""):
    raise SystemExit("reasoning does not explain preserved AUTO_BLOCK")
PY
      pass "warn preserves pre-existing AUTO_BLOCK without Codebase AUTO_BLOCK"
    else
      fail "warn preserves pre-existing AUTO_BLOCK without Codebase AUTO_BLOCK" "unexpected audit_summary.json"
    fi
  else
    fail "warn preserves pre-existing AUTO_BLOCK without Codebase AUTO_BLOCK" "helper exited non-zero"
  fi
}

run_idempotency() {
  local project="$WORK/idempotency"
  write_summary "$project" "AUTO_OK"
  write_scan "$project" "major-high"
  python3 "$HELPER" \
    --audit-summary "$project/audit_summary.json" \
    --duplicate-scan "$project/duplicate_scan.json" \
    --mode "warn" \
    --output "$project/audit_summary.json" \
    > "$project/first.out" 2> "$project/first.err"
  cp "$project/audit_summary.json" "$project/audit_summary.first.json"
  python3 "$HELPER" \
    --audit-summary "$project/audit_summary.json" \
    --duplicate-scan "$project/duplicate_scan.json" \
    --mode "warn" \
    --output "$project/audit_summary.json" \
    > "$project/second.out" 2> "$project/second.err"
  if cmp -s "$project/audit_summary.first.json" "$project/audit_summary.json" \
    && python3 - "$project/audit_summary.json" <<'PY'; then
import sys
import json
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
reasoning = summary.get("reasoning", "")
if reasoning.count("Codebase Awareness:") != 1:
    raise SystemExit(f"reasoning={reasoning}")
if summary.get("codebaseAwareness", {}).get("appliedOutcomeCap") != "HUMAN_REVIEW":
    raise SystemExit("unexpected Codebase Awareness summary")
PY
    pass "mapping helper is idempotent"
  else
    fail "mapping helper is idempotent" "second run changed output or duplicated reasoning"
  fi
}

check_surface() {
  local file="$1" label="$2"
  assert_contains "$file" "scripts/evaluate_codebase_awareness_audit.py" "$label applies verdict mapping helper"
  assert_contains "$file" 'DUPLICATE_SCAN_PATH="${ARTIFACT_ROOT}duplicate_scan.json"' "$label reads active-root duplicate scan"
  assert_contains "$file" "codebase-index-v1.json" "$label retains codebase awareness audit context"
}

assert_order "$ROOT_FRAGMENT" \
  "### Step 3.5: Synthesizer (agent)" \
  "scripts/evaluate_codebase_awareness_audit.py" \
  "=== AUDIT SUMMARY ===" \
  "root applies mapping before displaying summary"
assert_order "$OVERLAY_FRAGMENT" \
  "### Step 3.5: Synthesizer (agent)" \
  "scripts/evaluate_codebase_awareness_audit.py" \
  "=== AUDIT SUMMARY ===" \
  "Claude overlay applies mapping before displaying summary"
check_surface "$ROOT_FRAGMENT" "root AUDIT fragment"
check_surface "$OVERLAY_FRAGMENT" "Claude AUDIT fragment"
check_surface "$ROOT_COMMAND" "rendered root command"
check_surface "$OVERLAY_COMMAND" "rendered Claude command"

run_mapping "off-unresolved-major" "off" "major-high" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_mapping "off-stale-critical" "off" "critical" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_missing_or_invalid "off-missing-scan" "off" "missing" "AUTO_OK"
run_missing_or_invalid "off-invalid-scan" "off" "invalid" "AUTO_OK"
run_mapping "hint-unresolved-major" "hint" "major-high" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_mapping "hint-stale-critical" "hint" "critical" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_missing_or_invalid "hint-missing-scan" "hint" "missing" "AUTO_OK"
run_missing_or_invalid "hint-invalid-scan" "hint" "invalid" "AUTO_OK"
run_mapping "warn-clean" "warn" "clean" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_mapping "warn-minor-info" "warn" "minor-info" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_mapping "warn-unresolved-major" "warn" "major-high" "AUTO_OK" "HUMAN_REVIEW" "HOLD"
run_mapping "warn-unresolved-critical" "warn" "critical" "AUTO_OK" "HUMAN_REVIEW" "HOLD"
run_missing_or_invalid "warn-missing-scan" "warn" "missing" "HUMAN_REVIEW"
run_missing_or_invalid "warn-invalid-scan" "warn" "invalid" "HUMAN_REVIEW"
run_mapping "gate-clean" "gate" "clean" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_missing_or_invalid "gate-missing-scan" "gate" "missing" "AUTO_BLOCK"
run_missing_or_invalid "gate-invalid-scan" "gate" "invalid" "AUTO_BLOCK"
run_mapping "gate-high-confidence-major" "gate" "major-high" "AUTO_OK" "AUTO_BLOCK" "REJECT"
run_mapping "gate-lower-confidence-major" "gate" "major-low" "AUTO_OK" "HUMAN_REVIEW" "HOLD"
run_mapping "gate-unaddressed-candidate-only" "gate" "unaddressed-candidate-major" "AUTO_OK" "HUMAN_REVIEW" "HOLD"
run_mapping "gate-convention-drift-major" "gate" "convention-drift-major" "AUTO_OK" "HUMAN_REVIEW" "HOLD"
run_mapping "gate-path-name-only" "gate" "path-name-only" "AUTO_OK" "HUMAN_REVIEW" "HOLD"
run_mapping "gate-critical" "gate" "critical" "AUTO_OK" "AUTO_BLOCK" "REJECT"
run_mapping "gate-addressed-major" "gate" "addressed-major" "AUTO_OK" "AUTO_OK" "PROMOTE"
run_mapping "preserve-auto-block" "warn" "clean" "AUTO_BLOCK" "AUTO_BLOCK" "REJECT"
run_mapping "preserve-human-review" "gate" "clean" "HUMAN_REVIEW" "HUMAN_REVIEW" "HOLD"
run_preserved_auto_block
run_idempotency

if ! grep -R -E "AUTO_OK|HUMAN_REVIEW|AUTO_BLOCK" "$WORK"/*/duplicate_scan.json >/dev/null 2>&1; then
  pass "duplicate_scan fixtures contain no final verdict vocabulary"
else
  fail "duplicate_scan fixtures contain no final verdict vocabulary" "verdict token found"
fi

if python3 - "$WORK" <<'PY'; then
import sys
import json
from pathlib import Path

allowed = {"clean", "informational", "review-recommended"}
for path in Path(sys.argv[1]).glob("*/duplicate_scan.json"):
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        continue
    if report.get("recommendedOutcome") not in allowed:
        raise SystemExit(f"{path}: {report.get('recommendedOutcome')}")
PY
  pass "duplicate_scan recommendedOutcome stays in PR3A vocabulary"
else
  fail "duplicate_scan recommendedOutcome stays in PR3A vocabulary" "unexpected recommendedOutcome"
fi

assert_contains "$ROOT_PACK" "PROOFPACK_REUSE_SUMMARY" "root PACK contains packaging-only reuse summary step"
assert_contains "$OVERLAY_PACK" "PROOFPACK_REUSE_SUMMARY" "Claude PACK contains packaging-only reuse summary step"
assert_contains "$ROOT_PACK" "This packages existing evidence only; it does not change the audit decision." "root PACK documents no verdict mutation"
assert_contains "$OVERLAY_PACK" "This packages existing evidence only; it does not change the audit decision." "Claude PACK documents no verdict mutation"
assert_not_contains "$ROOT_PACK" "scripts/evaluate_codebase_awareness_audit.py" "root PACK does not run verdict mapping helper"
assert_not_contains "$OVERLAY_PACK" "scripts/evaluate_codebase_awareness_audit.py" "Claude PACK does not run verdict mapping helper"

printf 'test-codebase-awareness-verdict-mapping: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
