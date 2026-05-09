#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
AUDITOR="$ROOT_DIR/scripts/audit_codebase_reuse.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/basic-mixed"
CONTRACTS="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts"
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

setup_project() {
  local project="$1"
  cp -R "$FIXTURE" "$project"
  mkdir -p "$project/.signum/contracts/example"
  cp "$CONTRACTS/validation-contract.json" "$project/.signum/contracts/example/contract.json"
  cp "$CONTRACTS/validation-contract-engineer.json" "$project/.signum/contracts/example/contract-engineer.json"
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-v1.json" \
      --style-output ".signum/cache/style-profile-v1.json" \
      --generated-at "2026-01-01T00:00:00Z"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/example/contract.json" \
      --contract-engineer ".signum/contracts/example/contract-engineer.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/example/reuse_candidates.json" \
      --implementation-context ".signum/contracts/example/implementation_context.json" \
      --max-candidates 8 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

write_unaddressed_decision() {
  local project="$1"
  cat > "$project/.signum/contracts/example/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "decisions": [
    {
      "disposition": "inspect-only",
      "rationale": "Reviewed candidates during setup; this fixture intentionally leaves specific candidates unaddressed."
    }
  ],
  "newCodeJustifications": [],
  "summary": "Fixture decision leaves candidate IDs unaddressed so the audit can detect missing reuse discipline."
}
JSON
}

write_addressed_decision() {
  local project="$1"
  cat > "$project/.signum/contracts/example/reuse_decision.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "reject",
      "rationale": "The patch intentionally exercises audit downgrading for a candidate that was inspected and rejected in this fixture."
    }
  ],
  "newCodeJustifications": [
    "Fixture-only helper exists to validate duplicate scan behavior."
  ],
  "summary": "Candidate cand-001 was inspected and rejected for fixture purposes."
}
JSON
}

write_candidate_decision() {
  local project="$1" disposition="$2"
  cat > "$project/.signum/contracts/example/reuse_decision.json" <<JSON
{
  "schemaVersion": "1.0",
  "contractId": "validation-contract",
  "writtenAt": "2026-01-01T00:00:00Z",
  "mode": "warn",
  "decisions": [
    {
      "candidateId": "cand-001",
      "disposition": "$disposition",
      "action": "Fixture action for candidate cand-001.",
      "rationale": "Candidate cand-001 was inspected for fixture coverage of disposition $disposition."
    }
  ],
  "newCodeJustifications": [],
  "summary": "Fixture decision covers candidate cand-001 with disposition $disposition."
}
JSON
}

write_clean_patch() {
  local project="$1"
  cat > "$project/.signum/contracts/example/combined.patch" <<'PATCH'
diff --git a/src/runtime/build-info.ts b/src/runtime/build-info.ts
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/src/runtime/build-info.ts
@@ -0,0 +1,2 @@
+export const buildChannel = "local";
+export const releaseNumber = 2;
PATCH
}

write_duplicate_patch() {
  local project="$1"
  cat > "$project/.signum/contracts/example/combined.patch" <<'PATCH'
diff --git a/src/features/signup.ts b/src/features/signup.ts
index 1111111..2222222 100644
--- a/src/features/signup.ts
+++ b/src/features/signup.ts
@@ -1,3 +1,12 @@
+function isValidEmailAddress(email: string) {
+  const normalized = email.trim().toLowerCase();
+  if (!normalized.includes("@")) {
+    return { ok: false, reason: "missing-at-sign" };
+  }
+  return { ok: true };
+}
+
+export const signupValidationMode = "strict";
 export function createSignupPayload(email: string) {
   return { email };
 }
PATCH
}

write_path_name_only_patch() {
  local project="$1"
  cat > "$project/.signum/contracts/example/combined.patch" <<'PATCH'
diff --git a/src/features/signup-validation-alias.ts b/src/features/signup-validation-alias.ts
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/src/features/signup-validation-alias.ts
@@ -0,0 +1,3 @@
+export function validateEmailAlias(value: string): boolean {
+  return Boolean(value);
+}
PATCH
}

snapshot_project() {
  local project="$1"
  (
    cd "$project"
    find . -type f ! -path "./.signum/contracts/example/duplicate_scan.json" \
      | LC_ALL=C sort \
      | while IFS= read -r path; do shasum "$path"; done
  )
}

run_audit() {
  local project="$1"
  local mode="${2:-warn}"
  (
    cd "$project"
    python3 "$AUDITOR" \
      --project-root "." \
      --contract ".signum/contracts/example/contract.json" \
      --patch ".signum/contracts/example/combined.patch" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --reuse-candidates ".signum/contracts/example/reuse_candidates.json" \
      --reuse-decision ".signum/contracts/example/reuse_decision.json" \
      --output ".signum/contracts/example/duplicate_scan.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --implementation-context ".signum/contracts/example/implementation_context.json" \
      --mode "$mode" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

expect_exit_paths() {
  local name="$1" expected="$2" project="$3" mode="$4" patch="$5" index="$6" candidates="$7" decision="$8"
  local status=0
  set +e
  (
    cd "$project"
    python3 "$AUDITOR" \
      --project-root "." \
      --contract ".signum/contracts/example/contract.json" \
      --patch "$patch" \
      --codebase-index "$index" \
      --reuse-candidates "$candidates" \
      --reuse-decision "$decision" \
      --output ".signum/contracts/example/duplicate_scan.json" \
      --mode "$mode" \
      --generated-at "2026-01-01T00:00:00Z" \
      >"$WORK/$name.out" 2>"$WORK/$name.err"
  )
  status=$?
  set -e
  if [ "$status" -eq "$expected" ]; then
    pass "$name exits $expected"
  else
    fail "$name exits $expected" "got $status; stderr=$(cat "$WORK/$name.err")"
  fi
}

expect_exit() {
  local name="$1" expected="$2" project="$3" patch="$4"
  expect_exit_paths \
    "$name" "$expected" "$project" "warn" "$patch" \
    ".signum/cache/codebase-index-v1.json" \
    ".signum/contracts/example/reuse_candidates.json" \
    ".signum/contracts/example/reuse_decision.json"
}

mkdir -p "$WORK/clean" "$WORK/duplicate" "$WORK/addressed" "$WORK/missing" "$WORK/invalid" "$WORK/missing-decision" "$WORK/path-only" "$WORK/dispositions"

echo "=== Clean patch ==="
CLEAN="$WORK/clean/basic-mixed"
setup_project "$CLEAN"
write_unaddressed_decision "$CLEAN"
write_clean_patch "$CLEAN"
before_clean="$(snapshot_project "$CLEAN")"
if run_audit "$CLEAN" >"$WORK/clean.out" 2>"$WORK/clean.err"; then
  pass "clean patch audit exits 0"
else
  fail "clean patch audit exits 0" "$(cat "$WORK/clean.err")"
fi
after_clean="$(snapshot_project "$CLEAN")"
if [ "$before_clean" = "$after_clean" ]; then
  pass "audit does not mutate source or input artifacts"
else
  fail "audit does not mutate source or input artifacts" "snapshot changed"
fi
if python3 - "$CLEAN/.signum/contracts/example/duplicate_scan.json" "$WORK" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
work = sys.argv[2]
errors = []
required = {
    "schemaVersion",
    "contractId",
    "generatedAt",
    "mode",
    "inputs",
    "decisionStatus",
    "scanStats",
    "summaryCounts",
    "findings",
    "recommendedOutcome",
}
missing = required - set(report)
if missing:
    errors.append(f"missing top-level fields: {sorted(missing)}")
if report.get("schemaVersion") != "1.0":
    errors.append("schemaVersion")
if report.get("contractId") != "validation-contract":
    errors.append("contractId")
decision_status = report.get("decisionStatus", {})
if decision_status.get("present") is not True or decision_status.get("valid") is not True:
    errors.append("expected present valid decisionStatus")
if decision_status.get("entries") != 1:
    errors.append("expected one decision entry")
if report.get("summaryCounts", {}).get("total") != 0:
    errors.append("expected no findings")
if report.get("recommendedOutcome") != "clean":
    errors.append("recommendedOutcome")
if report.get("recommendedOutcome") not in {"clean", "informational", "review-recommended"}:
    errors.append("unexpected recommendedOutcome vocabulary")
if work in json.dumps(report, sort_keys=True):
    errors.append("leaked temp path")
if any(term in json.dumps(report, sort_keys=True) for term in ("AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW")):
    errors.append("leaked Signum verdict vocabulary")
if Path(report.get("inputs", {}).get("patch", "")).is_absolute():
    errors.append("absolute input path")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "clean patch writes clean duplicate_scan.json"
else
  fail "clean patch writes clean duplicate_scan.json" "report validation failed"
fi

echo ""
echo "=== Duplicate/helper patch ==="
DUPLICATE="$WORK/duplicate/basic-mixed"
setup_project "$DUPLICATE"
write_unaddressed_decision "$DUPLICATE"
write_duplicate_patch "$DUPLICATE"
if run_audit "$DUPLICATE" >"$WORK/duplicate.out" 2>"$WORK/duplicate.err"; then
  pass "duplicate patch audit exits 0"
else
  fail "duplicate patch audit exits 0" "$(cat "$WORK/duplicate.err")"
fi
cp "$DUPLICATE/.signum/contracts/example/duplicate_scan.json" "$WORK/duplicate-first.json"
if run_audit "$DUPLICATE" >"$WORK/duplicate-second.out" 2>"$WORK/duplicate-second.err" \
  && cmp -s "$WORK/duplicate-first.json" "$DUPLICATE/.signum/contracts/example/duplicate_scan.json"; then
  pass "duplicate audit output is byte-stable with fixed generatedAt"
else
  fail "duplicate audit output is byte-stable with fixed generatedAt" "duplicate_scan.json changed"
fi
if python3 - "$DUPLICATE/.signum/contracts/example/duplicate_scan.json" "$WORK" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
work = sys.argv[2]
findings = report.get("findings", [])
kinds = {finding.get("kind") for finding in findings}
errors = []
required_top = {
    "schemaVersion",
    "contractId",
    "generatedAt",
    "mode",
    "inputs",
    "decisionStatus",
    "scanStats",
    "summaryCounts",
    "findings",
    "recommendedOutcome",
}
missing_top = required_top - set(report)
if missing_top:
    errors.append(f"missing top-level fields: {sorted(missing_top)}")
if report.get("summaryCounts", {}).get("total", 0) < 1:
    errors.append("expected findings")
if report.get("recommendedOutcome") != "review-recommended":
    errors.append("expected review-recommended")
if report.get("recommendedOutcome") not in {"clean", "informational", "review-recommended"}:
    errors.append("unexpected recommendedOutcome vocabulary")
if not ({"new-helper-similar-to-existing-candidate", "added-block-token-overlap"} & kinds):
    errors.append("expected helper or token-overlap finding")
if not any(finding.get("severity") == "major" for finding in findings):
    errors.append("expected major severity with multiple evidence axes")
required_finding = {
    "findingId",
    "kind",
    "severity",
    "path",
    "candidateIds",
    "score",
    "why",
    "matches",
    "decisionAddressed",
    "recommendedAction",
}
for finding in findings:
    missing_finding = required_finding - set(finding)
    if missing_finding:
        errors.append(f"missing finding fields: {sorted(missing_finding)}")
    if finding.get("kind") == "possible-convention-drift" and finding.get("severity") not in {"info", "minor"}:
        errors.append("convention drift severity exceeded minor")
    if finding.get("kind") == "unaddressed-high-confidence-candidate" and finding.get("severity") not in {"info", "minor"}:
        errors.append("unaddressed candidate severity exceeded minor")
    if finding.get("severity") == "major":
        why = " ".join(finding.get("why", []))
        if "body tokens overlap" not in why:
            errors.append("major finding lacks strong token evidence")
if work in json.dumps(report, sort_keys=True):
    errors.append("leaked temp path")
if any(term in json.dumps(report, sort_keys=True) for term in ("AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW")):
    errors.append("leaked Signum verdict vocabulary")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "duplicate patch reports review-worthy finding"
else
  fail "duplicate patch reports review-worthy finding" "report validation failed"
fi

echo ""
echo "=== Decision-addressed patch ==="
ADDRESSED="$WORK/addressed/basic-mixed"
setup_project "$ADDRESSED"
write_addressed_decision "$ADDRESSED"
write_duplicate_patch "$ADDRESSED"
if run_audit "$ADDRESSED" >"$WORK/addressed.out" 2>"$WORK/addressed.err"; then
  pass "decision-addressed patch audit exits 0"
else
  fail "decision-addressed patch audit exits 0" "$(cat "$WORK/addressed.err")"
fi
if python3 - "$ADDRESSED/.signum/contracts/example/duplicate_scan.json" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
target = [
    finding for finding in report.get("findings", [])
    if "cand-001" in finding.get("candidateIds", [])
]
errors = []
if not target:
    errors.append("expected cand-001 finding")
if not any(finding.get("decisionAddressed") is True for finding in target):
    errors.append("expected decisionAddressed")
if not any(finding.get("decisionDisposition") == "reject" for finding in target):
    errors.append("expected reject disposition")
if any(finding.get("severity") == "major" for finding in target):
    errors.append("addressed cand-001 finding should be downgraded below major")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "decision-addressed finding is marked and downgraded"
else
  fail "decision-addressed finding is marked and downgraded" "report validation failed"
fi

echo ""
echo "=== Decision disposition guardrails ==="
for disposition in reuse adapt defer inspect-only; do
  DISPOSITION_PROJECT="$WORK/dispositions/$disposition/basic-mixed"
  mkdir -p "$(dirname "$DISPOSITION_PROJECT")"
  setup_project "$DISPOSITION_PROJECT"
  write_candidate_decision "$DISPOSITION_PROJECT" "$disposition"
  write_duplicate_patch "$DISPOSITION_PROJECT"
  if run_audit "$DISPOSITION_PROJECT" >"$WORK/disposition-$disposition.out" 2>"$WORK/disposition-$disposition.err" \
    && python3 - "$DISPOSITION_PROJECT/.signum/contracts/example/duplicate_scan.json" "$disposition" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
disposition = sys.argv[2]
target = [
    finding for finding in report.get("findings", [])
    if "cand-001" in finding.get("candidateIds", [])
]
errors = []
if not target:
    errors.append("expected cand-001 finding")
if not any(finding.get("decisionAddressed") is True for finding in target):
    errors.append("expected addressed finding")
if not any(finding.get("decisionDisposition") == disposition for finding in target):
    errors.append("expected disposition")
if any(finding.get("severity") == "major" for finding in target):
    errors.append("addressed finding should not remain major")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    pass "$disposition disposition is marked addressed and not escalated"
  else
    fail "$disposition disposition is marked addressed and not escalated" "$(cat "$WORK/disposition-$disposition.err" 2>/dev/null || true)"
  fi
done

echo ""
echo "=== Path/name-only severity guard ==="
PATH_ONLY="$WORK/path-only/basic-mixed"
setup_project "$PATH_ONLY"
write_unaddressed_decision "$PATH_ONLY"
write_path_name_only_patch "$PATH_ONLY"
if run_audit "$PATH_ONLY" >"$WORK/path-only.out" 2>"$WORK/path-only.err"; then
  pass "path/name-only audit exits 0"
else
  fail "path/name-only audit exits 0" "$(cat "$WORK/path-only.err")"
fi
if python3 - "$PATH_ONLY/.signum/contracts/example/duplicate_scan.json" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
errors = []
for finding in report.get("findings", []):
    if finding.get("severity") == "major":
        errors.append(f"path/name-only fixture produced major finding: {finding.get('findingId')}")
    if finding.get("kind") == "possible-convention-drift" and finding.get("severity") not in {"info", "minor"}:
        errors.append("convention drift severity exceeded minor")
    if finding.get("kind") == "unaddressed-high-confidence-candidate" and finding.get("severity") not in {"info", "minor"}:
        errors.append("unaddressed candidate severity exceeded minor")
if any(term in json.dumps(report, sort_keys=True) for term in ("AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW")):
    errors.append("leaked Signum verdict vocabulary")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "path/name-only fixture does not produce major findings"
else
  fail "path/name-only fixture does not produce major findings" "report validation failed"
fi

echo ""
echo "=== Missing decision by mode ==="
for mode in hint warn; do
  MISSING_DECISION_PROJECT="$WORK/missing-decision/$mode/basic-mixed"
  mkdir -p "$(dirname "$MISSING_DECISION_PROJECT")"
  setup_project "$MISSING_DECISION_PROJECT"
  write_duplicate_patch "$MISSING_DECISION_PROJECT"
  rm -f "$MISSING_DECISION_PROJECT/.signum/contracts/example/reuse_decision.json"
  if run_audit "$MISSING_DECISION_PROJECT" "$mode" >"$WORK/missing-decision-$mode.out" 2>"$WORK/missing-decision-$mode.err"; then
    pass "missing decision in $mode exits 0"
  else
    fail "missing decision in $mode exits 0" "$(cat "$WORK/missing-decision-$mode.err")"
  fi
  if python3 - "$MISSING_DECISION_PROJECT/.signum/contracts/example/duplicate_scan.json" "$mode" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
mode = sys.argv[2]
status = report.get("decisionStatus", {})
errors = []
if status.get("present") is not False:
    errors.append("decisionStatus.present should be false")
if status.get("valid") is not False:
    errors.append("decisionStatus.valid should be false")
if status.get("mode") != mode:
    errors.append("decisionStatus mode mismatch")
if status.get("entries") != 0:
    errors.append("decisionStatus entries should be 0")
if not any("degraded decision-unaware mode" in note for note in status.get("notes", [])):
    errors.append("missing degraded-mode note")
for finding in report.get("findings", []):
    if finding.get("candidateIds") and finding.get("decisionAddressed") is not False:
        errors.append("finding should not be decision-addressed without decision")
if any(term in json.dumps(report, sort_keys=True) for term in ("AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW")):
    errors.append("leaked Signum verdict vocabulary")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    pass "missing decision in $mode writes degraded decisionStatus"
  else
    fail "missing decision in $mode writes degraded decisionStatus" "report validation failed"
  fi
done

MISSING_DECISION_GATE="$WORK/missing-decision/gate/basic-mixed"
mkdir -p "$(dirname "$MISSING_DECISION_GATE")"
setup_project "$MISSING_DECISION_GATE"
write_duplicate_patch "$MISSING_DECISION_GATE"
rm -f "$MISSING_DECISION_GATE/.signum/contracts/example/reuse_decision.json"
expect_exit_paths \
  "missing decision gate" 2 "$MISSING_DECISION_GATE" "gate" \
  ".signum/contracts/example/combined.patch" \
  ".signum/cache/codebase-index-v1.json" \
  ".signum/contracts/example/reuse_candidates.json" \
  ".signum/contracts/example/reuse_decision.json"

echo ""
echo "=== Error handling ==="
MISSING="$WORK/missing/basic-mixed"
setup_project "$MISSING"
write_unaddressed_decision "$MISSING"
expect_exit "missing patch" 2 "$MISSING" ".signum/contracts/example/missing.patch"
write_duplicate_patch "$MISSING"
expect_exit_paths \
  "missing codebase index" 2 "$MISSING" "warn" \
  ".signum/contracts/example/combined.patch" \
  ".signum/cache/missing-codebase-index-v1.json" \
  ".signum/contracts/example/reuse_candidates.json" \
  ".signum/contracts/example/reuse_decision.json"
expect_exit_paths \
  "missing reuse candidates" 2 "$MISSING" "warn" \
  ".signum/contracts/example/combined.patch" \
  ".signum/cache/codebase-index-v1.json" \
  ".signum/contracts/example/missing_reuse_candidates.json" \
  ".signum/contracts/example/reuse_decision.json"

INVALID="$WORK/invalid/basic-mixed"
setup_project "$INVALID"
write_unaddressed_decision "$INVALID"
write_duplicate_patch "$INVALID"
printf '{ invalid json' > "$INVALID/.signum/contracts/example/reuse_candidates.json"
expect_exit "invalid reuse candidates JSON" 3 "$INVALID" ".signum/contracts/example/combined.patch"

INVALID_DECISION="$WORK/invalid/decision/basic-mixed"
mkdir -p "$(dirname "$INVALID_DECISION")"
setup_project "$INVALID_DECISION"
write_duplicate_patch "$INVALID_DECISION"
printf '{ invalid json' > "$INVALID_DECISION/.signum/contracts/example/reuse_decision.json"
expect_exit "invalid reuse decision JSON" 3 "$INVALID_DECISION" ".signum/contracts/example/combined.patch"

echo ""
printf "Passed: %s\n" "$passed"
printf "Failed: %s\n" "$failed"

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
