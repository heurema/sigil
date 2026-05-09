#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/go-basic"
CONTRACT="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts/go-validation-contract.json"
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
  shift
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-v1.json" \
      --style-output ".signum/cache/style-profile-v1.json" \
      --digests-output ".signum/cache/file-digests-v1.json" \
      --generated-at "2026-01-01T00:00:00Z" \
      "$@"
  )
}

run_matcher() {
  local project="$1"
  mkdir -p "$project/.signum/contracts/go-validation"
  cp "$CONTRACT" "$project/.signum/contracts/go-validation/contract.json"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/go-validation/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/go-validation/reuse_candidates.json" \
      --implementation-context ".signum/contracts/go-validation/implementation_context.json" \
      --max-candidates 8 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

PROJECT_A="$(make_project run-a)"

INDEX_A="$PROJECT_A/.signum/cache/codebase-index-v1.json"
STYLE_A="$PROJECT_A/.signum/cache/style-profile-v1.json"
DIGEST_A="$PROJECT_A/.signum/cache/file-digests-v1.json"
REUSE_A="$PROJECT_A/.signum/contracts/go-validation/reuse_candidates.json"
CONTEXT_A="$PROJECT_A/.signum/contracts/go-validation/implementation_context.json"

echo "=== Go scanner run ==="
if run_scanner "$PROJECT_A"; then
  pass "scanner exits 0 on Go fixture"
else
  fail "scanner exits 0 on Go fixture" "command failed"
fi

if [ -f "$INDEX_A" ] && [ -f "$STYLE_A" ] && [ -f "$DIGEST_A" ]; then
  pass "scanner writes Go index, style, and digest artifacts"
else
  fail "scanner writes Go index, style, and digest artifacts" "missing output"
fi

echo ""
echo "=== Go scanner artifact contract ==="
if python3 - "$INDEX_A" "$STYLE_A" "$DIGEST_A" "$PROJECT_A" <<'PY'
import json
import sys
from pathlib import Path

index = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
style = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
digests = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
project = sys.argv[4]
errors = []

def has_record(section, **expected):
    for item in index.get(section, []):
        if all(item.get(key) == value for key, value in expected.items()):
            return item
    return None

def symbol(name, kind=None, path=None):
    for item in index.get("symbols", []):
        if item.get("name") != name:
            continue
        if kind and item.get("kind") != kind:
            continue
        if path and item.get("path") != path:
            continue
        return item
    return None

if not any(item.get("language") == "go" and item.get("fileCount") >= 6 for item in index.get("languageDetections", [])):
    errors.append("Go language detection missing")

go_mod = has_record("manifests", path="go.mod", kind="go", language="go")
if not go_mod or go_mod.get("modulePath") != "example.com/signum-go-basic":
    errors.append("go.mod modulePath missing")
if go_mod and not {"signum", "basic"}.issubset(set(go_mod.get("tokens", []))):
    errors.append("go.mod module tokens missing")

go_work = has_record("manifests", path="go.work", kind="go-work", language="go")
if not go_work or go_work.get("workspaceUses") != ["./libs/shared", "./services/api"]:
    errors.append("go.work workspaceUses missing")

validate = symbol("ValidateToken", "function", "internal/auth/token.go")
parse = symbol("parseToken", "function", "internal/auth/token.go")
method = symbol("ValidateToken", "method", "internal/auth/token.go")
save = symbol("Save", "method", "internal/auth/token.go")
if not validate or validate.get("exported") is not True or validate.get("receiver") is not None:
    errors.append("ValidateToken function extraction/export failed")
if not parse or parse.get("exported") is not False:
    errors.append("parseToken unexported extraction failed")
if not method or method.get("receiver") != "Service" or method.get("exported") is not True:
    errors.append("Service method receiver extraction failed")
if not save or save.get("receiver") != "Repository":
    errors.append("Repository value receiver extraction failed")
for name in ("User", "Store", "Role", "DefaultTimeout", "ErrInvalidToken"):
    if not symbol(name, path="internal/auth/token.go"):
        errors.append(f"missing Go symbol {name}")

imports = index.get("imports", [])
def import_record(path, imported):
    return next((item for item in imports if item.get("path") == path and item.get("imported") == imported), None)

if not import_record("cmd/api/main.go", "context"):
    errors.append("single/block stdlib import missing")
auth_import = import_record("cmd/api/main.go", "example.com/signum-go-basic/internal/auth")
if not auth_import or auth_import.get("alias") != "auth" or auth_import.get("resolvedPath") != "internal/auth":
    errors.append("aliased local auth import did not resolve")
cfg_import = import_record("internal/users/signup.go", "example.com/signum-go-basic/internal/auth")
if not cfg_import or cfg_import.get("alias") != "cfg" or cfg_import.get("resolvedPath") != "internal/auth":
    errors.append("cfg local auth import did not resolve")
validation_imports = [
    item for item in imports
    if item.get("imported") == "example.com/signum-go-basic/pkg/validation"
]
if sorted(item.get("resolvedPath") for item in validation_imports) != ["pkg/validation", "pkg/validation"]:
    errors.append("local validation imports did not resolve to package directory")
blank_import = import_record("cmd/api/main.go", "net/http/pprof")
if not blank_import or blank_import.get("alias") != "_" or blank_import.get("resolvedPath") is not None:
    errors.append("blank stdlib import extraction failed")
github_import = import_record("cmd/api/main.go", "github.com/acme/external/driver")
if not github_import or github_import.get("resolvedPath") is not None:
    errors.append("external github import should not resolve locally")

tests = index.get("tests", [])
auth_test = next((item for item in tests if item.get("path") == "internal/auth/token_test.go"), None)
if not auth_test or auth_test.get("framework") != "go-test" or auth_test.get("targetPackage") != "auth":
    errors.append("Go auth test record missing framework/targetPackage")
if auth_test and set(auth_test.get("testFunctions", [])) != {"TestValidateToken", "BenchmarkValidateToken", "FuzzValidateToken"}:
    errors.append("Go test functions not detected")
if not next((item for item in tests if item.get("path") == "pkg/validation/email_test.go" and item.get("framework") == "go-test"), None):
    errors.append("Go validation test record missing")

modules = index.get("modules", [])
pkg_module = next((item for item in modules if item.get("path") == "pkg/validation" and item.get("kind") == "package"), None)
internal_module = next((item for item in modules if item.get("path") == "internal/auth" and item.get("kind") == "package"), None)
cmd_module = next((item for item in modules if item.get("path") == "cmd/api" and item.get("kind") == "package"), None)
if not pkg_module or pkg_module.get("weakReusablePackageConvention") is not True:
    errors.append("pkg/ weak package boundary missing")
if not internal_module or internal_module.get("internalBoundary") is not True:
    errors.append("internal/ boundary missing")
if not cmd_module or cmd_module.get("entrypointBoundary") is not True:
    errors.append("cmd/ boundary missing")

boundaries = index.get("moduleBoundaries", [])
if not any(item.get("path") == "internal/auth" and item.get("kind") == "go-internal" for item in boundaries):
    errors.append("go-internal module boundary missing")
if not any(item.get("path") == "cmd/api" and item.get("kind") == "go-cmd" for item in boundaries):
    errors.append("go-cmd module boundary missing")
if not any(item.get("path") == "pkg/validation" and item.get("kind") == "go-pkg" and item.get("weak") is True for item in boundaries):
    errors.append("go-pkg weak module boundary missing")
if "pkg/validation/testdata/valid.txt" not in index.get("conventions", {}).get("goTestdataPaths", []):
    errors.append("testdata convention missing")

shared = index.get("sharedCandidates", [])
validation_candidate = next((item for item in shared if item.get("path") == "pkg/validation"), None)
if not validation_candidate:
    errors.append("pkg/validation shared candidate missing")
else:
    reasons = set(validation_candidate.get("reasons", []))
    if not {"imported-by-local-files", "paired-test", "exported-symbols"}.issubset(reasons):
        errors.append("pkg/validation shared candidate lacks strong evidence")
    if validation_candidate.get("usageCount") != 2:
        errors.append("pkg/validation usageCount should be 2")
    if validation_candidate.get("importedBy") != ["cmd/api/main.go", "internal/users/signup.go"]:
        errors.append("pkg/validation importedBy mismatch")
    if validation_candidate.get("pairedTests") != ["pkg/validation/email_test.go"]:
        errors.append("pkg/validation pairedTests mismatch")
internal_candidate = next((item for item in shared if item.get("path") == "internal/auth"), None)
if not internal_candidate or internal_candidate.get("internalBoundary") is not True:
    errors.append("internal/auth candidate is not boundary-aware")

style_tests = style.get("testConventions", [])
if not any(item.get("language") == "go" and item.get("value") == "*_test.go" for item in style_tests):
    errors.append("Go *_test.go style convention missing")
style_go = style.get("goConventions", [])
if not any(item.get("value") == "go test" for item in style_go):
    errors.append("Go go test style convention missing")
if not any(item.get("value") == "package-local tests" for item in style_go):
    errors.append("Go package-local test convention missing")

digest_files = digests.get("files", {})
for rel in ("go.mod", "cmd/api/main.go", "internal/auth/token.go", "internal/auth/token_test.go", "pkg/validation/email.go"):
    record = digest_files.get(rel)
    if not record or record.get("indexed") is not True:
        errors.append(f"missing indexed digest for {rel}")
for key in digest_files:
    if key.startswith("/") or project in key:
        errors.append(f"non-portable digest key {key}")

if project in json.dumps(index) or project in json.dumps(style) or project in json.dumps(digests):
    errors.append("temp project path leaked")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Go scanner emits expected language, manifest, symbol, import, test, boundary, shared, and digest signals"
else
  fail "Go scanner emits expected language, manifest, symbol, import, test, boundary, shared, and digest signals" "Python assertion failed"
fi

echo ""
echo "=== Go matcher behavior ==="
if run_matcher "$PROJECT_A"; then
  pass "matcher exits 0 for Go contract"
else
  fail "matcher exits 0 for Go contract" "command failed"
fi

if python3 - "$REUSE_A" "$CONTEXT_A" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
context = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
errors = []
candidates = reuse.get("candidates", [])
top = candidates[0] if candidates else {}
if reuse.get("contractId") != "go-validation-contract":
    errors.append("Go contractId mismatch")
if top.get("path") != "pkg/validation" or top.get("kind") not in {"existing-helper", "shared-module"}:
    errors.append("top Go candidate should surface pkg/validation helper/module")
if top.get("symbol") not in {None, "ValidateEmail"}:
    errors.append("top Go candidate symbol mismatch")
why = " ".join(top.get("whyRelevant", [])).lower()
for term in ("validation", "shared candidate", "imported", "paired test"):
    if term not in why:
        errors.append(f"top Go candidate missing whyRelevant evidence: {term}")
if "pkg/" in why and not any(term in why for term in ("imported", "paired test", "symbol")):
    errors.append("Go candidate relies only on pkg path")
if not any(candidate.get("path") == "internal/auth" and candidate.get("risks") for candidate in candidates):
    errors.append("internal/auth candidate should carry boundary risk")
if "go" not in context.get("primaryLanguages", []):
    errors.append("implementation context missing Go primary language")
if not context.get("dominantConventions", {}).get("go"):
    errors.append("implementation context missing Go conventions")
if not context.get("moduleBoundaries"):
    errors.append("implementation context missing module boundaries")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Go matcher surfaces validation helper with evidence-based relevance"
else
  fail "Go matcher surfaces validation helper with evidence-based relevance" "Python assertion failed"
fi

echo ""
echo "=== Skip behavior ==="
PROJECT_C="$(make_project skip)"
mkdir -p "$PROJECT_C/vendor/example.com/generated" "$PROJECT_C/pkg/generated"
printf 'package generated\n\nfunc IgnoredVendor() {}\n' > "$PROJECT_C/vendor/example.com/generated/vendor.go"
printf '// Code generated by fixture. DO NOT EDIT.\npackage generated\n\nfunc IgnoredGenerated() {}\n' > "$PROJECT_C/pkg/generated/generated.go"
printf 'go\000binary\n' > "$PROJECT_C/pkg/generated/binary.bin"
if run_scanner "$PROJECT_C"; then
  pass "scanner exits 0 with Go skip fixtures"
else
  fail "scanner exits 0 with Go skip fixtures" "command failed"
fi
if python3 - "$PROJECT_C/.signum/cache/file-digests-v1.json" <<'PY'
import json
import sys
from pathlib import Path

digests = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
files = digests.get("files", {})
errors = []
if any(path.startswith("vendor/") for path in files):
    errors.append("vendor path should be ignored")
generated = files.get("pkg/generated/generated.go")
if not generated or generated.get("indexed") is not False or generated.get("reason") != "generated":
    errors.append("generated Go file should be skipped")
binary = files.get("pkg/generated/binary.bin")
if not binary or binary.get("indexed") is not False or binary.get("reason") != "binary":
    errors.append("binary file should be skipped")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "generated, vendor, and binary skip behavior remains intact"
else
  fail "generated, vendor, and binary skip behavior remains intact" "Python assertion failed"
fi

echo ""
echo "=== Determinism ==="
SNAPSHOT_INDEX="$WORK/codebase-index-a.json"
SNAPSHOT_STYLE="$WORK/style-profile-a.json"
SNAPSHOT_DIGEST="$WORK/file-digests-a.json"
cp "$INDEX_A" "$SNAPSHOT_INDEX"
cp "$STYLE_A" "$SNAPSHOT_STYLE"
cp "$DIGEST_A" "$SNAPSHOT_DIGEST"
if run_scanner "$PROJECT_A"; then
  pass "second Go scanner run exits 0 on same project"
else
  fail "second Go scanner run exits 0 on same project" "command failed"
fi
if cmp -s "$INDEX_A" "$SNAPSHOT_INDEX" && cmp -s "$STYLE_A" "$SNAPSHOT_STYLE" && cmp -s "$DIGEST_A" "$SNAPSHOT_DIGEST"; then
  pass "Go scanner artifacts are byte-stable with fixed generatedAt"
else
  fail "Go scanner artifacts are byte-stable with fixed generatedAt" "scanner outputs changed"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Go Codebase Awareness adapter is deterministic and evidence-based"
