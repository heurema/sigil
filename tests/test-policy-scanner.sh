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
  dependency-suppression-docs-no-finding.patch \
  debug-print-production.patch \
  debug-print-examples-no-trigger.patch \
  debug-print-nonproduction-prefixes.patch; do
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
expected_rules = {
    "POLICY_DYNAMIC_CODE_EXECUTION": {
        "type": "security",
        "severity": "CRITICAL",
        "pattern": "dynamic_code_execution",
        "regex": r"eval\s*\(|new\s+Function\s*\(|__import__\s*\(",
    },
    "POLICY_XSS_SINK": {
        "type": "security",
        "severity": "CRITICAL",
        "pattern": "xss_sink",
        "regex": r"innerHTML\s*=|outerHTML\s*=|document\.write\s*\(|insertAdjacentHTML\s*\(",
    },
    "POLICY_SQL_INJECTION": {
        "type": "security",
        "severity": "CRITICAL",
        "pattern": "sql_injection",
        "regex": "(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE).*[+%].*['\\\"]|['\\\"].*[+%].*(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE)",
    },
    "POLICY_SUBPROCESS_SHELL_INJECTION": {
        "type": "security",
        "severity": "CRITICAL",
        "pattern": "subprocess_shell_injection",
        "regex": r"shell\s*=\s*True|subprocess\.(call|run|Popen)\s*\(|os\.system\s*\(|child_process\.(exec|execSync|spawn)\s*\(",
    },
    "POLICY_WEAK_CRYPTO": {
        "type": "security",
        "severity": "MAJOR",
        "pattern": "weak_crypto",
        "regex": r"md5\s*\(|sha1\s*\(|DES\.|RC4\.|hashlib\.md5|hashlib\.sha1",
    },
    "POLICY_UNCHECKED_ANY": {
        "type": "unsafe",
        "severity": "MINOR",
        "pattern": "unchecked_any",
        "regex": r":\s*any\b|as\s+any\b",
    },
    "POLICY_INCOMPLETE_MARKER": {
        "type": "unsafe",
        "severity": "CRITICAL",
        "pattern": "incomplete_implementation",
        "regex": "TODO:|FIXME:|HACK:|XXX:",
    },
    "POLICY_INCOMPLETE_STUB": {
        "type": "unsafe",
        "severity": "CRITICAL",
        "pattern": "incomplete_implementation",
        "regex": "panic\\(\\\"not implemented\\\"\\)|panic\\(\\\"todo\\\"\\)|raise\\s+NotImplementedError|throw\\s+new\\s+Error\\(\\\"TODO\\\"\\)",
    },
    "POLICY_SUSPICIOUS_RETURN": {
        "type": "unsafe",
        "severity": "MINOR",
        "pattern": "suspicious_return",
        "regex": r"return nil\s*//|return nil\s*$|return null\s*//\s*TODO",
    },
    "POLICY_DEBUG_PRINT": {
        "type": "unsafe",
        "severity": "MINOR",
        "pattern": "debug_print",
        "regex": r"console\.log\s*\(|debugger\s*;|pprint\s*\(|console\.debug\s*\(",
    },
    "POLICY_NEW_NPM_DEPENDENCY": {
        "type": "dependency",
        "severity": "MAJOR",
        "pattern": "new_npm_dependency",
        "regex": "\\\"[a-zA-Z0-9@/_-]+\\\"\\s*:\\s*\\\"[~^]?[0-9*]",
    },
    "POLICY_NEW_CARGO_DEPENDENCY": {
        "type": "dependency",
        "severity": "MAJOR",
        "pattern": "new_cargo_dependency",
        "regex": "^[a-zA-Z0-9_-]+\\s*=\\s*[\\\"{]",
    },
    "POLICY_NEW_PYTHON_DEPENDENCY": {
        "type": "dependency",
        "severity": "MAJOR",
        "pattern": "new_python_dependency",
        "regex": "\\\"[a-zA-Z0-9_.-]+[><=!~]|'[a-zA-Z0-9_.-]+[><=!~]|^\\s*[a-zA-Z0-9_.-]+[><=!~]",
    },
    "POLICY_NEW_GO_DEPENDENCY": {
        "type": "dependency",
        "severity": "MAJOR",
        "pattern": "new_go_dependency",
        "regex": r"[a-z][a-zA-Z0-9._/-]*/[a-zA-Z0-9_-]+\s+v[0-9]+\.[0-9]",
    },
}
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
expected_nonproduction_exclusions = {"docs/", "examples/", "fixtures/", "tests/", "test/"}
expected_rule_exclusions = {
    "POLICY_DEBUG_PRINT": expected_nonproduction_exclusions,
    "POLICY_NEW_NPM_DEPENDENCY": expected_nonproduction_exclusions,
    "POLICY_NEW_CARGO_DEPENDENCY": expected_nonproduction_exclusions,
    "POLICY_NEW_PYTHON_DEPENDENCY": expected_nonproduction_exclusions,
    "POLICY_NEW_GO_DEPENDENCY": expected_nonproduction_exclusions,
}
for index, rule in enumerate(rules):
    rid = rule.get("ruleId")
    if not isinstance(rid, str) or not rid.startswith("POLICY_"):
        errors.append(f"catalog rule {index} has invalid ruleId")
        continue
    if rid in catalog_by_id:
        errors.append(f"duplicate catalog ruleId: {rid}")
    catalog_by_id[rid] = rule
    for field in ("type", "severity", "pattern", "description", "fixture", "engine", "regex"):
        if not isinstance(rule.get(field), str) or not rule[field]:
            errors.append(f"{rid} missing non-empty {field}")
    if rule.get("engine") != "regex":
        errors.append(f"{rid} engine must be regex")
    if "\t" in str(rule.get("regex", "")):
        errors.append(f"{rid} regex must not contain a literal tab")
    if not isinstance(rule.get("autoBlock"), bool):
        errors.append(f"{rid} missing boolean autoBlock")
    elif rule["autoBlock"] != (rule.get("severity") == "CRITICAL"):
        errors.append(f"{rid} autoBlock must match CRITICAL severity")
    if not isinstance(rule.get("suppressible"), bool):
        errors.append(f"{rid} missing boolean suppressible")
    elif rule.get("severity") == "CRITICAL" and rule["suppressible"] is not False:
        errors.append(f"{rid} CRITICAL rule must not be suppressible")
    elif rule.get("severity") != "CRITICAL" and rule["suppressible"] is not True:
        errors.append(f"{rid} non-critical rule must remain suppressible")
    excluded_prefixes = rule.get("excludedPathPrefixes")
    if excluded_prefixes is not None:
        if not isinstance(excluded_prefixes, list) or not excluded_prefixes or not all(isinstance(item, str) and item and "\t" not in item for item in excluded_prefixes):
            errors.append(f"{rid} invalid excludedPathPrefixes")
    if rid in expected_rule_exclusions:
        if set(excluded_prefixes or []) != expected_rule_exclusions[rid]:
            errors.append(f"{rid} unexpected excludedPathPrefixes: {excluded_prefixes}")
    elif excluded_prefixes is not None:
        errors.append(f"{rid} has unexpected excludedPathPrefixes: {excluded_prefixes}")
    if rule.get("type") == "dependency":
        file_scope = rule.get("fileScope")
        if not isinstance(file_scope, list) or not file_scope or not all(isinstance(item, str) and item for item in file_scope):
            errors.append(f"{rid} missing non-empty dependency fileScope")
        if rid in expected_dependency_scopes and set(file_scope or []) != expected_dependency_scopes[rid]:
            errors.append(f"{rid} unexpected fileScope: {file_scope}")
    fixture = rule.get("fixture")
    if isinstance(fixture, str) and not (fixtures / fixture).is_file():
        errors.append(f"{rid} fixture not found: {fixture}")

if set(expected_rules) != set(catalog_by_id):
    errors.append(
        "catalog rule IDs differ from externalized scanner baseline: "
        f"missing={sorted(set(expected_rules)-set(catalog_by_id))} "
        f"extra={sorted(set(catalog_by_id)-set(expected_rules))}"
    )
for rule_id, expected in expected_rules.items():
    rule = catalog_by_id.get(rule_id)
    if not rule:
        continue
    for field, expected_value in expected.items():
        if rule.get(field) != expected_value:
            errors.append(f"{rule_id} {field} changed: expected {expected_value!r}, got {rule.get(field)!r}")

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
echo "=== Catalog loading behavior ==="
EXPLICIT_DIR="$WORK/explicit-catalog"
mkdir -p "$EXPLICIT_DIR"
cp "$FIXTURES/clean.patch" "$EXPLICIT_DIR/combined.patch"
SIGNUM_POLICY_RULE_CATALOG="$CATALOG" "$SCRIPT" "$EXPLICIT_DIR/combined.patch" >/dev/null
assert_jq "scanner runs with explicit SIGNUM_POLICY_RULE_CATALOG" '.summaryCounts.total == 0' "$EXPLICIT_DIR/policy_scan.json"

ALIAS_DIR="$WORK/alias-catalog"
mkdir -p "$ALIAS_DIR"
cp "$FIXTURES/clean.patch" "$ALIAS_DIR/combined.patch"
SIGNUM_POLICY_PATTERN_CATALOG="$CATALOG" "$SCRIPT" "$ALIAS_DIR/combined.patch" >/dev/null
assert_jq "scanner runs with legacy SIGNUM_POLICY_PATTERN_CATALOG alias" '.summaryCounts.total == 0' "$ALIAS_DIR/policy_scan.json"

MISSING_DIR="$WORK/missing-catalog"
mkdir -p "$MISSING_DIR"
cp "$FIXTURES/clean.patch" "$MISSING_DIR/combined.patch"
if SIGNUM_POLICY_RULE_CATALOG="$WORK/missing-policy-rules.json" "$SCRIPT" "$MISSING_DIR/combined.patch" >/dev/null 2>"$WORK/missing-catalog.err"; then
  fail "scanner fails closed for missing catalog" "scanner unexpectedly succeeded"
else
  if grep -q "policy rule catalog not found" "$WORK/missing-catalog.err"; then
    pass "scanner fails closed for missing catalog"
  else
    fail "scanner fails closed for missing catalog" "$(cat "$WORK/missing-catalog.err")"
  fi
fi

MALFORMED_CATALOG="$WORK/malformed-policy-rules.json"
printf '%s\n' '{"schemaVersion":"1.0","rules":[{"ruleId":"POLICY_BAD"}]}' > "$MALFORMED_CATALOG"
MALFORMED_DIR="$WORK/malformed-catalog"
mkdir -p "$MALFORMED_DIR"
cp "$FIXTURES/clean.patch" "$MALFORMED_DIR/combined.patch"
if SIGNUM_POLICY_RULE_CATALOG="$MALFORMED_CATALOG" "$SCRIPT" "$MALFORMED_DIR/combined.patch" >/dev/null 2>"$WORK/malformed-catalog.err"; then
  fail "scanner fails closed for malformed catalog" "scanner unexpectedly succeeded"
else
  if grep -q "policy rule catalog validation failed" "$WORK/malformed-catalog.err"; then
    pass "scanner fails closed for malformed catalog"
  else
    fail "scanner fails closed for malformed catalog" "$(cat "$WORK/malformed-catalog.err")"
  fi
fi

CONFLICT_DIR="$WORK/conflicting-catalog"
mkdir -p "$CONFLICT_DIR"
cp "$FIXTURES/clean.patch" "$CONFLICT_DIR/combined.patch"
if SIGNUM_POLICY_RULE_CATALOG="$CATALOG" SIGNUM_POLICY_PATTERN_CATALOG="$CATALOG" "$SCRIPT" "$CONFLICT_DIR/combined.patch" >/dev/null 2>"$WORK/conflicting-catalog.err"; then
  fail "scanner fails closed for conflicting catalog env vars" "scanner unexpectedly succeeded"
else
  if grep -q "set only one of SIGNUM_POLICY_RULE_CATALOG or SIGNUM_POLICY_PATTERN_CATALOG" "$WORK/conflicting-catalog.err"; then
    pass "scanner fails closed for conflicting catalog env vars"
  else
    fail "scanner fails closed for conflicting catalog env vars" "$(cat "$WORK/conflicting-catalog.err")"
  fi
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
echo "=== Rule-level path scope ==="
DEBUG_PROD_JSON=$(run_fixture debug-print-production.patch)
assert_jq "debug print triggers in production src path" '.summaryCounts.minor == 1 and .summaryCounts.total == 1 and .findings[0].ruleId == "POLICY_DEBUG_PRINT"' "$DEBUG_PROD_JSON"

DEBUG_EXAMPLES_JSON=$(run_fixture debug-print-examples-no-trigger.patch)
assert_jq "debug print does not trigger in examples path" '.summaryCounts.total == 0 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$DEBUG_EXAMPLES_JSON"

DEBUG_NONPROD_JSON=$(run_fixture debug-print-nonproduction-prefixes.patch)
assert_jq "debug print does not trigger in docs fixtures tests or test paths" '.summaryCounts.total == 0 and .summaryCounts.suppressed == 0 and .summaryCounts.rejectedSuppressions == 0' "$DEBUG_NONPROD_JSON"

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
