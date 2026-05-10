#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/shell-basic"
CONTRACT="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts/shell-json-checker-contract.json"
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

make_project() {
  local name="$1"
  local project="$WORK/$name"
  cp -R "$FIXTURE" "$project"
  mkdir -p "$project/.signum/contracts/shell"
  cp "$CONTRACT" "$project/.signum/contracts/shell/contract.json"
  printf '%s\n' "$project"
}

run_scanner() {
  local project="$1"
  local index_output="$2"
  local style_output="$3"
  local digests_output="$4"
  local extracts_output="$5"
  shift 5
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output "$index_output" \
      --style-output "$style_output" \
      --digests-output "$digests_output" \
      --extracts-output "$extracts_output" \
      --generated-at "2026-01-01T00:00:00Z" \
      "$@"
  )
}

run_matcher() {
  local project="$1"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/shell/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/shell/reuse_candidates.json" \
      --implementation-context ".signum/contracts/shell/implementation_context.json" \
      --max-candidates 12 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

PROJECT_A="$(make_project run-a)"
PROJECT_B="$(make_project run-b)"

INDEX_A="$PROJECT_A/.signum/cache/codebase-index-v1.json"
STYLE_A="$PROJECT_A/.signum/cache/style-profile-v1.json"
DIGEST_A="$PROJECT_A/.signum/cache/file-digests-v1.json"
EXTRACTS_A="$PROJECT_A/.signum/cache/file-extracts-v1.json"
CACHED_INDEX="$PROJECT_A/.signum/cache/codebase-index-cached.json"
CACHED_STYLE="$PROJECT_A/.signum/cache/style-profile-cached.json"
CACHED_DIGEST="$PROJECT_A/.signum/cache/file-digests-cached.json"
CACHED_EXTRACTS="$PROJECT_A/.signum/cache/file-extracts-cached.json"
INDEX_B="$PROJECT_B/.signum/cache/codebase-index-v1.json"
STYLE_B="$PROJECT_B/.signum/cache/style-profile-v1.json"
DIGEST_B="$PROJECT_B/.signum/cache/file-digests-v1.json"
EXTRACTS_B="$PROJECT_B/.signum/cache/file-extracts-v1.json"
REUSE_A="$PROJECT_A/.signum/contracts/shell/reuse_candidates.json"
CONTEXT_A="$PROJECT_A/.signum/contracts/shell/implementation_context.json"

echo "=== Shell scanner run ==="
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json"; then
  pass "scanner exits 0 on shell fixture"
else
  fail "scanner exits 0 on shell fixture" "command failed"
fi

if [ -f "$INDEX_A" ] && [ -f "$STYLE_A" ] && [ -f "$DIGEST_A" ] && [ -f "$EXTRACTS_A" ]; then
  pass "scanner writes shell index, style, digest, and extracts artifacts"
else
  fail "scanner writes shell index, style, digest, and extracts artifacts" "missing output"
fi

echo ""
echo "=== Shell scanner artifact contract ==="
if python3 - "$INDEX_A" "$STYLE_A" "$DIGEST_A" "$EXTRACTS_A" "$PROJECT_A" <<'PY'
import json
import sys
from pathlib import Path

index = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
style = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
digests = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
extracts = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
project = sys.argv[5]
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def records(section):
    value = index.get(section, [])
    return value if isinstance(value, list) else []


def find(section, **criteria):
    for item in records(section):
        if all(item.get(key) == value for key, value in criteria.items()):
            return item
    return None


def symbol(name, path=None):
    for item in records("symbols"):
        if item.get("name") != name:
            continue
        if path is not None and item.get("path") != path:
            continue
        return item
    return None


def import_record(path, imported=None, resolved=None, kind=None):
    for item in records("imports"):
        if item.get("path") != path:
            continue
        if imported is not None and item.get("imported") != imported:
            continue
        if resolved is not None and item.get("resolvedPath") != resolved:
            continue
        if kind is not None and item.get("kind") != kind:
            continue
        return item
    return None


def boundary(path, kind):
    return any(item.get("path") == path and item.get("kind") == kind for item in records("moduleBoundaries"))


def extract_payload(path):
    return extracts.get("files", {}).get(path, {})


detected = {item.get("language"): item.get("fileCount") for item in records("languageDetections")}
require(detected.get("shell", 0) >= 7, "Shell language detection missing or too small")
require(index.get("primaryLanguages") == ["shell"], "Shell primary language missing")
require(find("modules", path="scripts/policy-entry", language="shell") is not None, "extensionless /bin/sh shebang script not detected")
require(find("modules", path="scripts/zsh-entry", language="shell") is not None, "extensionless /usr/bin/env zsh shebang script not detected")

json_payload = extract_payload("lib/json-output.sh")
policy_payload = extract_payload("lib/policy-check.sh")
test_payload = extract_payload("tests/test-policy-check.sh")
zsh_payload = extract_payload("scripts/zsh-entry")
require(json_payload.get("fileTextSignals", {}).get("shellShebang") is True, "shell shebang signal missing")
require(zsh_payload.get("fileTextSignals", {}).get("shellShebang") is True, "zsh shebang signal missing")
require(json_payload.get("fileTextSignals", {}).get("shellStrictMode") is True, "set -euo pipefail signal missing")

expected_symbols = {
    ("emit_json_report", "lib/json-output.sh"),
    ("write_json_file", "lib/json-output.sh"),
    ("contract_dir_for", "lib/contract-dir.sh"),
    ("main", "lib/policy-check.sh"),
    ("pass", "tests/test-policy-check.sh"),
    ("fail", "tests/test-policy-check.sh"),
}
for name, path in expected_symbols:
    item = symbol(name, path)
    require(item is not None, f"missing shell function symbol {name}")
    if item:
        require(item.get("kind") == "function", f"{name} kind mismatch")
        require(item.get("language") == "shell", f"{name} language mismatch")
        require(item.get("visibility") == "function", f"{name} visibility missing")
        require(item.get("exported") is True, f"{name} exported flag missing")
        require(item.get("tokens"), f"{name} tokens missing")

contract_import = import_record("lib/policy-check.sh", imported="$ROOT_DIR/lib/contract-dir.sh", resolved="lib/contract-dir.sh", kind="source")
json_import = import_record("lib/policy-check.sh", imported="$ROOT_DIR/lib/json-output.sh", resolved="lib/json-output.sh", kind="source")
test_source = import_record("tests/test-policy-check.sh", imported="lib/json-output.sh", resolved="lib/json-output.sh", kind="source")
test_call = import_record("tests/test-policy-check.sh", imported="lib/policy-check.sh", resolved="lib/policy-check.sh", kind="shell-call")
fragment_call = import_record("commands/signum.fragments/90-phase-audit.md", imported="scripts/run-policy-check.sh", resolved="scripts/run-policy-check.sh", kind="shell-call")
require(contract_import is not None, "dot source import did not resolve")
require(json_import is not None, "source import did not resolve")
require(test_source is not None, "test source import did not resolve")
require(test_call is not None, "test bash call did not resolve")
require(fragment_call is not None, "command fragment bash call did not resolve")

require(json_payload.get("fileTextSignals", {}).get("shellJsonOutputPattern") is True, "JSON-emitting helper pattern missing")
require(policy_payload.get("fileTextSignals", {}).get("shellCiAnnotationPattern") is True, "GitHub annotation pattern missing")
require(policy_payload.get("fileTextSignals", {}).get("shellExit78") is True, "exit 78 convention missing")
require(test_payload.get("fileTextSignals", {}).get("shellUsesJq") is True, "jq convention missing")
require(test_payload.get("fileTextSignals", {}).get("shellPythonJsonValidation") is True, "python JSON validation pattern missing")
require(test_payload.get("fileTextSignals", {}).get("shellJsonValidationPattern") is True, "JSON validation pattern missing")

test_record = find("tests", path="tests/test-policy-check.sh")
require(test_record is not None, "shell test record missing")
if test_record:
    require(test_record.get("framework") == "shell-test", "shell-test framework missing")
    require(set(test_record.get("testFunctions", [])) == {"fail", "pass"}, "shell test functions missing")
    require({"lib/json-output.sh", "lib/policy-check.sh"} <= set(test_record.get("targetPaths", [])), "shell test target paths missing")

json_candidate = find("sharedCandidates", path="lib/json-output.sh")
require(json_candidate is not None, "shell JSON helper shared candidate missing")
if json_candidate:
    reasons = set(json_candidate.get("reasons", []))
    require({"sourced-by-local-files", "json-output-pattern", "imported-by-local-files", "paired-test", "exported-symbols"} <= reasons, "JSON helper lacks multiple evidence signals")
    require(json_candidate.get("usageCount", 0) >= 2, "JSON helper fan-in missing")
    require({"lib/policy-check.sh", "tests/test-policy-check.sh"} <= set(json_candidate.get("importedBy", [])), "JSON helper importedBy evidence missing")
    require("tests/test-policy-check.sh" in json_candidate.get("pairedTests", []), "JSON helper paired test missing")
    require({"emit_json_report", "write_json_file"} <= set(json_candidate.get("symbols", [])), "JSON helper symbols missing")

policy_candidate = find("sharedCandidates", path="lib/policy-check.sh")
require(policy_candidate is not None, "shell checker candidate missing")
if policy_candidate:
    require("called-from-local-files" in set(policy_candidate.get("reasons", [])), "shell checker local call evidence missing")
    require("json-output-pattern" in set(policy_candidate.get("reasons", [])), "shell checker JSON evidence missing")

require(find("sharedCandidates", path="lib/utils.sh") is None, "weak lib/utils.sh became shared candidate from weak prior only")
require(boundary("lib/utils.sh", "shared-name-weak"), "weak shared-name boundary missing")
require(boundary("commands/signum.fragments/90-phase-audit.md", "shell-command-fragment"), "command fragment boundary missing")
require(find("sharedCandidates", path="commands/signum.fragments/90-phase-audit.md") is None, "command fragment became shared helper candidate")
require(boundary("scripts/run-policy-check.sh", "shell-executable-script"), "shell executable script boundary missing")
require(boundary("scripts/policy-entry", "shell-executable-script"), "extensionless executable script boundary missing")
require(boundary("scripts/zsh-entry", "shell-executable-script"), "extensionless zsh executable script boundary missing")
require(find("sharedCandidates", path="scripts/run-policy-check.sh") is None, "executable wrapper became shared helper candidate")
require(find("sharedCandidates", path="scripts/zsh-entry") is None, "extensionless zsh executable script became shared helper candidate")
require(boundary("scripts/run-policy-check.sh", "shell-tempdir-trap-cleanup"), "tempdir/trap cleanup boundary missing")
require(boundary("tests/test-policy-check.sh", "shell-test-file"), "shell test boundary missing")

for cache, label in ((digests, "digests"), (extracts, "extracts")):
    files = cache.get("files", {})
    require("lib/json-output.sh" in files, f"{label} missing shell helper")
    require("scripts/policy-entry" in files, f"{label} missing shebang extensionless shell script")
    require("scripts/zsh-entry" in files, f"{label} missing zsh shebang extensionless shell script")
    require("tests/test-policy-check.sh" in files, f"{label} missing shell test")
require(any(item.get("name") == "emit_json_report" for item in json_payload.get("symbols", [])), "extract cache missing shell symbols")
require(any(item.get("imported") == "$ROOT_DIR/lib/json-output.sh" for item in policy_payload.get("imports", [])), "extract cache missing shell source imports")

serialized = json.dumps([index, style, digests, extracts], sort_keys=True)
require(project not in serialized, "scanner artifacts leaked temp project path")
require(style.get("shellConventions"), "shellConventions style profile section missing")
require("JSON-emitting checker pattern" in json.dumps(style.get("shellConventions", [])), "shell JSON convention missing from style")
require("test-*.sh" in json.dumps(style.get("testConventions", [])), "shell test convention missing from style")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "shell scanner signals, boundaries, tests, and cache payloads are valid"
else
  fail "shell scanner signals, boundaries, tests, and cache payloads are valid" "Python assertion failed"
fi

echo ""
echo "=== Shell cache parity and determinism ==="
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-cached.json" ".signum/cache/style-profile-cached.json" ".signum/cache/file-digests-cached.json" ".signum/cache/file-extracts-cached.json" --previous-extracts ".signum/cache/file-extracts-v1.json"; then
  pass "cached scanner exits 0 on shell fixture"
else
  fail "cached scanner exits 0 on shell fixture" "command failed"
fi

if run_scanner "$PROJECT_B" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json"; then
  pass "second full scanner exits 0 on shell fixture"
else
  fail "second full scanner exits 0 on shell fixture" "command failed"
fi

if python3 - "$INDEX_A" "$STYLE_A" "$DIGEST_A" "$EXTRACTS_A" "$CACHED_INDEX" "$CACHED_STYLE" "$CACHED_DIGEST" "$CACHED_EXTRACTS" "$INDEX_B" "$STYLE_B" "$DIGEST_B" "$EXTRACTS_B" <<'PY'
import copy
import json
import sys
from pathlib import Path

labels = (
    "index_a",
    "style_a",
    "digest_a",
    "extracts_a",
    "cached_index",
    "cached_style",
    "cached_digest",
    "cached_extracts",
    "index_b",
    "style_b",
    "digest_b",
    "extracts_b",
)
data = {label: json.loads(Path(path).read_text(encoding="utf-8")) for label, path in zip(labels, sys.argv[1:])}
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def without_reuse(value):
    cloned = copy.deepcopy(value)
    stats = cloned.get("scanStats")
    if isinstance(stats, dict):
        stats.pop("filesReused", None)
        stats.pop("filesExtracted", None)
    return cloned


require(data["cached_index"].get("scanStats", {}).get("filesReused", 0) > 0, "cached index did not reuse shell file extractions")
require(without_reuse(data["index_a"]) == without_reuse(data["cached_index"]), "cached/full shell index parity failed")
require(data["style_a"] == data["cached_style"], "cached/full shell style parity failed")
require(data["index_a"] == data["index_b"], "fixed-time shell index determinism failed")
require(data["style_a"] == data["style_b"], "fixed-time shell style determinism failed")
require(data["extracts_a"] == data["extracts_b"], "fixed-time shell extracts determinism failed")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "cached/full parity and fixed generatedAt determinism hold for shell fixture"
else
  fail "cached/full parity and fixed generatedAt determinism hold for shell fixture" "Python assertion failed"
fi

echo ""
echo "=== Shell matcher behavior ==="
if run_matcher "$PROJECT_A"; then
  pass "matcher exits 0 on shell fixture"
else
  fail "matcher exits 0 on shell fixture" "command failed"
fi

if [ -f "$REUSE_A" ] && [ -f "$CONTEXT_A" ]; then
  pass "matcher writes shell reuse candidates and implementation context"
else
  fail "matcher writes shell reuse candidates and implementation context" "missing output"
fi

if python3 - "$REUSE_A" "$CONTEXT_A" "$PROJECT_A" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
context = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
project = sys.argv[3]
errors = []
candidates = reuse.get("candidates", [])


def require(condition, message):
    if not condition:
        errors.append(message)


require(candidates, "matcher produced no shell candidates")
require(project not in json.dumps([reuse, context], sort_keys=True), "matcher artifacts leaked temp project path")
require("shell" in context.get("primaryLanguages", []), "implementation context lost shell primary language")

top = candidates[:8]
json_helpers = [
    candidate
    for candidate in top
    if candidate.get("path") == "lib/json-output.sh"
    and candidate.get("kind") in {"existing-helper", "shared-module", "module-boundary"}
]
require(json_helpers, "JSON shell helper is not in top candidates")
for candidate in json_helpers[:2]:
    why = " ".join(candidate.get("whyRelevant", [])).lower()
    require("json" in why, "JSON helper candidate lacks JSON whyRelevant evidence")
    require("imported" in why or "sourced" in why, "JSON helper candidate lacks fan-in whyRelevant evidence")
    require("paired test" in why or "multiple reuse signals" in why, "JSON helper candidate lacks paired-test/multi-signal evidence")

weak_paths = {"lib/utils.sh", "commands/signum.fragments/90-phase-audit.md", "scripts/run-policy-check.sh", "scripts/policy-entry", "scripts/zsh-entry"}
require(not any(candidate.get("path") in weak_paths and candidate.get("kind") in {"existing-helper", "shared-module"} for candidate in candidates), "weak/orchestrator/executable path surfaced as reusable shell helper")
test_candidates = [candidate for candidate in candidates if candidate.get("path") == "tests/test-policy-check.sh"]
for candidate in test_candidates:
    risks = " ".join(candidate.get("risks", [])).lower()
    require("guide tests" in risks or candidate.get("kind") == "test-pattern", "shell test candidate lacks test-boundary risk")

helper = next(
    (
        candidate
        for candidate in candidates
        if candidate.get("path") == "lib/json-output.sh"
        and candidate.get("symbol") == "emit_json_report"
    ),
    None,
)
require(helper is not None, "emit_json_report helper candidate missing")
if helper:
    why = " ".join(helper.get("whyRelevant", [])).lower()
    require("weak" in why and ("imported" in why or "sourced" in why) and "paired test" in why, "weak lib prior is not backed by strong evidence")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "shell matcher candidates use evidence and keep boundaries out of helper rankings"
else
  fail "shell matcher candidates use evidence and keep boundaries out of helper rankings" "Python assertion failed"
fi

echo ""
printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Bash/Shell Codebase Awareness adapter detects lexical shell structure without executing target scripts"
