#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/typescript-basic"
CONTRACT="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts/typescript-validation-contract.json"
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
  mkdir -p "$project/.signum/contracts/typescript"
  cp "$CONTRACT" "$project/.signum/contracts/typescript/contract.json"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/typescript/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/typescript/reuse_candidates.json" \
      --implementation-context ".signum/contracts/typescript/implementation_context.json" \
      --max-candidates 8 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

PROJECT_A="$(make_project run-a)"
PROJECT_B="$(make_project run-b)"

INDEX_A="$PROJECT_A/.signum/cache/codebase-index-v1.json"
STYLE_A="$PROJECT_A/.signum/cache/style-profile-v1.json"
DIGEST_A="$PROJECT_A/.signum/cache/file-digests-v1.json"
EXTRACTS_A="$PROJECT_A/.signum/cache/file-extracts-v1.json"
REUSE_A="$PROJECT_A/.signum/contracts/typescript/reuse_candidates.json"
CONTEXT_A="$PROJECT_A/.signum/contracts/typescript/implementation_context.json"

echo "=== TypeScript/JavaScript scanner run ==="
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json"; then
  pass "scanner exits 0 on TypeScript fixture"
else
  fail "scanner exits 0 on TypeScript fixture" "command failed"
fi

if [ -f "$INDEX_A" ] && [ -f "$STYLE_A" ] && [ -f "$DIGEST_A" ] && [ -f "$EXTRACTS_A" ]; then
  pass "scanner writes TypeScript index, style, digest, and extracts artifacts"
else
  fail "scanner writes TypeScript index, style, digest, and extracts artifacts" "missing output"
fi

echo ""
echo "=== TypeScript/JavaScript scanner artifact contract ==="
if python3 - "$INDEX_A" "$STYLE_A" "$DIGEST_A" "$EXTRACTS_A" "$PROJECT_A" <<'PY'
import copy
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


require(
    any(item.get("language") == "typescript" and item.get("fileCount", 0) >= 7 for item in records("languageDetections")),
    "TypeScript language detection missing",
)

root_pkg = find("manifests", path="package.json", kind="npm-package")
require(root_pkg is not None, "root package.json manifest missing")
if root_pkg:
    require(root_pkg.get("packageName") == "@acme/root", "root packageName missing")
    require(root_pkg.get("workspaces") == ["packages/*"], "root workspaces missing")
    require({"typescript", "vitest"} <= set(root_pkg.get("devDependencies", [])), "root dev dependencies missing")
    require(root_pkg.get("testFrameworkHints") == [{"framework": "vitest", "package": "vitest"}], "root vitest hint missing")

shared_pkg = find("manifests", path="packages/shared/package.json", kind="npm-package")
api_pkg = find("manifests", path="packages/api/package.json", kind="npm-package")
web_pkg = find("manifests", path="packages/web/package.json", kind="npm-package")
cli_pkg = find("manifests", path="packages/cli/package.json", kind="npm-package")
require(shared_pkg is not None and shared_pkg.get("packageName") == "@acme/shared", "shared package missing")
if shared_pkg:
    require(shared_pkg.get("packageType") == "module", "shared package type missing")
    require(shared_pkg.get("main") == "dist/index.js", "shared main missing")
    require(set(shared_pkg.get("exports", [])) == {".", "./validation"}, "shared exports missing")
    require({"zod"} <= set(shared_pkg.get("dependencies", [])), "shared dependencies missing")
    require({"acme", "shared", "validation"} <= set(shared_pkg.get("tokens", [])), "shared package tokens missing")
require(api_pkg is not None and api_pkg.get("runtimeHints") == ["node"], "api node runtime hint missing")
require(web_pkg is not None and web_pkg.get("runtimeHints") == ["browser"], "web browser runtime hint missing")
if web_pkg:
    web_hints = {(item.get("package"), item.get("framework")) for item in web_pkg.get("testFrameworkHints", [])}
    require(("@testing-library/react", "testing-library") in web_hints and ("jest", "jest") in web_hints, "web test hints missing")
if cli_pkg:
    require(cli_pkg.get("bin") == {"acme": "src/index.ts"}, "cli bin manifest missing")
    require(cli_pkg.get("runtimeHints") == ["node"], "cli node runtime hint missing")
else:
    errors.append("cli package missing")

for rel, kind in (
    ("package-lock.json", "npm-lock"),
    ("pnpm-lock.yaml", "pnpm-lock"),
    ("pnpm-workspace.yaml", "pnpm-workspace"),
    ("yarn.lock", "yarn-lock"),
):
    require(find("manifests", path=rel, kind=kind) is not None, f"{kind} manifest missing")

root_tsconfig = find("manifests", path="tsconfig.json", kind="tsconfig")
api_tsconfig = find("manifests", path="packages/api/tsconfig.json", kind="tsconfig")
web_jsconfig = find("manifests", path="packages/web/jsconfig.json", kind="jsconfig")
require(root_tsconfig is not None and root_tsconfig.get("baseUrl") == ".", "root tsconfig baseUrl missing")
if root_tsconfig:
    require(root_tsconfig.get("paths") == {"@acme/shared/*": ["packages/shared/src/*"]}, "root tsconfig paths missing")
    require(root_tsconfig.get("references") == [{"path": "packages/shared"}, {"path": "packages/api"}], "root tsconfig references missing")
    require("packages/**/*.ts" in root_tsconfig.get("include", []), "root tsconfig include missing")
    require("node_modules" in root_tsconfig.get("exclude", []), "root tsconfig exclude missing")
require(api_tsconfig is not None and api_tsconfig.get("paths") == {"@acme/shared/*": ["../shared/src/*"]}, "api tsconfig path alias missing")
require(web_jsconfig is not None and web_jsconfig.get("paths") == {"@acme/shared/*": ["../shared/src/*"]}, "web jsconfig path alias missing")

validation_path = "packages/shared/src/validation.ts"
for expected in (
    ("validateEmail", "function", True, "exported"),
    ("normalizeEmail", "function", True, "exported"),
    ("ValidationService", "class", True, "exported"),
    ("EmailValidationResult", "interface", True, "exported"),
    ("UserId", "type", True, "exported"),
    ("Role", "enum", True, "exported"),
    ("parseToken", "function", False, "local"),
    ("formatValidationMessage", "function", False, "local"),
):
    item = symbol(expected[0], expected[1], validation_path)
    require(item is not None, f"missing symbol {expected[0]}")
    if item:
        require(item.get("exported") is expected[2], f"{expected[0]} exported mismatch")
        require(item.get("visibility") == expected[3], f"{expected[0]} visibility mismatch")
default_symbol = symbol("default", "function", validation_path)
require(default_symbol is not None and default_symbol.get("visibility") == "default-export", "default export function missing")

api_import = import_record("packages/api/src/signup.ts", "@acme/shared/validation", "import")
require(api_import is not None and api_import.get("resolvedPath") == validation_path, "api static package import did not resolve")
if api_import:
    require(set(api_import.get("symbols", [])) == {"normalizeEmail", "validateEmail"}, "api static import symbols missing")
    require(api_import.get("alias") == "normalize", "api alias missing")
require(import_record("packages/api/src/signup.ts", "@acme/shared/validation", "require") is not None, "api require import missing")
dynamic = import_record("packages/api/src/signup.ts", "@acme/shared/validation", "dynamic-import")
require(dynamic is not None and dynamic.get("resolvedPath") == validation_path, "api dynamic import did not resolve")
side_effect = import_record("packages/shared/src/index.ts", "./validation", "side-effect-import")
require(side_effect is not None and side_effect.get("resolvedPath") == validation_path, "side-effect relative import did not resolve")
export_from = import_record("packages/shared/src/index.ts", "./validation", "export-from")
require(export_from is not None and export_from.get("resolvedPath") == validation_path, "export-from relative import did not resolve")
index_import = import_record("packages/shared/src/validation.test.ts", ".", "import")
require(index_import is not None and index_import.get("resolvedPath") == "packages/shared/src/index.ts", "relative directory index import did not resolve")
web_import = import_record("packages/web/src/signup-form.tsx", "@acme/shared/validation", "import")
require(web_import is not None and web_import.get("resolvedPath") == validation_path, "web package import did not resolve")

test_record = next((item for item in records("tests") if item.get("path") == "packages/shared/src/validation.test.ts"), None)
require(test_record is not None, "validation test record missing")
if test_record:
    require(test_record.get("framework") == "vitest", "vitest framework missing")
    require("validates email" in test_record.get("testFunctions", []), "test function name missing")

candidate = next((item for item in records("sharedCandidates") if item.get("path") == validation_path), None)
require(candidate is not None, "validation shared candidate missing")
if candidate:
    reasons = set(candidate.get("reasons", []))
    require(
        {"imported-by-local-files", "exported-symbols", "paired-test", "workspace-package", "package-name-import", "tsconfig-path-reference"} <= reasons,
        "validation candidate lacks strong evidence",
    )
    require(candidate.get("usageCount") == 4, "validation usageCount mismatch")
    require(candidate.get("pairedTests") == ["packages/shared/src/validation.test.ts"], "validation paired test missing")
    require(candidate.get("packageName") == "@acme/shared", "validation packageName missing")

require(
    not any(item.get("path") == "packages/shared/src/common-utils.ts" for item in records("sharedCandidates")),
    "common-utils should not be a shared candidate from weak path names only",
)
require(
    not any(item.get("path") == "packages/cli/src/index.ts" for item in records("sharedCandidates")),
    "CLI bin entrypoint should not be a shared helper candidate",
)
require(
    any(item.get("path") == "packages/cli/src/index.ts" and item.get("kind") == "npm-bin-entrypoint" for item in records("moduleBoundaries")),
    "CLI bin boundary missing",
)
require(
    any(item.get("path") == "packages/shared/src/common-utils.ts" and item.get("kind") == "shared-name-weak" and item.get("weak") is True for item in records("moduleBoundaries")),
    "weak shared-name boundary missing",
)

style_tests = style.get("testConventions", [])
require(any(item.get("language") == "typescript" and item.get("value") == "*.test.*" for item in style_tests), "*.test.* convention missing")
require(any(item.get("language") == "typescript" and item.get("value") == "colocated test convention" for item in style_tests), "colocated test convention missing")
tsjs_style = style.get("typescriptJavascriptConventions", [])
require(any(item.get("name") == "test-framework" and item.get("value") == "vitest" for item in tsjs_style), "vitest style hint missing")
require(any(item.get("name") == "boundary" and item.get("value") == "package.json bin entrypoint" for item in tsjs_style), "CLI boundary style hint missing")

for rel in (
    "packages/shared/src/validation.ts",
    "packages/shared/src/validation.test.ts",
    "packages/web/src/signup-form.tsx",
    "packages/cli/src/index.ts",
    "packages/web/jsconfig.json",
):
    digest = digests.get("files", {}).get(rel)
    extract = extracts.get("files", {}).get(rel)
    require(digest is not None and digest.get("indexed") is True, f"missing digest for {rel}")
    require(extract is not None and extract.get("indexed") is True, f"missing extract for {rel}")

require(project not in json.dumps(index), "temp project path leaked in index")
require(project not in json.dumps(style), "temp project path leaked in style")
require(project not in json.dumps(digests), "temp project path leaked in digests")
require(project not in json.dumps(extracts), "temp project path leaked in extracts")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "TypeScript scanner emits expected language, manifest, symbol, import, test, boundary, shared, digest, and extract signals"
else
  fail "TypeScript scanner emits expected language, manifest, symbol, import, test, boundary, shared, digest, and extract signals" "Python assertion failed"
fi

echo ""
echo "=== TypeScript matcher behavior ==="
if run_matcher "$PROJECT_A"; then
  pass "matcher exits 0 for TypeScript contract"
else
  fail "matcher exits 0 for TypeScript contract" "command failed"
fi

if python3 - "$REUSE_A" "$CONTEXT_A" "$WORK" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
context = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
work = sys.argv[3]
errors = []
candidates = reuse.get("candidates", [])
top_paths = [candidate.get("path") for candidate in candidates[:5]]
top_why = " ".join(" ".join(candidate.get("whyRelevant", [])) for candidate in candidates[:5]).lower()

if reuse.get("contractId") != "typescript-validation-contract":
    errors.append("TypeScript contractId mismatch")
if "packages/shared/src/validation.ts" not in top_paths:
    errors.append("validation helper is not a top TypeScript candidate")
helper = next(
    (
        candidate
        for candidate in candidates
        if candidate.get("path") == "packages/shared/src/validation.ts"
        and candidate.get("symbol") == "validateEmail"
    ),
    None,
)
if not helper:
    errors.append("validateEmail helper candidate missing")
else:
    why = " ".join(helper.get("whyRelevant", [])).lower()
    for term in ("validation", "imported", "paired test", "exported", "shared candidate"):
        if term not in why:
            errors.append(f"validateEmail whyRelevant missing {term}")
    if "domain terms matched validation helper: email" not in why:
        errors.append("validateEmail missing generic validation domain evidence")
if "shared/common directory hint" in top_why and "imported" not in top_why:
    errors.append("top candidates appear to rank from shared path only")
if any(candidate.get("path") == "packages/shared/src/common-utils.ts" for candidate in candidates):
    errors.append("common-utils weak path candidate surfaced")
if any(candidate.get("path") == "packages/cli/src/index.ts" and candidate.get("kind") in {"existing-helper", "shared-module"} for candidate in candidates):
    errors.append("CLI bin entrypoint surfaced as helper")
if not any("typescriptJavascript" in context.get("dominantConventions", {}) for _ in [0]):
    errors.append("implementation context missing TypeScript/JavaScript conventions")
if work in json.dumps(reuse) or work in json.dumps(context):
    errors.append("matcher artifacts leaked temp path")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "TypeScript matcher surfaces validation helper with non-path-only evidence and boundary awareness"
else
  fail "TypeScript matcher surfaces validation helper with non-path-only evidence and boundary awareness" "Python assertion failed"
fi

echo ""
echo "=== Cached/full extraction parity ==="
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-reuse.json" ".signum/cache/style-profile-reuse.json" ".signum/cache/file-digests-reuse.json" ".signum/cache/file-extracts-reuse.json" --previous-extracts ".signum/cache/file-extracts-v1.json"; then
  pass "cached TypeScript scanner run exits 0"
else
  fail "cached TypeScript scanner run exits 0" "command failed"
fi
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-full.json" ".signum/cache/style-profile-full.json" ".signum/cache/file-digests-full.json" ".signum/cache/file-extracts-full.json"; then
  pass "full TypeScript comparison run exits 0"
else
  fail "full TypeScript comparison run exits 0" "command failed"
fi
if python3 - "$PROJECT_A/.signum/cache/codebase-index-v1.json" "$PROJECT_A/.signum/cache/codebase-index-reuse.json" "$PROJECT_A/.signum/cache/codebase-index-full.json" "$PROJECT_A/.signum/cache/style-profile-reuse.json" "$PROJECT_A/.signum/cache/style-profile-full.json" <<'PY'
import copy
import json
import sys
from pathlib import Path

first = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
reuse = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
full = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
style_reuse = Path(sys.argv[4]).read_bytes()
style_full = Path(sys.argv[5]).read_bytes()

def normalized(value):
    item = copy.deepcopy(value)
    stats = item.get("scanStats", {})
    if isinstance(stats, dict):
        stats.pop("filesReused", None)
        stats.pop("filesExtracted", None)
    return item

assert reuse["scanStats"]["filesReused"] > 0, "no files reused"
assert reuse["scanStats"]["filesExtracted"] < first["scanStats"]["filesExtracted"], "filesExtracted did not drop"
assert style_reuse == style_full, "cached style differs from full style"
assert normalized(reuse) == normalized(full), "cached index differs from full index beyond reuse counters"
for section in ("manifests", "modules", "moduleBoundaries", "symbols", "imports", "tests", "sharedCandidates"):
    assert reuse.get(section) == full.get(section), f"cached/full section differs: {section}"
PY
then
  pass "cached TypeScript output matches full output"
else
  fail "cached TypeScript output matches full output" "Python assertion failed"
fi

echo ""
echo "=== Fixed-time determinism ==="
run_scanner "$PROJECT_B" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json"
if cmp -s "$INDEX_A" "$PROJECT_B/.signum/cache/codebase-index-v1.json"; then
  pass "TypeScript codebase index is byte-stable with fixed generatedAt"
else
  fail "TypeScript codebase index is byte-stable with fixed generatedAt" "$(diff -u "$INDEX_A" "$PROJECT_B/.signum/cache/codebase-index-v1.json" || true)"
fi
if cmp -s "$STYLE_A" "$PROJECT_B/.signum/cache/style-profile-v1.json"; then
  pass "TypeScript style profile is byte-stable with fixed generatedAt"
else
  fail "TypeScript style profile is byte-stable with fixed generatedAt" "$(diff -u "$STYLE_A" "$PROJECT_B/.signum/cache/style-profile-v1.json" || true)"
fi
if cmp -s "$DIGEST_A" "$PROJECT_A/.signum/cache/file-digests-full.json"; then
  pass "TypeScript digest cache is byte-stable with fixed generatedAt on unchanged files"
else
  fail "TypeScript digest cache is byte-stable with fixed generatedAt on unchanged files" "$(diff -u "$DIGEST_A" "$PROJECT_A/.signum/cache/file-digests-full.json" || true)"
fi
if cmp -s "$EXTRACTS_A" "$PROJECT_B/.signum/cache/file-extracts-v1.json"; then
  pass "TypeScript extracts cache is byte-stable with fixed generatedAt"
else
  fail "TypeScript extracts cache is byte-stable with fixed generatedAt" "$(diff -u "$EXTRACTS_A" "$PROJECT_B/.signum/cache/file-extracts-v1.json" || true)"
fi

echo ""
printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: TypeScript/JavaScript Codebase Awareness adapter emits deterministic shallow lexical scanner and matcher evidence"
