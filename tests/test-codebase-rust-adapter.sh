#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/rust-basic"
CONTRACT="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts/rust-validation-contract.json"
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

PROJECT_A="$WORK/run-a/rust-basic"
PROJECT_B="$WORK/run-b/rust-basic"
mkdir -p "$(dirname "$PROJECT_A")" "$(dirname "$PROJECT_B")"
cp -R "$FIXTURE" "$PROJECT_A"
cp -R "$FIXTURE" "$PROJECT_B"
mkdir -p "$PROJECT_A/.signum/contracts/rust" "$PROJECT_B/.signum/contracts/rust"
cp "$CONTRACT" "$PROJECT_A/.signum/contracts/rust/contract.json"
cp "$CONTRACT" "$PROJECT_B/.signum/contracts/rust/contract.json"

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
      --contract ".signum/contracts/rust/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/rust/reuse_candidates.json" \
      --implementation-context ".signum/contracts/rust/implementation_context.json" \
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
REUSE_A="$PROJECT_A/.signum/contracts/rust/reuse_candidates.json"
CONTEXT_A="$PROJECT_A/.signum/contracts/rust/implementation_context.json"
INDEX_B="$PROJECT_B/.signum/cache/codebase-index-v1.json"
STYLE_B="$PROJECT_B/.signum/cache/style-profile-v1.json"
DIGEST_B="$PROJECT_B/.signum/cache/file-digests-v1.json"
REUSE_B="$PROJECT_B/.signum/contracts/rust/reuse_candidates.json"
CONTEXT_B="$PROJECT_B/.signum/contracts/rust/implementation_context.json"

echo "=== Rust scanner run ==="
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
assert_file "rust codebase index created" "$INDEX_A"
assert_file "rust style profile created" "$STYLE_A"
assert_file "rust digest cache created" "$DIGEST_A"

echo ""
echo "=== Rust scanner signals ==="
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

require(any(item.get("language") == "rust" for item in index.get("languageDetections", [])), "rust language detection missing")
require("rust" in index.get("primaryLanguages", []), "rust primary language missing")

root_manifest = find("manifests", path="Cargo.toml", kind="cargo")
require(root_manifest is not None, "root Cargo.toml manifest missing")
if root_manifest:
    require(root_manifest.get("workspaceMembers") == ["crates/api", "crates/cli", "crates/shared"], "workspace members not parsed")
shared_manifest = find("manifests", path="crates/shared/Cargo.toml", kind="cargo")
require(shared_manifest is not None and shared_manifest.get("packageName") == "shared", "nested shared package manifest missing")
api_manifest = find("manifests", path="crates/api/Cargo.toml", kind="cargo")
require(api_manifest is not None and "shared" in api_manifest.get("dependencies", []), "dependency keys not parsed")
cli_manifest = find("manifests", path="crates/cli/Cargo.toml", kind="cargo")
require(cli_manifest is not None and cli_manifest.get("bin"), "bin hints not parsed")

symbols = records("symbols")
def symbol(name, kind=None, path="crates/shared/src/validation.rs"):
    for item in symbols:
        if item.get("name") == name and item.get("path") == path and (kind is None or item.get("kind") == kind):
            return item
    return None

validate = symbol("validate_email", "function")
require(validate is not None and validate.get("exported") is True and validate.get("visibility") == "pub", "pub function visibility/export missing")
normalize = symbol("normalize_email", "function")
require(normalize is not None and normalize.get("exported") is False and normalize.get("visibility") == "pub(crate)", "pub(crate) function visibility/export missing")
require(symbol("EmailAddress", "struct") is not None, "struct symbol missing")
require(symbol("ValidationError", "enum") is not None, "enum symbol missing")
require(symbol("Validator", "trait") is not None, "trait symbol missing")
require(symbol("UserId", "type") is not None, "type alias symbol missing")
require(symbol("DEFAULT_TIMEOUT", "constant") is not None, "const symbol missing")
require(symbol("CACHE_NAME", "static") is not None, "static symbol missing")
method = symbol("validate", "method")
require(method is not None and method.get("implType") == "EmailAddress", "impl method symbol missing")
module_symbol = symbol("validation", "module", "crates/shared/src/lib.rs")
require(module_symbol is not None and module_symbol.get("exported") is True, "pub mod symbol missing")
inline_test_symbol = symbol("validates_email", "function")
require(
    inline_test_symbol is None or inline_test_symbol.get("testOnly") is True,
    "inline cfg(test) function emitted as production symbol",
)

imports = records("imports")
def has_import(path, imported, resolved=None, kind=None):
    for item in imports:
        if item.get("path") != path or item.get("imported") != imported:
            continue
        if resolved is not None and item.get("resolvedPath") != resolved:
            continue
        if kind is not None and item.get("kind") != kind:
            continue
        return True
    return False

require(has_import("crates/api/src/signup.rs", "shared::validation::validate_email", "crates/shared/src/validation.rs"), "api shared use import not resolved")
require(has_import("crates/cli/src/main.rs", "shared::validation::validate_email", "crates/shared/src/validation.rs"), "cli shared use import not resolved")
require(has_import("crates/shared/src/lib.rs", "validation", "crates/shared/src/validation.rs", "mod"), "pub mod validation not resolved")
require(has_import("crates/shared/src/lib.rs", "validation::validate_email", "crates/shared/src/validation.rs", "pub use"), "pub use validation not extracted")
require(has_import("tests/integration_signup.rs", "api::signup::create_signup", "crates/api/src/signup.rs"), "workspace crate integration import not resolved")

modules = records("modules")
shared_lib = find("modules", path="crates/shared/src/lib.rs")
cli_main = find("modules", path="crates/cli/src/main.rs")
integration = find("modules", path="tests/integration_signup.rs")
require(shared_lib is not None and shared_lib.get("rustRole") == "library-crate-root", "src/lib.rs library boundary missing")
require(cli_main is not None and cli_main.get("rustRole") == "binary-crate-root", "src/main.rs binary boundary missing")
require(integration is not None and integration.get("kind") == "test", "tests/ integration test module missing")

boundaries = records("moduleBoundaries")
def has_boundary(path, kind):
    return any(item.get("path") == path and item.get("kind") == kind for item in boundaries)
require(has_boundary("crates/shared/src/lib.rs", "rust-library-crate-root"), "library crate boundary missing")
require(has_boundary("crates/cli/src/main.rs", "rust-binary-crate-root"), "binary crate boundary missing")
require(has_boundary("crates/shared", "rust-workspace-member"), "workspace member boundary missing")
require(has_boundary("crates/shared/src/validation.rs", "rust-inline-cfg-test"), "inline cfg test boundary missing")
require(has_boundary("crates/shared/src/validation.rs", "rust-crate-local-visibility"), "crate-local visibility boundary missing")

tests = records("tests")
validation_test = next((item for item in tests if item.get("path") == "crates/shared/src/validation.rs"), None)
require(validation_test is not None and validation_test.get("framework") == "rust-test", "inline Rust test record missing")
if validation_test:
    require(validation_test.get("inlineCfgTest") is True, "inline cfg(test) flag missing")
    require("validates_email" in validation_test.get("testFunctions", []), "inline test function missing")
integration_test = next((item for item in tests if item.get("path") == "tests/integration_signup.rs"), None)
require(integration_test is not None and integration_test.get("framework") == "tokio-test", "tokio integration test missing")
if integration_test:
    require("accepts_signup_email" in integration_test.get("testFunctions", []), "tokio test function missing")

test_conventions = style.get("testConventions", [])
require(any(item.get("language") == "rust" and item.get("value") == "inline #[cfg(test)]" for item in test_conventions), "inline Rust test convention missing")
require(any(item.get("language") == "rust" and item.get("value") == "tests/ directory" for item in test_conventions), "Rust tests directory convention missing")
require(any(item.get("value") == "Rust crate-local visibility" for item in style.get("boundaries", [])), "crate-local visibility style boundary missing")

shared = find("sharedCandidates", path="crates/shared/src/validation.rs")
require(shared is not None, "Rust shared validation candidate missing")
if shared:
    require("validate_email" in shared.get("symbols", []), "shared candidate exported symbol missing")
    require(shared.get("usageCount", 0) >= 2, "shared candidate fan-in too low")
    require("crates/api/src/signup.rs" in shared.get("importedBy", []), "api importer missing")
    require("crates/cli/src/main.rs" in shared.get("importedBy", []), "cli importer missing")
    require("crates/shared/src/validation.rs" in shared.get("pairedTests", []), "inline paired test missing")
    reasons = set(shared.get("reasons", []))
    require({"imported-by-local-files", "exported-symbols", "paired-test"} <= reasons, "shared candidate lacks strong reasons")
    require(reasons != {"shared-directory-name"}, "shared candidate relies only on directory name")
    require("normalize_email" in shared.get("crateLocalSymbols", []), "crate-local symbol risk evidence missing")
    require(shared.get("visibilityRisks"), "visibility risk missing on shared candidate")

for candidate in records("sharedCandidates"):
    reasons = set(candidate.get("reasons", []))
    if candidate.get("language") == "rust":
        require(reasons != {"shared-directory-name"} and reasons != {"rust-crates-directory"}, "Rust candidate uses only weak directory prior")

files = digests.get("files", {})
for path in (
    "Cargo.toml",
    "crates/shared/src/validation.rs",
    "crates/api/src/signup.rs",
    "crates/cli/src/main.rs",
    "tests/integration_signup.rs",
):
    require(path in files, f"digest missing {path}")
    require(files.get(path, {}).get("indexed") is True, f"digest did not index {path}")
require(work not in json.dumps(index) and work not in json.dumps(style) and work not in json.dumps(digests), "scanner artifacts leaked temp path")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Rust scanner language, manifest, symbol, import, test, boundary, shared, and digest signals are valid"
else
  fail "Rust scanner language, manifest, symbol, import, test, boundary, shared, and digest signals are valid" "Python assertion failed"
fi

echo ""
echo "=== Rust matcher run ==="
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
assert_file "rust reuse candidates created" "$REUSE_A"
assert_file "rust implementation context created" "$CONTEXT_A"

if python3 - "$REUSE_A" "$CONTEXT_A" "$WORK" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text())
context = json.loads(Path(sys.argv[2]).read_text())
work = sys.argv[3]
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

candidates = reuse.get("candidates", [])
require(reuse.get("contractId") == "rust-validation-contract", "Rust contract ID missing")
require(reuse.get("candidateCount") == len(candidates), "candidate count mismatch")
require("rust" in context.get("primaryLanguages", []), "Rust context language missing")
require(context.get("moduleBoundaries"), "Rust module boundaries missing from implementation context")
require(work not in json.dumps(reuse) and work not in json.dumps(context), "matcher artifacts leaked temp path")

validation_candidates = [
    item for item in candidates
    if item.get("path") == "crates/shared/src/validation.rs"
    and item.get("kind") in {"existing-helper", "shared-module"}
]
require(validation_candidates, "Rust validation helper candidate missing")
helper = next((item for item in validation_candidates if item.get("symbol") == "validate_email"), None)
require(helper is not None, "validate_email helper candidate missing")
helper = helper or validation_candidates[0]
why = " ".join(helper.get("whyRelevant", [])).lower()
require(helper.get("whyRelevant"), "Rust helper whyRelevant missing")
require(any(term in why for term in ("symbol", "imported", "paired test", "shared candidate", "validation")), "Rust helper lacks evidence")
require(helper.get("kind") in {"existing-helper", "shared-module"}, "Rust helper kind is unexpected")
require(any(item.get("path") == "crates/shared/src/validation.rs" for item in candidates[:3]), "Rust helper is not a top candidate")
helper_risks = " ".join(helper.get("risks", [])).lower()
require("crate-local" not in helper_risks and "outside its crate" not in helper_risks, "pub helper inherited crate-local visibility risk")

require(
    not any(item.get("symbol") == "validates_email" for item in candidates),
    "inline test function surfaced as reuse candidate",
)

normalize = next((item for item in candidates if item.get("symbol") == "normalize_email"), None)
if normalize is not None:
    risks = " ".join(normalize.get("risks", [])).lower()
    require("crate-local" in risks or "outside its crate" in risks, "pub(crate) helper lacks boundary risk")

shared_module = next(
    (
        item for item in candidates
        if item.get("path") == "crates/shared/src/validation.rs"
        and item.get("kind") == "shared-module"
    ),
    None,
)
if shared_module is not None:
    module_risks = " ".join(shared_module.get("risks", [])).lower()
    require("crate-local" in module_risks or "visibility" in module_risks, "shared module lacks mixed visibility boundary context")

main_candidate = next((item for item in candidates if item.get("path") == "crates/cli/src/main.rs"), None)
if main_candidate is not None:
    require(any("binary" in risk.lower() for risk in main_candidate.get("risks", [])), "src/main.rs candidate lacks binary boundary risk")

for candidate in validation_candidates:
    why_text = " ".join(candidate.get("whyRelevant", [])).lower()
    require("crates directory" not in why_text, "validation candidate relies on crates directory wording")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Rust matcher candidates and boundary risks are valid"
else
  fail "Rust matcher candidates and boundary risks are valid" "Python assertion failed"
fi

echo ""
echo "=== Fixed-time stability ==="
if run_second_digest; then
  pass "second same-project digest run exits 0"
else
  fail "second same-project digest run exits 0" "command failed"
fi
if cmp -s "$INDEX_A" "$INDEX_B"; then
  pass "rust codebase index is byte-stable with fixed generatedAt"
else
  fail "rust codebase index is byte-stable with fixed generatedAt" "$(diff -u "$INDEX_A" "$INDEX_B" || true)"
fi
if cmp -s "$STYLE_A" "$STYLE_B"; then
  pass "rust style profile is byte-stable with fixed generatedAt"
else
  fail "rust style profile is byte-stable with fixed generatedAt" "$(diff -u "$STYLE_A" "$STYLE_B" || true)"
fi
if cmp -s "$DIGEST_A" "$SECOND_DIGEST_A"; then
  pass "rust digest cache is byte-stable with fixed generatedAt"
else
  fail "rust digest cache is byte-stable with fixed generatedAt" "$(diff -u "$DIGEST_A" "$SECOND_DIGEST_A" || true)"
fi
if cmp -s "$REUSE_A" "$REUSE_B"; then
  pass "rust reuse candidates are byte-stable with fixed generatedAt"
else
  fail "rust reuse candidates are byte-stable with fixed generatedAt" "$(diff -u "$REUSE_A" "$REUSE_B" || true)"
fi
if cmp -s "$CONTEXT_A" "$CONTEXT_B"; then
  pass "rust implementation context is byte-stable with fixed generatedAt"
else
  fail "rust implementation context is byte-stable with fixed generatedAt" "$(diff -u "$CONTEXT_A" "$CONTEXT_B" || true)"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: codebase awareness Rust adapter signals and matcher candidates are deterministic"
