#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/csharp-basic"
CONTRACT="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts/csharp-validation-contract.json"
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

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

PROJECT_A="$WORK/run-a/csharp-basic"
PROJECT_B="$WORK/run-b/csharp-basic"
mkdir -p "$(dirname "$PROJECT_A")" "$(dirname "$PROJECT_B")"
cp -R "$FIXTURE" "$PROJECT_A"
cp -R "$FIXTURE" "$PROJECT_B"
mkdir -p "$PROJECT_A/.signum/contracts/csharp" "$PROJECT_B/.signum/contracts/csharp"
cp "$CONTRACT" "$PROJECT_A/.signum/contracts/csharp/contract.json"
cp "$CONTRACT" "$PROJECT_B/.signum/contracts/csharp/contract.json"

run_scanner() {
  local project="$1"
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-v1.json" \
      --style-output ".signum/cache/style-profile-v1.json" \
      --digests-output ".signum/cache/file-digests-v1.json" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

run_matcher() {
  local project="$1"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/csharp/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/csharp/reuse_candidates.json" \
      --implementation-context ".signum/contracts/csharp/implementation_context.json" \
      --max-candidates 12 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

run_second_digest() {
  (
    cd "$PROJECT_A"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-second.json" \
      --style-output ".signum/cache/style-profile-second.json" \
      --digests-output ".signum/cache/file-digests-second.json" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

INDEX_A="$PROJECT_A/.signum/cache/codebase-index-v1.json"
STYLE_A="$PROJECT_A/.signum/cache/style-profile-v1.json"
DIGEST_A="$PROJECT_A/.signum/cache/file-digests-v1.json"
SECOND_DIGEST_A="$PROJECT_A/.signum/cache/file-digests-second.json"
REUSE_A="$PROJECT_A/.signum/contracts/csharp/reuse_candidates.json"
CONTEXT_A="$PROJECT_A/.signum/contracts/csharp/implementation_context.json"
INDEX_B="$PROJECT_B/.signum/cache/codebase-index-v1.json"
STYLE_B="$PROJECT_B/.signum/cache/style-profile-v1.json"
DIGEST_B="$PROJECT_B/.signum/cache/file-digests-v1.json"
REUSE_B="$PROJECT_B/.signum/contracts/csharp/reuse_candidates.json"
CONTEXT_B="$PROJECT_B/.signum/contracts/csharp/implementation_context.json"

echo "=== C# scanner run ==="
if run_scanner "$PROJECT_A"; then
  pass "scanner run A exits 0"
else
  fail "scanner run A exits 0" "command failed"
fi
if run_scanner "$PROJECT_B"; then
  pass "scanner run B exits 0"
else
  fail "scanner run B exits 0" "command failed"
fi
assert_file "csharp codebase index created" "$INDEX_A"
assert_file "csharp style profile created" "$STYLE_A"
assert_file "csharp digest cache created" "$DIGEST_A"

echo ""
echo "=== C# scanner signals ==="
if python3 - "$INDEX_A" "$STYLE_A" "$DIGEST_A" "$WORK" <<'PY'
import json
import sys
from pathlib import Path

index = json.loads(Path(sys.argv[1]).read_text())
style = json.loads(Path(sys.argv[2]).read_text())
digests = json.loads(Path(sys.argv[3]).read_text())
work = sys.argv[4]
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

def symbol(name, kind=None, path="src/Common/EmailValidator.cs"):
    for item in records("symbols"):
        if item.get("name") == name and item.get("path") == path and (kind is None or item.get("kind") == kind):
            return item
    return None

require(any(item.get("language") == "csharp" and item.get("fileCount", 0) >= 3 for item in index.get("languageDetections", [])), "C# language detection missing")
require("csharp" in index.get("primaryLanguages", []), "C# primary language missing")

solution = find("manifests", path="Sample.sln", kind="dotnet-solution")
require(solution is not None, ".sln manifest missing")
if solution:
    projects = solution.get("projects", [])
    require({"name": "App", "path": "src/App/App.csproj"} in projects, "App solution project missing")
    require({"name": "Common", "path": "src/Common/Common.csproj"} in projects, "Common solution project missing")
    require({"name": "App.Tests", "path": "tests/App.Tests/App.Tests.csproj"} in projects, "App.Tests solution project missing")
props = find("manifests", path="Directory.Build.props", kind="dotnet-props")
require(props is not None and "Nullable" in props.get("properties", []), "Directory.Build.props manifest missing")
common_manifest = find("manifests", path="src/Common/Common.csproj", kind="dotnet-project")
app_manifest = find("manifests", path="src/App/App.csproj", kind="dotnet-project")
test_manifest = find("manifests", path="tests/App.Tests/App.Tests.csproj", kind="dotnet-project")
require(common_manifest is not None and common_manifest.get("rootNamespace") == "Sample.Common", "Common root namespace missing")
if common_manifest:
    require(common_manifest.get("assemblyName") == "Common", "Common assembly missing")
    require(common_manifest.get("targetFrameworks") == ["net8.0"], "Common target framework missing")
    require("src/App/App.csproj" in common_manifest.get("referencedBy", []), "Common referencedBy missing")
require(app_manifest is not None and app_manifest.get("projectReferences") == ["src/Common/Common.csproj"], "App project reference missing")
if app_manifest:
    require(app_manifest.get("outputType") == "Exe", "App OutputType missing")
    require("Newtonsoft.Json" in app_manifest.get("packageReferences", []), "App package reference missing")
require(test_manifest is not None and test_manifest.get("isTestProject") is True, "test project not detected")
if test_manifest:
    require("xunit" in test_manifest.get("packageReferences", []), "xunit package missing")
    require("Microsoft.NET.Test.Sdk" in test_manifest.get("packageReferences", []), "test sdk package missing")
    require(any(hint.get("framework") == "xunit" for hint in test_manifest.get("testPackageHints", [])), "xunit hint missing")

require(symbol("Sample.Common", "namespace") is not None, "file-scoped namespace missing")
require(symbol("IEmailValidator", "interface") is not None, "interface symbol missing")
require(symbol("Role", "enum") is not None, "enum symbol missing")
require(symbol("Result", "struct") is not None, "struct symbol missing")
require(symbol("UserDto", "record") is not None, "record symbol missing")
require(symbol("SignupRequest", "record") is not None and symbol("SignupRequest", "record").get("visibility") == "internal", "internal record visibility missing")
klass = symbol("EmailValidator", "class")
require(klass is not None and klass.get("exported") is True and klass.get("static") is True, "public static class extraction failed")
validate = symbol("ValidateEmail", "method")
normalize = symbol("NormalizeEmail", "method")
private = symbol("HasAtSign", "method")
const = symbol("DefaultRole", "constant")
prop = symbol("IsValid", "property")
require(validate is not None and validate.get("exported") is True and validate.get("visibility") == "public" and validate.get("container") == "EmailValidator", "public method extraction failed")
require(normalize is not None and normalize.get("exported") is False and normalize.get("visibility") == "internal", "internal method extraction failed")
require(normalize is not None and normalize.get("visibilityRisks"), "internal method risk missing")
require(private is not None and private.get("visibility") == "private", "private method extraction failed")
require(const is not None and const.get("visibility") == "public", "constant extraction failed")
require(prop is not None and prop.get("kind") == "property", "property extraction failed")
signup_ctor = symbol("SignupService", "constructor", "src/App/SignupService.cs")
create_async = symbol("CreateAsync", "method", "src/App/SignupService.cs")
require(signup_ctor is not None and signup_ctor.get("visibility") == "public", "constructor extraction failed")
require(create_async is not None and create_async.get("container") == "SignupService", "async method extraction failed")

imports = records("imports")
def import_record(path, imported):
    return next((item for item in imports if item.get("path") == path and item.get("imported") == imported), None)

common_import = import_record("src/App/SignupService.cs", "Sample.Common")
require(common_import is not None and common_import.get("global") is True and common_import.get("resolvedPath") == "src/Common", "global C# using did not resolve")
static_import = import_record("src/App/SignupService.cs", "Sample.Common.EmailValidator")
require(static_import is not None and static_import.get("static") is True and static_import.get("resolvedPath") == "src/Common", "static C# using did not resolve")
alias_import = static_import = next((item for item in imports if item.get("path") == "src/App/SignupService.cs" and item.get("alias") == "CommonValidation"), None)
require(alias_import is not None and alias_import.get("imported") == "Sample.Common.EmailValidator" and alias_import.get("resolvedPath") == "src/Common", "alias C# using did not resolve")
system_import = import_record("src/App/SignupService.cs", "System")
require(system_import is not None and system_import.get("resolvedPath") is None, "System should not resolve locally")
test_common_import = import_record("tests/App.Tests/SignupServiceTests.cs", "Sample.Common")
require(test_common_import is not None and test_common_import.get("resolvedPath") == "src/Common", "test import did not resolve transitively")

modules = records("modules")
common_project = find("modules", path="src/Common", kind="project")
app_project = find("modules", path="src/App", kind="project")
tests_project = find("modules", path="tests/App.Tests", kind="project")
require(common_project is not None and common_project.get("projectPath") == "src/Common/Common.csproj", "Common project module missing")
if common_project:
    require("src/App/App.csproj" in common_project.get("projectReferences", []), "Common project fan-in missing")
    require("ValidateEmail" in common_project.get("symbols", []), "Common project exported method missing")
    require("NormalizeEmail" in common_project.get("internalSymbols", []), "Common internal symbol evidence missing")
require(app_project is not None and app_project.get("executableBoundary") is True, "App executable boundary missing")
require(tests_project is not None and tests_project.get("isTestProject") is True, "test project boundary missing")

boundaries = records("moduleBoundaries")
def has_boundary(path, kind):
    return any(item.get("path") == path and item.get("kind") == kind for item in boundaries)
require(has_boundary("Sample.sln", "dotnet-solution"), "solution boundary missing")
require(has_boundary("src/App/App.csproj", "dotnet-project"), "project boundary missing")
require(has_boundary("src/Common/Common.csproj", "dotnet-project-reference"), "project reference edge missing")
require(has_boundary("src/App/App.csproj", "dotnet-executable-project"), "executable project boundary missing")
require(has_boundary("tests/App.Tests/App.Tests.csproj", "dotnet-test-project"), "test project boundary missing")
require(has_boundary("src/Common", "dotnet-internal-api"), "internal API boundary missing")

tests = records("tests")
signup_tests = next((item for item in tests if item.get("path") == "tests/App.Tests/SignupServiceTests.cs"), None)
require(signup_tests is not None and signup_tests.get("framework") == "xunit", "xUnit test record missing")
if signup_tests:
    require(set(signup_tests.get("testFunctions", [])) == {"NormalizesEmailThroughSharedValidator", "UsesExistingEmailValidator"}, "Fact/Theory test functions missing")
    require(signup_tests.get("language") == "csharp", "C# test language missing")

shared = find("sharedCandidates", path="src/Common")
require(shared is not None, "C# shared Common candidate missing")
if shared:
    reasons = set(shared.get("reasons", []))
    require({"project-referenced-by-local-projects", "imported-by-local-files", "exported-symbols", "paired-test"} <= reasons, "C# shared candidate lacks strong evidence")
    require(reasons != {"shared-directory-name"}, "C# shared candidate relies only on weak Common name")
    require(shared.get("usageCount", 0) >= 2, "C# shared candidate import fan-in too low")
    require("src/App/SignupService.cs" in shared.get("importedBy", []), "App importer missing")
    require("tests/App.Tests/SignupServiceTests.cs" in shared.get("importedBy", []), "test importer missing")
    require("tests/App.Tests/SignupServiceTests.cs" in shared.get("pairedTests", []), "paired test missing")
    require("src/App/App.csproj" in shared.get("projectReferences", []), "project reference fan-in missing")
    require("NormalizeEmail" in shared.get("internalSymbols", []), "internal symbol evidence missing")
    require(shared.get("visibilityRisks"), "internal visibility risk missing")
require(find("sharedCandidates", path="tests/App.Tests") is None, "test project should not be shared production candidate")

test_conventions = style.get("testConventions", [])
require(any(item.get("language") == "csharp" and item.get("value") == "*Tests.cs" for item in test_conventions), "C# *Tests.cs convention missing")
require(any(item.get("language") == "csharp" and item.get("value") == "xunit" for item in style.get("csharpConventions", [])), "C# xunit style convention missing")
require(any(item.get("value") == "C# project references" for item in style.get("boundaries", [])), "C# project reference style boundary missing")
require(any(item.get("value") == "internal assembly-local symbols" for item in style.get("csharpConventions", [])), "C# internal style convention missing")

files = digests.get("files", {})
for path in (
    "Sample.sln",
    "Directory.Build.props",
    "src/Common/Common.csproj",
    "src/Common/EmailValidator.cs",
    "src/App/App.csproj",
    "src/App/SignupService.cs",
    "tests/App.Tests/App.Tests.csproj",
    "tests/App.Tests/SignupServiceTests.cs",
):
    require(path in files, f"digest missing {path}")
    require(files.get(path, {}).get("indexed") is True, f"digest did not index {path}")
for key in files:
    require(not key.startswith("/") and work not in key, f"non-portable digest key {key}")
require(work not in json.dumps(index) and work not in json.dumps(style) and work not in json.dumps(digests), "scanner artifacts leaked temp path")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "C# scanner language, manifest, symbol, import, test, boundary, shared, and digest signals are valid"
else
  fail "C# scanner language, manifest, symbol, import, test, boundary, shared, and digest signals are valid" "Python assertion failed"
fi

echo ""
echo "=== C# matcher run ==="
if run_matcher "$PROJECT_A"; then
  pass "matcher run A exits 0"
else
  fail "matcher run A exits 0" "command failed"
fi
if run_matcher "$PROJECT_B"; then
  pass "matcher run B exits 0"
else
  fail "matcher run B exits 0" "command failed"
fi
assert_file "csharp reuse candidates created" "$REUSE_A"
assert_file "csharp implementation context created" "$CONTEXT_A"

if python3 - "$REUSE_A" "$CONTEXT_A" "$MATCHER" <<'PY'
import json
import re
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text())
context = json.loads(Path(sys.argv[2]).read_text())
matcher_source = Path(sys.argv[3]).read_text()
errors = []
candidates = reuse.get("candidates", [])
top = candidates[0] if candidates else {}
if reuse.get("contractId") != "csharp-validation-contract":
    errors.append("csharp contractId")
if "csharp" not in context.get("primaryLanguages", []):
    errors.append("C# primary language missing from implementation context")
if not context.get("dominantConventions", {}).get("csharp"):
    errors.append("C# conventions missing from implementation context")
if not context.get("moduleBoundaries"):
    errors.append("C# module boundaries missing from context")
if top.get("path") not in {"src/Common", "src/Common/EmailValidator.cs"}:
    errors.append("top C# candidate should be Common validation helper or project")
if top.get("kind") not in {"existing-helper", "shared-module"}:
    errors.append("top C# candidate kind")
why = " ".join(top.get("whyRelevant", [])).lower()
for term in ("validation", "shared candidate", "imported", "paired test"):
    if term not in why:
        errors.append(f"missing C# whyRelevant evidence: {term}")
if "domain terms matched validation helper:" not in why:
    errors.append("generic C# validation domain overlap explanation missing")
helper_candidates = [
    candidate for candidate in candidates
    if candidate.get("path") in {"src/Common", "src/Common/EmailValidator.cs"}
    and candidate.get("symbol") in {None, "EmailValidator", "ValidateEmail"}
]
if not helper_candidates:
    errors.append("C# validation helper candidate missing")
validate_helpers = [
    candidate for candidate in candidates
    if candidate.get("path") in {"src/Common", "src/Common/EmailValidator.cs"}
    and candidate.get("symbol") == "ValidateEmail"
]
if not validate_helpers:
    errors.append("public ValidateEmail helper candidate missing")
for candidate in validate_helpers:
    risk_text = " ".join(candidate.get("risks", [])).lower()
    if "internal" in risk_text or "assembly-local" in risk_text:
        errors.append("public ValidateEmail candidate inherited internal/assembly-local risk")
internal_candidates = [
    candidate for candidate in candidates
    if candidate.get("symbol") == "NormalizeEmail"
]
if internal_candidates:
    if not any("internal" in " ".join(candidate.get("risks", [])).lower() for candidate in internal_candidates):
        errors.append("internal C# helper risk missing")
elif not any(candidate.get("path") == "src/Common" and "internal" in " ".join(candidate.get("risks", [])).lower() for candidate in candidates):
    errors.append("internal C# boundary risk missing from shared candidate")
shared_common = [
    candidate for candidate in candidates
    if candidate.get("kind") == "shared-module" and candidate.get("path") == "src/Common"
]
if not shared_common:
    errors.append("shared-module src/Common candidate missing")
elif not any("internal" in " ".join(candidate.get("risks", [])).lower() for candidate in shared_common):
    errors.append("shared-module src/Common lost internal/assembly-local risk")
test_project_candidates = [candidate for candidate in candidates if candidate.get("path") == "tests/App.Tests"]
if any(candidate.get("kind") == "shared-module" for candidate in test_project_candidates):
    errors.append("test project surfaced as shared module")
if re.search(r"""['"]email['"]""", matcher_source):
    errors.append("matcher source contains hard-coded email literal")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "C# matcher surfaces validation helper with boundary-aware evidence"
else
  fail "C# matcher surfaces validation helper with boundary-aware evidence" "Python assertion failed"
fi

echo ""
echo "=== Fixed-time stability ==="
if cmp -s "$INDEX_A" "$INDEX_B"; then
  pass "csharp codebase index is byte-stable with fixed generatedAt"
else
  fail "csharp codebase index is byte-stable with fixed generatedAt" "$(diff -u "$INDEX_A" "$INDEX_B" || true)"
fi

if cmp -s "$STYLE_A" "$STYLE_B"; then
  pass "csharp style profile is byte-stable with fixed generatedAt"
else
  fail "csharp style profile is byte-stable with fixed generatedAt" "$(diff -u "$STYLE_A" "$STYLE_B" || true)"
fi

if run_second_digest; then
  pass "second same-project C# digest run exits 0"
else
  fail "second same-project C# digest run exits 0" "command failed"
fi

if cmp -s "$DIGEST_A" "$SECOND_DIGEST_A"; then
  pass "csharp digest cache is byte-stable with fixed generatedAt"
else
  fail "csharp digest cache is byte-stable with fixed generatedAt" "$(diff -u "$DIGEST_A" "$SECOND_DIGEST_A" || true)"
fi

if cmp -s "$REUSE_A" "$REUSE_B"; then
  pass "csharp reuse candidates are byte-stable with fixed generatedAt"
else
  fail "csharp reuse candidates are byte-stable with fixed generatedAt" "$(diff -u "$REUSE_A" "$REUSE_B" || true)"
fi

if cmp -s "$CONTEXT_A" "$CONTEXT_B"; then
  pass "csharp implementation context is byte-stable with fixed generatedAt"
else
  fail "csharp implementation context is byte-stable with fixed generatedAt" "$(diff -u "$CONTEXT_A" "$CONTEXT_B" || true)"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: codebase awareness C# adapter signals and matcher candidates are deterministic"
