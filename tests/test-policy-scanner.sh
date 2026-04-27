#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/lib/policy-scanner.sh"
OVERLAY_SCRIPT="$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh"
CATALOG="$ROOT_DIR/lib/policy-rules.json"
OVERLAY_CATALOG="$ROOT_DIR/platforms/claude-code/lib/policy-rules.json"
FIXTURES="$ROOT_DIR/tests/fixtures/policy-scanner"
WORK=$(mktemp -d)
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

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

assert_ok() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

assert_jq() {
  local name="$1" expr="$2" file="$3"
  if jq -e "$expr" "$file" >/dev/null; then
    pass "$name"
  else
    fail "$name" "jq expression failed: $expr"
  fi
}

run_fixture() {
  local fixture="$1"
  local case_dir="$WORK/${fixture%.patch}"
  mkdir -p "$case_dir"
  cp "$FIXTURES/$fixture" "$case_dir/combined.patch"
  "$SCRIPT" "$case_dir/combined.patch" >/dev/null
  printf '%s\n' "$case_dir/policy_scan.json"
}

echo "=== Scanner wiring ==="
assert_file "root policy scanner exists" "$SCRIPT"
assert_file "overlay policy scanner exists" "$OVERLAY_SCRIPT"
assert_file "root policy rule catalog exists" "$CATALOG"
assert_file "overlay policy rule catalog exists" "$OVERLAY_CATALOG"
assert_ok "overlay policy scanner mirrors root" cmp -s "$SCRIPT" "$OVERLAY_SCRIPT"
assert_ok "overlay policy rule catalog mirrors root" cmp -s "$CATALOG" "$OVERLAY_CATALOG"

for fixture in \
  clean.patch \
  non-added-line.patch \
  benign-close.patch \
  all-rules.patch \
  suppression-minor.patch \
  suppression-same-line.patch \
  suppression-major.patch \
  suppression-critical-rejected.patch \
  suppression-wrong-rule.patch \
  suppression-unknown-rule.patch \
  suppression-missing-reason.patch \
  suppression-scope.patch \
  dependency-npm-manifest.patch \
  dependency-npm-docs-no-trigger.patch \
  dependency-python-manifest.patch \
  dependency-python-docs-no-trigger.patch \
  dependency-cargo-manifest.patch \
  dependency-go-manifest.patch \
  dependency-suppression-manifest.patch \
  dependency-suppression-docs-no-finding.patch; do
  assert_file "fixture exists: $fixture" "$FIXTURES/$fixture"
done

echo ""
echo "=== Rule catalog contract ==="
if REPO_ROOT="$ROOT_DIR" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

repo = Path(os.environ["REPO_ROOT"])
scanner = repo / "lib" / "policy-scanner.sh"
catalog_path = repo / "lib" / "policy-rules.json"
fixtures = repo / "tests" / "fixtures" / "policy-scanner"

catalog = json.loads(catalog_path.read_text())
errors = []
if catalog.get("schemaVersion") != "1.0":
    errors.append("catalog schemaVersion must be 1.0")

rules = catalog.get("rules")
if not isinstance(rules, list) or not rules:
    errors.append("catalog rules must be a non-empty array")
    rules = []

catalog_by_id = {}
expected_dependency_scopes = {
    "POLICY_NEW_NPM_DEPENDENCY": {
        "package.json",
        "package-lock.json",
        "npm-shrinkwrap.json",
        "pnpm-lock.yaml",
        "yarn.lock",
    },
    "POLICY_NEW_CARGO_DEPENDENCY": {"Cargo.toml", "Cargo.lock"},
    "POLICY_NEW_PYTHON_DEPENDENCY": {
        "requirements*.txt",
        "pyproject.toml",
        "poetry.lock",
        "Pipfile",
        "Pipfile.lock",
        "setup.py",
        "setup.cfg",
    },
    "POLICY_NEW_GO_DEPENDENCY": {"go.mod", "go.sum"},
}
expected_dependency_exclusions = {"docs/", "examples/", "fixtures/", "tests/", "test/"}
for index, rule in enumerate(rules):
    rid = rule.get("ruleId")
    if not isinstance(rid, str) or not rid.startswith("POLICY_"):
        errors.append(f"catalog rule {index} has invalid ruleId")
        continue
    if rid in catalog_by_id:
        errors.append(f"duplicate catalog ruleId: {rid}")
    catalog_by_id[rid] = rule
    for field in ("type", "severity", "pattern", "description", "fixture"):
        if not isinstance(rule.get(field), str) or not rule[field]:
            errors.append(f"{rid} missing non-empty {field}")
    if not isinstance(rule.get("autoBlock"), bool):
        errors.append(f"{rid} missing boolean autoBlock")
    elif rule["autoBlock"] != (rule.get("severity") == "CRITICAL"):
        errors.append(f"{rid} autoBlock must match CRITICAL severity")
    if rule.get("type") == "dependency":
        file_scope = rule.get("fileScope")
        excluded_prefixes = rule.get("excludedPathPrefixes")
        if not isinstance(file_scope, list) or not file_scope or not all(isinstance(item, str) and item for item in file_scope):
            errors.append(f"{rid} missing non-empty dependency fileScope")
        if not isinstance(excluded_prefixes, list) or not excluded_prefixes or not all(isinstance(item, str) and item for item in excluded_prefixes):
            errors.append(f"{rid} missing non-empty dependency excludedPathPrefixes")
        if rid in expected_dependency_scopes and set(file_scope or []) != expected_dependency_scopes[rid]:
            errors.append(f"{rid} unexpected fileScope: {file_scope}")
        if set(excluded_prefixes or []) != expected_dependency_exclusions:
            errors.append(f"{rid} unexpected excludedPathPrefixes: {excluded_prefixes}")
    fixture = rule.get("fixture")
    if isinstance(fixture, str) and not (fixtures / fixture).is_file():
        errors.append(f"{rid} fixture not found: {fixture}")

pattern_defs = []
in_patterns = False
for raw in scanner.read_text().splitlines():
    line = raw.strip()
    if line == "declare -a PATTERNS=(":
        in_patterns = True
        continue
    if in_patterns and line == ")":
        in_patterns = False
        continue
    if not in_patterns or not line.startswith('"') or not line.endswith('"'):
        continue
    value = line[1:-1]
    parts = value.split("|", 4)
    if len(parts) != 5:
        errors.append(f"malformed pattern definition: {line}")
        continue
    rule_id, rule_type, severity, pattern, _regex = parts
    pattern_defs.append((rule_id, rule_type, severity, pattern))

scanner_ids = [item[0] for item in pattern_defs]
if len(scanner_ids) != len(set(scanner_ids)):
    errors.append("scanner pattern rule IDs must be unique")
if set(scanner_ids) != set(catalog_by_id):
    errors.append(
        "scanner/catalog rule IDs differ: "
        f"scanner_only={sorted(set(scanner_ids)-set(catalog_by_id))} "
        f"catalog_only={sorted(set(catalog_by_id)-set(scanner_ids))}"
    )
for rule_id, rule_type, severity, pattern in pattern_defs:
    rule = catalog_by_id.get(rule_id)
    if not rule:
        continue
    if rule.get("type") != rule_type or rule.get("severity") != severity or rule.get("pattern") != pattern:
        errors.append(f"catalog metadata mismatch for {rule_id}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
then
  pass "catalog matches scanner rule definitions"
else
  fail "catalog matches scanner rule definitions" "Python contract check failed"
fi

echo ""
echo "=== Fixture behavior ==="
CLEAN_JSON=$(run_fixture clean.patch)
assert_jq "clean patch produces no findings" '.summaryCounts.critical == 0 and .summaryCounts.major == 0 and .summaryCounts.minor == 0 and .summaryCounts.total == 0' "$CLEAN_JSON"
assert_jq "clean patch produces no suppression records" '.summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$CLEAN_JSON"
assert_jq "clean output preserves top-level fields" 'has("scannedAt") and has("patchFile") and (.findings|type == "array") and (.suppressedFindings|type == "array") and (.rejectedSuppressions|type == "array") and (.summaryCounts|type == "object")' "$CLEAN_JSON"

NON_ADDED_JSON=$(run_fixture non-added-line.patch)
assert_jq "non-added rule-like lines do not trigger" '.summaryCounts.total == 0' "$NON_ADDED_JSON"

BENIGN_JSON=$(run_fixture benign-close.patch)
assert_jq "benign close cases do not trigger" '.summaryCounts.total == 0' "$BENIGN_JSON"

ALL_RULES_JSON=$(run_fixture all-rules.patch)
assert_jq "all-rules fixture total is stable" '.summaryCounts.critical == 6 and .summaryCounts.major == 5 and .summaryCounts.minor == 3 and .summaryCounts.total == 14' "$ALL_RULES_JSON"
assert_jq "all-rules fixture has no suppressions" '.summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$ALL_RULES_JSON"
assert_jq "CRITICAL findings preserve AUTO_BLOCK input" '.summaryCounts.critical > 0' "$ALL_RULES_JSON"
assert_jq "legacy finding fields are preserved" 'all(.findings[]; has("type") and has("pattern") and has("file") and has("line") and has("snippet") and has("severity"))' "$ALL_RULES_JSON"
assert_jq "every finding has a stable ruleId" 'all(.findings[]; (.ruleId|type == "string") and (.ruleId|startswith("POLICY_")))' "$ALL_RULES_JSON"
assert_jq "duplicate legacy pattern name remains compatible" '[.findings[] | select(.pattern == "incomplete_implementation")] | length == 2' "$ALL_RULES_JSON"

if CATALOG="$CATALOG" ALL_RULES_JSON="$ALL_RULES_JSON" python3 - <<'PY'
import json
import os
import sys

catalog = json.load(open(os.environ["CATALOG"], encoding="utf-8"))
scan = json.load(open(os.environ["ALL_RULES_JSON"], encoding="utf-8"))
known = {rule["ruleId"] for rule in catalog["rules"]}
found = [finding.get("ruleId") for finding in scan["findings"]]
errors = []
if set(found) != known:
    errors.append(f"fixture rule coverage mismatch: missing={sorted(known - set(found))} extra={sorted(set(found) - known)}")
if len(found) != len(set(found)):
    errors.append("all-rules fixture should trigger each rule exactly once")
for finding in scan["findings"]:
    if finding.get("ruleId") not in known:
        errors.append(f"unknown ruleId in output: {finding.get('ruleId')}")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
then
  pass "all catalog rules are covered by fixtures"
else
  fail "all catalog rules are covered by fixtures" "Python coverage check failed"
fi

echo ""
echo "=== Dependency file scope ==="
DEP_NPM_JSON=$(run_fixture dependency-npm-manifest.patch)
assert_jq "npm dependency triggers in package.json" '.summaryCounts.major == 1 and .summaryCounts.total == 1 and .findings[0].ruleId == "POLICY_NEW_NPM_DEPENDENCY"' "$DEP_NPM_JSON"

DEP_NPM_DOCS_JSON=$(run_fixture dependency-npm-docs-no-trigger.patch)
assert_jq "npm dependency-like docs line does not trigger" '.summaryCounts.total == 0 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$DEP_NPM_DOCS_JSON"

DEP_PYTHON_JSON=$(run_fixture dependency-python-manifest.patch)
assert_jq "python dependency triggers in requirements.txt" '.summaryCounts.major == 1 and .summaryCounts.total == 1 and .findings[0].ruleId == "POLICY_NEW_PYTHON_DEPENDENCY"' "$DEP_PYTHON_JSON"

DEP_PYTHON_DOCS_JSON=$(run_fixture dependency-python-docs-no-trigger.patch)
assert_jq "python dependency-like docs line does not trigger" '.summaryCounts.total == 0 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$DEP_PYTHON_DOCS_JSON"

DEP_CARGO_JSON=$(run_fixture dependency-cargo-manifest.patch)
assert_jq "cargo dependency triggers in Cargo.toml" '.summaryCounts.major == 1 and .summaryCounts.total == 1 and .findings[0].ruleId == "POLICY_NEW_CARGO_DEPENDENCY"' "$DEP_CARGO_JSON"

DEP_GO_JSON=$(run_fixture dependency-go-manifest.patch)
assert_jq "go dependency triggers in go.mod" '.summaryCounts.major == 1 and .summaryCounts.total == 1 and .findings[0].ruleId == "POLICY_NEW_GO_DEPENDENCY"' "$DEP_GO_JSON"

DEP_SUPPRESS_JSON=$(run_fixture dependency-suppression-manifest.patch)
assert_jq "dependency suppression still works in manifest" '.summaryCounts.total == 0 and .summaryCounts.suppressed == 1 and .suppressedFindings[0].ruleId == "POLICY_NEW_NPM_DEPENDENCY"' "$DEP_SUPPRESS_JSON"

DEP_SUPPRESS_DOCS_JSON=$(run_fixture dependency-suppression-docs-no-finding.patch)
assert_jq "out-of-scope docs dependency suppression creates no finding" '.summaryCounts.total == 0 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$DEP_SUPPRESS_DOCS_JSON"

echo ""
echo "=== Suppression behavior ==="
SUPPRESS_MINOR_JSON=$(run_fixture suppression-minor.patch)
assert_jq "valid MINOR suppression removes active finding" '.summaryCounts.total == 0 and .summaryCounts.minor == 0 and .summaryCounts.suppressed == 1' "$SUPPRESS_MINOR_JSON"
assert_jq "suppressed MINOR finding is retained with reason" '.suppressedFindings[0].ruleId == "POLICY_DEBUG_PRINT" and .suppressedFindings[0].suppressionReason == "temporary debug output in CLI fixture" and .suppressedFindings[0].suppressionScope == "next-added-line"' "$SUPPRESS_MINOR_JSON"

SUPPRESS_SAME_LINE_JSON=$(run_fixture suppression-same-line.patch)
assert_jq "same-line suppression is supported" '.summaryCounts.total == 0 and .summaryCounts.suppressed == 1 and .suppressedFindings[0].suppressionScope == "same-line"' "$SUPPRESS_SAME_LINE_JSON"

SUPPRESS_MAJOR_JSON=$(run_fixture suppression-major.patch)
assert_jq "valid MAJOR suppression removes active finding" '.summaryCounts.total == 0 and .summaryCounts.major == 0 and .summaryCounts.suppressed == 1' "$SUPPRESS_MAJOR_JSON"
assert_jq "suppressed MAJOR finding is retained with ruleId" '.suppressedFindings[0].ruleId == "POLICY_NEW_NPM_DEPENDENCY" and .suppressedFindings[0].suppressionReason == "temporary fixture dependency"' "$SUPPRESS_MAJOR_JSON"

SUPPRESS_CRITICAL_JSON=$(run_fixture suppression-critical-rejected.patch)
assert_jq "CRITICAL suppression attempt leaves active finding" '.summaryCounts.critical == 1 and .summaryCounts.total == 1 and .summaryCounts.suppressed == 0' "$SUPPRESS_CRITICAL_JSON"
assert_jq "CRITICAL suppression attempt is rejected" '.summaryCounts.rejectedSuppressions == 1 and .rejectedSuppressions[0].ruleId == "POLICY_DYNAMIC_CODE_EXECUTION" and .rejectedSuppressions[0].rejectedReason == "critical_not_suppressible"' "$SUPPRESS_CRITICAL_JSON"

SUPPRESS_WRONG_RULE_JSON=$(run_fixture suppression-wrong-rule.patch)
assert_jq "wrong ruleId does not suppress another rule" '.summaryCounts.major == 1 and .summaryCounts.total == 1 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0 and .findings[0].ruleId == "POLICY_WEAK_CRYPTO"' "$SUPPRESS_WRONG_RULE_JSON"

SUPPRESS_UNKNOWN_JSON=$(run_fixture suppression-unknown-rule.patch)
assert_jq "unknown ruleId suppression is rejected" '.summaryCounts.minor == 1 and .summaryCounts.total == 1 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 1 and .rejectedSuppressions[0].rejectedReason == "unknown_rule_id"' "$SUPPRESS_UNKNOWN_JSON"

SUPPRESS_MISSING_REASON_JSON=$(run_fixture suppression-missing-reason.patch)
assert_jq "missing reason suppression is rejected" '.summaryCounts.minor == 1 and .summaryCounts.total == 1 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 1 and .rejectedSuppressions[0].rejectedReason == "missing_reason"' "$SUPPRESS_MISSING_REASON_JSON"

SUPPRESS_SCOPE_JSON=$(run_fixture suppression-scope.patch)
assert_jq "suppression scope does not extend to later or cross-file findings" '.summaryCounts.minor == 2 and .summaryCounts.total == 2 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$SUPPRESS_SCOPE_JSON"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
