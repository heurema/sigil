#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/python-basic"
CONTRACT="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts/python-validation-contract.json"
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
  mkdir -p "$project/.signum/contracts/python"
  cp "$CONTRACT" "$project/.signum/contracts/python/contract.json"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/python/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/python/reuse_candidates.json" \
      --implementation-context ".signum/contracts/python/implementation_context.json" \
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
REUSE_A="$PROJECT_A/.signum/contracts/python/reuse_candidates.json"
CONTEXT_A="$PROJECT_A/.signum/contracts/python/implementation_context.json"

echo "=== Python scanner run ==="
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json"; then
  pass "scanner exits 0 on Python fixture"
else
  fail "scanner exits 0 on Python fixture" "command failed"
fi

if [ -f "$INDEX_A" ] && [ -f "$STYLE_A" ] && [ -f "$DIGEST_A" ] && [ -f "$EXTRACTS_A" ]; then
  pass "scanner writes Python index, style, digest, and extracts artifacts"
else
  fail "scanner writes Python index, style, digest, and extracts artifacts" "missing output"
fi

echo ""
echo "=== Python scanner artifact contract ==="
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


def symbol(name, kind=None, path=None):
    for item in records("symbols"):
        if item.get("name") != name:
            continue
        if kind is not None and item.get("kind") != kind:
            continue
        if path is not None and item.get("path") != path:
            continue
        return item
    return None


def import_record(path, imported, kind=None):
    for item in records("imports"):
        if item.get("path") != path or item.get("imported") != imported:
            continue
        if kind is not None and item.get("kind") != kind:
            continue
        return item
    return None


def boundary(path, kind):
    return any(item.get("path") == path and item.get("kind") == kind for item in records("moduleBoundaries"))


require(any(item.get("language") == "python" and item.get("fileCount", 0) >= 9 for item in records("languageDetections")), "Python language detection missing")
require(index.get("primaryLanguages") == ["python"], "Python primary language missing")

pyproject = find("manifests", path="pyproject.toml", kind="python-project")
require(pyproject is not None, "pyproject manifest missing")
if pyproject:
    require(pyproject.get("projectName") == "signum-python-basic", "pyproject projectName missing")
    require(pyproject.get("dependencies") == ["pydantic"], "pyproject dependencies missing")
    require({"pytest", "hypothesis", "ruff", "mypy"} <= set(pyproject.get("devDependencies", [])), "pyproject dev dependencies missing")
    require(pyproject.get("buildBackendHints") == ["hatch"], "pyproject build backend hint missing")
    require(pyproject.get("entrypoints") == {"acme-signup": "acme_cli.__main__:main"}, "pyproject CLI entrypoint missing")
    frameworks = {(item.get("package"), item.get("framework")) for item in pyproject.get("testFrameworkHints", [])}
    require(("pytest", "pytest") in frameworks and ("hypothesis", "hypothesis") in frameworks, "pyproject test hints missing")
    tools = {(item.get("package"), item.get("tool")) for item in pyproject.get("toolHints", [])}
    require(("ruff", "ruff") in tools and ("mypy", "mypy") in tools, "pyproject tool hints missing")

requirements = find("manifests", path="requirements.txt", kind="python-requirements")
dev_requirements = find("manifests", path="requirements/dev.txt", kind="python-requirements")
require(requirements is not None and requirements.get("dependencies") == ["click", "fastapi"], "requirements dependencies missing")
require(dev_requirements is not None and dev_requirements.get("devDependencies") == ["coverage"], "requirements/dev dependencies missing")

validation_path = "src/acme_shared/validation.py"
module = find("modules", path=validation_path)
package = find("modules", path="src/acme_shared", kind="package")
require(module is not None and module.get("moduleName") == "acme_shared.validation", "Python module name missing")
require(module is not None and module.get("packageName") == "acme_shared", "Python package name missing")
require(package is not None and package.get("packageName") == "acme_shared", "Python package module missing")
require(boundary(validation_path, "python-package"), "Python package boundary missing")
require(boundary("pyproject.toml", "python-project"), "Python project boundary missing")
require(boundary("src/acme_cli/__main__.py", "python-cli-entrypoint"), "Python CLI boundary missing")
require(boundary("src/shared/helpers.py", "shared-name-weak"), "weak shared-name boundary missing")

expected_symbols = (
    ("validate_email", "function", True, "public"),
    ("normalize_email", "function", True, "public"),
    ("fetch_user", "function", True, "public"),
    ("EmailValidator", "class", True, "public"),
    ("SignupPayload", "class", True, "public"),
    ("validate", "method", True, "public"),
    ("normalize", "method", True, "public"),
    ("EMAIL_SUFFIX", "constant", True, "public"),
    ("DEFAULT_TIMEOUT", "constant", True, "public"),
    ("_private_format_email", "function", False, "private"),
    ("_format_for_log", "method", False, "private"),
)
for name, kind, exported, visibility in expected_symbols:
    item = symbol(name, kind, validation_path)
    require(item is not None, f"missing symbol {name}")
    if item:
        require(item.get("exported") is exported, f"{name} exported mismatch")
        require(item.get("visibility") == visibility, f"{name} visibility mismatch")
private_helper = symbol("_private_format_email", "function", validation_path)
require(private_helper is not None and private_helper.get("visibilityRisks"), "private helper visibility risk missing")
signup_payload = symbol("SignupPayload", "class", validation_path)
require(signup_payload is not None and signup_payload.get("pydanticModel") is True, "pydantic model hint missing")
email_validator = symbol("EmailValidator", "class", validation_path)
require(email_validator is not None and email_validator.get("dataclass") is True, "dataclass hint missing")

api_import = import_record("src/acme_api/signup.py", "acme_shared.validation", "from-import")
require(api_import is not None and api_import.get("resolvedPath") == validation_path, "absolute from-import did not resolve")
if api_import:
    require(set(api_import.get("symbols", [])) == {"normalize_email", "validate_email"}, "from-import symbols missing")
relative_import = import_record("src/acme_shared/__init__.py", ".validation", "from-import")
require(relative_import is not None and relative_import.get("resolvedPath") == validation_path, "relative import did not resolve")
package_import = import_record("src/acme_web/signup_form.py", "acme_shared", "from-import")
require(package_import is not None and package_import.get("resolvedPath") == validation_path, "from package import module did not resolve")
alias_import = import_record("src/acme_web/signup_form.py", "acme_shared.validation", "from-import")
require(alias_import is not None and alias_import.get("alias") == "is_valid_email", "from-import alias missing")

test_record = next((item for item in records("tests") if item.get("path") == "tests/test_validation.py"), None)
require(test_record is not None, "pytest test record missing")
if test_record:
    require(test_record.get("framework") == "pytest", "pytest framework missing")
    require("test_validate_email" in test_record.get("testFunctions", []), "pytest test function missing")
    require(test_record.get("fixtures") == ["validator"], "pytest fixture missing")
style_tests = json.dumps(style.get("testConventions", []))
require("pytest" in style_tests and "test_*.py" in style_tests and "validator" in style_tests, "Python test style conventions missing")
require(style.get("pythonConventions"), "pythonConventions style section missing")

candidate = next((item for item in records("sharedCandidates") if item.get("path") == validation_path), None)
require(candidate is not None, "Python validation shared candidate missing")
if candidate:
    reasons = set(candidate.get("reasons", []))
    require({"imported-by-local-files", "exported-symbols", "paired-test", "python-package-boundary"} <= reasons, "validation candidate lacks strong evidence")
    require(candidate.get("usageCount", 0) >= 2, "validation candidate import fan-in missing")
    require({"src/acme_api/signup.py", "src/acme_web/signup_form.py"} <= set(candidate.get("importedBy", [])), "validation importedBy evidence missing")
    require("tests/test_validation.py" in candidate.get("pairedTests", []), "validation paired test missing")
    require("validate_email" in candidate.get("symbols", []), "validation helper symbol missing")
    require(candidate.get("visibilityRisks"), "private helper risk missing from shared candidate")
require(not any(item.get("path") == "src/shared/helpers.py" for item in records("sharedCandidates")), "shared/common/utils path became candidate from weak name only")
require(not any(item.get("path") == "src/acme_cli/__main__.py" for item in records("sharedCandidates")), "CLI entrypoint became shared candidate")

for cache, label in ((digests, "digests"), (extracts, "extracts")):
    files = cache.get("files", {})
    require(validation_path in files and "src/acme_api/signup.py" in files, f"{label} missing Python files")
extract_payload = extracts.get("files", {}).get(validation_path, {})
require(any(item.get("name") == "validate_email" for item in extract_payload.get("symbols", [])), "extract cache missing Python symbols")
require(any(item.get("imported") == "pydantic" for item in extract_payload.get("imports", [])), "extract cache missing Python imports")

serialized = json.dumps([index, style, digests, extracts], sort_keys=True)
require(project not in serialized, "scanner artifacts leaked temp project path")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Python scanner detections, manifests, symbols, imports, tests, boundaries, candidates, and caches are valid"
else
  fail "Python scanner detections, manifests, symbols, imports, tests, boundaries, candidates, and caches are valid" "Python assertion failed"
fi

echo ""
echo "=== Cached/full parity ==="
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-cached.json" ".signum/cache/style-profile-cached.json" ".signum/cache/file-digests-cached.json" ".signum/cache/file-extracts-cached.json" --previous-extracts ".signum/cache/file-extracts-v1.json"; then
  pass "cached scanner exits 0 on Python fixture"
else
  fail "cached scanner exits 0 on Python fixture" "command failed"
fi

if run_scanner "$PROJECT_B" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json"; then
  pass "second full scanner exits 0 on Python fixture"
else
  fail "second full scanner exits 0 on Python fixture" "command failed"
fi

if python3 - "$INDEX_A" "$CACHED_INDEX" "$INDEX_B" "$STYLE_A" "$CACHED_STYLE" "$STYLE_B" "$EXTRACTS_A" "$EXTRACTS_B" <<'PY'
import copy
import json
import sys
from pathlib import Path

first_index = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
cached_index = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
full_index = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
style_a = Path(sys.argv[4]).read_bytes()
style_cached = Path(sys.argv[5]).read_bytes()
style_b = Path(sys.argv[6]).read_bytes()
extracts_a = Path(sys.argv[7]).read_bytes()
extracts_b = Path(sys.argv[8]).read_bytes()
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def without_reuse_counts(value):
    cloned = copy.deepcopy(value)
    stats = cloned.get("scanStats", {})
    if isinstance(stats, dict):
        stats.pop("filesReused", None)
        stats.pop("filesExtracted", None)
    return cloned


require(cached_index.get("scanStats", {}).get("filesReused", 0) > 0, "cached run did not reuse Python extractions")
require(
    cached_index.get("scanStats", {}).get("filesExtracted", 0) < first_index.get("scanStats", {}).get("filesExtracted", 0),
    "cached run did not reduce extracted file count",
)
require(without_reuse_counts(cached_index) == without_reuse_counts(full_index), "cached/full Python index parity failed")
require(style_a == style_cached == style_b, "Python style profile is not stable across cached/full runs")
require(extracts_a == extracts_b, "Python extract cache is not stable with fixed generatedAt")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Python cached/full parity and fixed-time determinism hold"
else
  fail "Python cached/full parity and fixed-time determinism hold" "Python assertion failed"
fi

echo ""
echo "=== Python matcher behavior ==="
if run_matcher "$PROJECT_A"; then
  pass "matcher exits 0 on Python validation contract"
else
  fail "matcher exits 0 on Python validation contract" "command failed"
fi

if python3 - "$REUSE_A" "$CONTEXT_A" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
context = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


candidates = reuse.get("candidates", [])
top_window = candidates[:8]
helper = next(
    (
        item for item in candidates
        if item.get("path") == "src/acme_shared/validation.py" and item.get("symbol") == "validate_email"
    ),
    None,
)
require(reuse.get("contractId") == "python-validation-contract", "Python contractId missing")
require(helper is not None, "Python validate_email helper candidate missing")
require(any(item.get("path") == "src/acme_shared/validation.py" for item in top_window), "Python validation module is not top-ranked")
if helper:
    why = " ".join(helper.get("whyRelevant", [])).lower()
    for term in ("validation", "shared candidate", "imported", "paired test", "exported"):
        require(term in why, f"missing Python whyRelevant evidence: {term}")
    require("domain terms matched validation helper: email" in why, "Python validation domain overlap missing")
    require("shared/common directory hint" not in why or any(term in why for term in ("imported", "paired test", "exported")), "helper relies on weak shared/common prior only")
private = next((item for item in candidates if item.get("symbol") == "_private_format_email"), None)
if private:
    require(any("private" in risk.lower() for risk in private.get("risks", [])), "private helper candidate lacks risk")
require(not any(item.get("path") == "src/shared/helpers.py" for item in candidates), "weak shared/common/utils path surfaced as matcher candidate")
require(
    not any(item.get("path") == "src/acme_cli/__main__.py" and item.get("kind") in {"existing-helper", "shared-module"} for item in candidates),
    "Python CLI entrypoint surfaced as reusable helper",
)
require("python" in context.get("primaryLanguages", []), "Python primary language missing from matcher context")
require(context.get("dominantConventions", {}).get("python"), "Python conventions missing from matcher context")
require(context.get("dominantConventions", {}).get("tests"), "Python test conventions missing from matcher context")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Python matcher surfaces validation evidence and boundary risks"
else
  fail "Python matcher surfaces validation evidence and boundary risks" "Python assertion failed"
fi

echo ""
printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Python Codebase Awareness adapter support is deterministic and evidence-based"
