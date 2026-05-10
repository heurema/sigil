#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
FIXTURE_ROOT="$ROOT_DIR/tests/fixtures/codebase-awareness"
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
  local fixture="$1"
  local project="$WORK/$fixture"
  cp -R "$FIXTURE_ROOT/$fixture" "$project"
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

assert_adapter_parity() {
  local name="$1"
  local language="$2"
  local first_index="$3"
  local cached_index="$4"
  local full_index="$5"
  local cached_style="$6"
  local full_style="$7"

  if python3 - "$language" "$first_index" "$cached_index" "$full_index" "$cached_style" "$full_style" <<'PY'
import copy
import json
import sys
from pathlib import Path

language = sys.argv[1]
first_index = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
cached_index = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
full_index = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
cached_style_bytes = Path(sys.argv[5]).read_bytes()
full_style_bytes = Path(sys.argv[6]).read_bytes()
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def records(index, section):
    value = index.get(section, [])
    return value if isinstance(value, list) else []


def find(index, section, **criteria):
    for item in records(index, section):
        if all(item.get(key) == value for key, value in criteria.items()):
            return item
    return None


def symbol(index, name, kind=None, path=None):
    for item in records(index, "symbols"):
        if item.get("name") != name:
            continue
        if kind is not None and item.get("kind") != kind:
            continue
        if path is not None and item.get("path") != path:
            continue
        return item
    return None


def has_boundary(index, path, kind):
    return any(
        item.get("path") == path and item.get("kind") == kind
        for item in records(index, "moduleBoundaries")
    )


def normalized(index):
    item = copy.deepcopy(index)
    stats = item.get("scanStats")
    if isinstance(stats, dict):
        stats.pop("filesReused", None)
        stats.pop("filesExtracted", None)
    return item


first_stats = first_index.get("scanStats", {})
cached_stats = cached_index.get("scanStats", {})
require(cached_stats.get("filesReused", 0) > 0, "cached run did not reuse files")
require(
    cached_stats.get("filesExtracted", 0) < first_stats.get("filesExtracted", 0),
    "cached run did not reduce filesExtracted",
)
require(cached_style_bytes == full_style_bytes, "cached style profile differs from full style profile")
require(
    normalized(cached_index) == normalized(full_index),
    "cached index differs from full index beyond filesReused/filesExtracted",
)

for section in (
    "manifests",
    "modules",
    "moduleBoundaries",
    "symbols",
    "imports",
    "tests",
    "sharedCandidates",
):
    require(
        cached_index.get(section) == full_index.get(section),
        f"cached/full section differs: {section}",
    )


def assert_go(index):
    go_mod = find(index, "manifests", path="go.mod", kind="go")
    require(
        go_mod is not None and go_mod.get("modulePath") == "example.com/signum-go-basic",
        "Go module path missing",
    )
    auth_import = next(
        (
            item
            for item in records(index, "imports")
            if item.get("path") == "cmd/api/main.go"
            and item.get("imported") == "example.com/signum-go-basic/internal/auth"
        ),
        None,
    )
    require(
        auth_import is not None and auth_import.get("resolvedPath") == "internal/auth",
        "Go local auth import did not resolve",
    )
    validation_imports = [
        item
        for item in records(index, "imports")
        if item.get("imported") == "example.com/signum-go-basic/pkg/validation"
    ]
    require(
        sorted(item.get("resolvedPath") for item in validation_imports) == ["pkg/validation", "pkg/validation"],
        "Go validation imports did not resolve through module path",
    )
    candidate = find(index, "sharedCandidates", path="pkg/validation")
    require(candidate is not None, "Go pkg/validation shared candidate missing")
    if candidate:
        reasons = set(candidate.get("reasons", []))
        require(
            {"imported-by-local-files", "paired-test", "exported-symbols"} <= reasons,
            "Go pkg/validation lacks fan-in, paired-test, or symbol evidence",
        )
        require(candidate.get("usageCount") == 2, "Go pkg/validation fan-in count changed")
        require(
            candidate.get("importedBy") == ["cmd/api/main.go", "internal/users/signup.go"],
            "Go pkg/validation importedBy changed",
        )
        require(
            candidate.get("pairedTests") == ["pkg/validation/email_test.go"],
            "Go pkg/validation paired test evidence changed",
        )


def assert_rust(index):
    validate = symbol(index, "validate_email", "function", "crates/shared/src/validation.rs")
    require(
        validate is not None and validate.get("exported") is True and validate.get("visibility") == "pub",
        "Rust validate_email helper missing or visibility changed",
    )
    inline_test_symbol = symbol(index, "validates_email", "function", "crates/shared/src/validation.rs")
    require(
        inline_test_symbol is None or inline_test_symbol.get("testOnly") is True,
        "Rust inline cfg(test) function surfaced as production symbol",
    )
    test_record = next(
        (
            item
            for item in records(index, "tests")
            if item.get("path") == "crates/shared/src/validation.rs"
        ),
        None,
    )
    require(test_record is not None and test_record.get("inlineCfgTest") is True, "Rust inline cfg(test) evidence missing")
    if test_record:
        require("validates_email" in test_record.get("testFunctions", []), "Rust inline test function missing")
    require(
        has_boundary(index, "crates/shared/src/validation.rs", "rust-inline-cfg-test"),
        "Rust inline cfg(test) boundary missing",
    )
    require(
        has_boundary(index, "crates/shared/src/validation.rs", "rust-crate-local-visibility"),
        "Rust pub(crate) boundary missing",
    )
    normalize = symbol(index, "normalize_email", "function", "crates/shared/src/validation.rs")
    require(
        normalize is not None and normalize.get("visibility") == "pub(crate)" and normalize.get("exported") is False,
        "Rust pub(crate) helper boundary behavior changed",
    )
    candidate = find(index, "sharedCandidates", path="crates/shared/src/validation.rs")
    require(candidate is not None, "Rust shared validation candidate missing")
    if candidate:
        require("validate_email" in candidate.get("symbols", []), "Rust shared candidate lost validate_email")
        require("validates_email" not in candidate.get("symbols", []), "Rust shared candidate includes test-only helper")
        require("crates/shared/src/validation.rs" in candidate.get("pairedTests", []), "Rust paired inline test missing")
        require("normalize_email" in candidate.get("crateLocalSymbols", []), "Rust crate-local evidence missing")
        require(candidate.get("visibilityRisks"), "Rust visibility risk evidence missing")


def assert_csharp(index):
    candidate = find(index, "sharedCandidates", path="src/Common")
    require(candidate is not None, "C# src/Common shared candidate missing")
    if candidate:
        reasons = set(candidate.get("reasons", []))
        require(
            {"project-referenced-by-local-projects", "imported-by-local-files", "exported-symbols", "paired-test"} <= reasons,
            "C# src/Common candidate lacks project reference, fan-in, paired-test, or symbol evidence",
        )
        require("src/App/App.csproj" in candidate.get("projectReferences", []), "C# project reference fan-in missing")
        require("src/App/SignupService.cs" in candidate.get("importedBy", []), "C# app importer missing")
        require("tests/App.Tests/SignupServiceTests.cs" in candidate.get("importedBy", []), "C# test importer missing")
        require("tests/App.Tests/SignupServiceTests.cs" in candidate.get("pairedTests", []), "C# paired test missing")
        require("NormalizeEmail" in candidate.get("internalSymbols", []), "C# internal symbol evidence missing")
        require(candidate.get("visibilityRisks"), "C# internal visibility risk missing")
    common_manifest = find(index, "manifests", path="src/Common/Common.csproj", kind="dotnet-project")
    require(
        common_manifest is not None and "src/App/App.csproj" in common_manifest.get("referencedBy", []),
        "C# projectReference fan-in missing from manifest",
    )
    test_record = next(
        (
            item
            for item in records(index, "tests")
            if item.get("path") == "tests/App.Tests/SignupServiceTests.cs"
        ),
        None,
    )
    require(test_record is not None and test_record.get("framework") == "xunit", "C# xunit test framework missing")
    require(has_boundary(index, "src/Common", "dotnet-internal-api"), "C# internal assembly-local boundary missing")
    validate = symbol(index, "ValidateEmail", "method", "src/Common/EmailValidator.cs")
    require(
        validate is not None and validate.get("visibility") == "public" and validate.get("exported") is True,
        "C# public ValidateEmail helper missing",
    )
    if validate:
        risk_text = " ".join(validate.get("visibilityRisks", [])).lower()
        require("internal" not in risk_text and "assembly-local" not in risk_text, "C# public helper inherited internal risk")


def assert_typescript(index):
    validation_path = "packages/shared/src/validation.ts"
    validate = symbol(index, "validateEmail", "function", validation_path)
    normalize = symbol(index, "normalizeEmail", "function", validation_path)
    local_helper = symbol(index, "parseToken", "function", validation_path)
    require(
        validate is not None and validate.get("exported") is True and validate.get("visibility") == "exported",
        "TypeScript exported validateEmail helper missing",
    )
    require(
        normalize is not None and normalize.get("exported") is True and normalize.get("visibility") == "exported",
        "TypeScript exported normalizeEmail helper missing",
    )
    require(
        local_helper is not None and local_helper.get("exported") is False and local_helper.get("visibility") == "local",
        "TypeScript local helper visibility missing",
    )
    default_symbol = symbol(index, "default", "function", validation_path)
    require(
        default_symbol is not None and default_symbol.get("visibility") == "default-export",
        "TypeScript default export visibility missing",
    )
    api_import = next(
        (
            item
            for item in records(index, "imports")
            if item.get("path") == "packages/api/src/signup.ts"
            and item.get("imported") == "@acme/shared/validation"
            and item.get("kind") == "import"
        ),
        None,
    )
    require(api_import is not None and api_import.get("resolvedPath") == validation_path, "TypeScript package import did not resolve")
    require(
        any(
            item.get("path") == "packages/shared/src/index.ts"
            and item.get("kind") == "export-from"
            and item.get("resolvedPath") == validation_path
            for item in records(index, "imports")
        ),
        "TypeScript export-from did not resolve",
    )
    test_record = next(
        (
            item
            for item in records(index, "tests")
            if item.get("path") == "packages/shared/src/validation.test.ts"
        ),
        None,
    )
    require(test_record is not None and test_record.get("framework") == "vitest", "TypeScript vitest test record missing")
    candidate = find(index, "sharedCandidates", path=validation_path)
    require(candidate is not None, "TypeScript validation shared candidate missing")
    if candidate:
        reasons = set(candidate.get("reasons", []))
        require(
            {"imported-by-local-files", "exported-symbols", "paired-test", "workspace-package", "package-name-import"} <= reasons,
            "TypeScript validation candidate lacks fan-in, symbol, paired-test, or package evidence",
        )
        require(candidate.get("usageCount") == 4, "TypeScript validation fan-in changed")
        require(candidate.get("pairedTests") == ["packages/shared/src/validation.test.ts"], "TypeScript paired test changed")
    require(
        not any(item.get("path") == "packages/shared/src/common-utils.ts" for item in records(index, "sharedCandidates")),
        "TypeScript weak shared/common/utils path became shared candidate",
    )
    require(has_boundary(index, "packages/cli/src/index.ts", "npm-bin-entrypoint"), "TypeScript CLI bin boundary missing")


def assert_python(index):
    validation_path = "src/acme_shared/validation.py"
    validate = symbol(index, "validate_email", "function", validation_path)
    private = symbol(index, "_private_format_email", "function", validation_path)
    require(
        validate is not None and validate.get("exported") is True and validate.get("visibility") == "public",
        "Python public validate_email helper missing",
    )
    require(
        private is not None and private.get("exported") is False and private.get("visibility") == "private",
        "Python private helper visibility missing",
    )
    require(private is not None and private.get("visibilityRisks"), "Python private helper risk missing")
    require(has_boundary(index, validation_path, "python-package"), "Python package boundary missing")
    require(has_boundary(index, "src/acme_cli/__main__.py", "python-cli-entrypoint"), "Python CLI boundary missing")
    api_import = next(
        (
            item
            for item in records(index, "imports")
            if item.get("path") == "src/acme_api/signup.py"
            and item.get("imported") == "acme_shared.validation"
        ),
        None,
    )
    require(api_import is not None and api_import.get("resolvedPath") == validation_path, "Python absolute import did not resolve")
    package_import = next(
        (
            item
            for item in records(index, "imports")
            if item.get("path") == "src/acme_web/signup_form.py"
            and item.get("imported") == "acme_shared"
        ),
        None,
    )
    require(package_import is not None and package_import.get("resolvedPath") == validation_path, "Python from package import module did not resolve")
    test_record = next(
        (
            item
            for item in records(index, "tests")
            if item.get("path") == "tests/test_validation.py"
        ),
        None,
    )
    require(test_record is not None and test_record.get("framework") == "pytest", "Python pytest test record missing")
    require(test_record is not None and test_record.get("fixtures") == ["validator"], "Python pytest fixture missing")
    candidate = find(index, "sharedCandidates", path=validation_path)
    require(candidate is not None, "Python validation shared candidate missing")
    if candidate:
        reasons = set(candidate.get("reasons", []))
        require(
            {"imported-by-local-files", "exported-symbols", "paired-test", "python-package-boundary"} <= reasons,
            "Python validation candidate lacks fan-in, symbol, paired-test, or package evidence",
        )
        require(candidate.get("usageCount", 0) >= 2, "Python validation fan-in changed")
        require("tests/test_validation.py" in candidate.get("pairedTests", []), "Python paired test changed")
        require(candidate.get("visibilityRisks"), "Python private helper risk missing from candidate")
    require(
        not any(item.get("path") == "src/shared/helpers.py" for item in records(index, "sharedCandidates")),
        "Python weak shared/common/utils path became shared candidate",
    )
    require(
        not any(item.get("path") == "src/acme_cli/__main__.py" for item in records(index, "sharedCandidates")),
        "Python CLI entrypoint became shared candidate",
    )


def assert_shell(index):
    validation_path = "lib/json-output.sh"
    emit = symbol(index, "emit_json_report", "function", validation_path)
    write = symbol(index, "write_json_file", "function", validation_path)
    require(
        emit is not None and emit.get("exported") is True and emit.get("visibility") == "function",
        "Shell emit_json_report helper missing",
    )
    require(
        write is not None and write.get("exported") is True and write.get("visibility") == "function",
        "Shell write_json_file helper missing",
    )
    require(has_boundary(index, validation_path, "shell-json-output"), "Shell JSON output boundary missing")
    require(has_boundary(index, "scripts/run-policy-check.sh", "shell-executable-script"), "Shell executable boundary missing")
    source_import = next(
        (
            item
            for item in records(index, "imports")
            if item.get("path") == "lib/policy-check.sh"
            and item.get("imported") == "$ROOT_DIR/lib/json-output.sh"
        ),
        None,
    )
    require(source_import is not None and source_import.get("resolvedPath") == validation_path, "Shell source import did not resolve")
    test_record = next(
        (
            item
            for item in records(index, "tests")
            if item.get("path") == "tests/test-policy-check.sh"
        ),
        None,
    )
    require(test_record is not None and test_record.get("framework") == "shell-test", "Shell test record missing")
    require(test_record is not None and validation_path in test_record.get("targetPaths", []), "Shell test target path missing")
    candidate = find(index, "sharedCandidates", path=validation_path)
    require(candidate is not None, "Shell JSON helper shared candidate missing")
    if candidate:
        reasons = set(candidate.get("reasons", []))
        require(
            {"sourced-by-local-files", "json-output-pattern", "exported-symbols", "paired-test"} <= reasons,
            "Shell JSON helper candidate lacks source, JSON, symbol, or paired-test evidence",
        )
        require(candidate.get("usageCount", 0) >= 2, "Shell JSON helper fan-in changed")
        require("tests/test-policy-check.sh" in candidate.get("pairedTests", []), "Shell paired test changed")
    require(
        not any(item.get("path") == "lib/utils.sh" for item in records(index, "sharedCandidates")),
        "Shell weak lib/utils path became shared candidate",
    )
    require(
        not any(item.get("path") == "scripts/run-policy-check.sh" for item in records(index, "sharedCandidates")),
        "Shell executable wrapper became shared candidate",
    )


if language == "go":
    assert_go(cached_index)
elif language == "rust":
    assert_rust(cached_index)
elif language == "csharp":
    assert_csharp(cached_index)
elif language == "typescript":
    assert_typescript(cached_index)
elif language == "python":
    assert_python(cached_index)
elif language == "shell":
    assert_shell(cached_index)
else:
    errors.append(f"unknown language: {language}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
  then
    pass "$name"
  else
    fail "$name" "Python assertion failed"
  fi
}

run_case() {
  local fixture="$1"
  local language="$2"
  local project
  project="$(make_project "$fixture")"

  echo "=== $fixture cached extraction parity ==="
  if run_scanner "$project" ".signum/cache/codebase-index-first.json" ".signum/cache/style-profile-first.json" ".signum/cache/file-digests-first.json" ".signum/cache/file-extracts-first.json"; then
    pass "$fixture first full scanner run exits 0"
  else
    fail "$fixture first full scanner run exits 0" "command failed"
  fi

  if run_scanner "$project" ".signum/cache/codebase-index-cached.json" ".signum/cache/style-profile-cached.json" ".signum/cache/file-digests-cached.json" ".signum/cache/file-extracts-cached.json" --previous-extracts ".signum/cache/file-extracts-first.json"; then
    pass "$fixture cached scanner run exits 0"
  else
    fail "$fixture cached scanner run exits 0" "command failed"
  fi

  if run_scanner "$project" ".signum/cache/codebase-index-full.json" ".signum/cache/style-profile-full.json" ".signum/cache/file-digests-full.json" ".signum/cache/file-extracts-full.json"; then
    pass "$fixture comparison full scanner run exits 0"
  else
    fail "$fixture comparison full scanner run exits 0" "command failed"
  fi

  assert_adapter_parity "$fixture cached output matches full output and preserves $language adapter signals" \
    "$language" \
    "$project/.signum/cache/codebase-index-first.json" \
    "$project/.signum/cache/codebase-index-cached.json" \
    "$project/.signum/cache/codebase-index-full.json" \
    "$project/.signum/cache/style-profile-cached.json" \
    "$project/.signum/cache/style-profile-full.json"
  echo ""
}

run_case "go-basic" "go"
run_case "rust-basic" "rust"
run_case "csharp-basic" "csharp"
run_case "typescript-basic" "typescript"
run_case "python-basic" "python"
run_case "shell-basic" "shell"

printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Codebase Awareness extraction cache preserves Go, Rust, C#, TypeScript, Python, and Shell adapter-sensitive assembly"
