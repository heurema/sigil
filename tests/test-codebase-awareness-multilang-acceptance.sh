#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE_ROOT="$ROOT_DIR/tests/fixtures/codebase-awareness"
GOLDEN_DIR="$FIXTURE_ROOT/golden"
PACK_WIRING_TEST="$ROOT_DIR/tests/test-codebase-awareness-pack-wiring.sh"
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

contract_for_fixture() {
  case "$1" in
    basic-mixed) printf '%s\n' "$FIXTURE_ROOT/contracts/validation-contract.json" ;;
    go-basic) printf '%s\n' "$FIXTURE_ROOT/contracts/go-validation-contract.json" ;;
    rust-basic) printf '%s\n' "$FIXTURE_ROOT/contracts/rust-validation-contract.json" ;;
    csharp-basic) printf '%s\n' "$FIXTURE_ROOT/contracts/csharp-validation-contract.json" ;;
    typescript-basic) printf '%s\n' "$FIXTURE_ROOT/contracts/typescript-validation-contract.json" ;;
    python-basic) printf '%s\n' "$FIXTURE_ROOT/contracts/python-validation-contract.json" ;;
    *) return 1 ;;
  esac
}

run_scanner_full() {
  local project="$1"
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-v1.json" \
      --style-output ".signum/cache/style-profile-v1.json" \
      --digests-output ".signum/cache/file-digests-v1.json" \
      --extracts-output ".signum/cache/file-extracts-v1.json" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

run_scanner_cached() {
  local project="$1"
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-cached.json" \
      --style-output ".signum/cache/style-profile-cached.json" \
      --digests-output ".signum/cache/file-digests-cached.json" \
      --extracts-output ".signum/cache/file-extracts-cached.json" \
      --previous-extracts ".signum/cache/file-extracts-v1.json" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

run_matcher() {
  local fixture="$1"
  local project="$2"
  local contract
  contract="$(contract_for_fixture "$fixture")"
  if [ ! -f "$contract" ]; then
    return 2
  fi
  mkdir -p "$project/.signum/contracts/acceptance"
  cp "$contract" "$project/.signum/contracts/acceptance/contract.json"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/acceptance/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/acceptance/reuse_candidates.json" \
      --implementation-context ".signum/contracts/acceptance/implementation_context.json" \
      --max-candidates 12 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

validate_scanner_fixture() {
  local fixture="$1" project="$2"
  local index="$project/.signum/cache/codebase-index-v1.json"
  local style="$project/.signum/cache/style-profile-v1.json"
  local digests="$project/.signum/cache/file-digests-v1.json"
  local extracts="$project/.signum/cache/file-extracts-v1.json"
  local cached_index="$project/.signum/cache/codebase-index-cached.json"
  local cached_style="$project/.signum/cache/style-profile-cached.json"
  local cached_digests="$project/.signum/cache/file-digests-cached.json"
  local cached_extracts="$project/.signum/cache/file-extracts-cached.json"
  local golden="$GOLDEN_DIR/$fixture-summary.json"

  python3 - "$fixture" "$index" "$style" "$digests" "$extracts" "$cached_index" "$cached_style" "$cached_digests" "$cached_extracts" "$project" "$golden" <<'PY'
import copy
import difflib
import json
import sys
from pathlib import Path

fixture = sys.argv[1]
paths = {
    "index": Path(sys.argv[2]),
    "style": Path(sys.argv[3]),
    "digests": Path(sys.argv[4]),
    "extracts": Path(sys.argv[5]),
    "cached_index": Path(sys.argv[6]),
    "cached_style": Path(sys.argv[7]),
    "cached_digests": Path(sys.argv[8]),
    "cached_extracts": Path(sys.argv[9]),
}
project = sys.argv[10]
golden_path = Path(sys.argv[11])
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def load_json(label: str) -> dict:
    try:
        value = json.loads(paths[label].read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{label} is not parseable JSON: {exc}")
        return {}
    require(isinstance(value, dict), f"{label} must be a JSON object")
    return value if isinstance(value, dict) else {}


index = load_json("index")
style = load_json("style")
digests = load_json("digests")
extracts = load_json("extracts")
cached_index = load_json("cached_index")
cached_digests = load_json("cached_digests")
cached_extracts = load_json("cached_extracts")
load_json("cached_style")

for label, path in paths.items():
    require(path.is_file(), f"{label} output is missing")

serialized = "\n".join(
    json.dumps(value, sort_keys=True)
    for value in (index, style, digests, extracts, cached_index, cached_digests, cached_extracts)
)
require(project not in serialized, "scanner artifacts leaked temp absolute project path")


def check_repo_relative_path(value, label: str) -> None:
    if value in (None, "", "."):
        return
    if isinstance(value, str):
        require(not value.startswith("/"), f"{label} is absolute: {value}")
        require(project not in value, f"{label} leaked temp project path: {value}")


def walk_path_fields(value, label: str = "artifact") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            key_lower = str(key).lower()
            child_label = f"{label}.{key}"
            if "path" in key_lower or key in {"importedBy", "pairedTests", "projectReferences", "workspaceMembers", "workspaceUses"}:
                if isinstance(item, list):
                    for idx, entry in enumerate(item):
                        check_repo_relative_path(entry, f"{child_label}[{idx}]")
                else:
                    check_repo_relative_path(item, child_label)
            walk_path_fields(item, child_label)
    elif isinstance(value, list):
        for idx, item in enumerate(value):
            walk_path_fields(item, f"{label}[{idx}]")


for label, value in (
    ("index", index),
    ("style", style),
    ("digests", digests),
    ("extracts", extracts),
    ("cached_index", cached_index),
    ("cached_digests", cached_digests),
    ("cached_extracts", cached_extracts),
):
    walk_path_fields(value, label)

for artifact in (digests, extracts, cached_digests, cached_extracts):
    for rel in artifact.get("files", {}):
        check_repo_relative_path(rel, "cache files key")

cached_stats = cached_index.get("scanStats", {})
require(cached_stats.get("filesReused", 0) > 0, "cached scanner pass did not reuse any file extraction")


def without_reuse_counts(value: dict) -> dict:
    cloned = copy.deepcopy(value)
    scan_stats = cloned.get("scanStats", {})
    if isinstance(scan_stats, dict):
        scan_stats.pop("filesReused", None)
        scan_stats.pop("filesExtracted", None)
    return cloned


normalized_full = without_reuse_counts(index)
normalized_cached = without_reuse_counts(cached_index)
if normalized_full != normalized_cached:
    expected = json.dumps(normalized_full, indent=2, sort_keys=True).splitlines()
    actual = json.dumps(normalized_cached, indent=2, sort_keys=True).splitlines()
    diff = "\n".join(difflib.unified_diff(expected, actual, fromfile="full", tofile="cached", lineterm=""))
    errors.append(f"cached/full index parity failed after removing reuse counters:\n{diff}")

if paths["style"].read_bytes() != paths["cached_style"].read_bytes():
    errors.append("cached/full style profile is not byte-identical")


def records(section: str) -> list[dict]:
    value = index.get(section, [])
    return value if isinstance(value, list) else []


def names(section: str, key: str) -> set[str]:
    return {item.get(key) for item in records(section) if isinstance(item.get(key), str)}


primary = index.get("primaryLanguages", [])
detected = {item.get("language") for item in records("languageDetections")}
manifest_kinds = names("manifests", "kind")
shared_paths = names("sharedCandidates", "path")
symbol_names = names("symbols", "name")
test_frameworks = names("tests", "framework")
boundary_kinds = names("moduleBoundaries", "kind")

summary = {
    "boundaryKinds": sorted(boundary_kinds),
    "cacheStatsShape": {
        "hasFilesExtracted": "filesExtracted" in index.get("scanStats", {}),
        "hasFilesReused": "filesReused" in index.get("scanStats", {}),
    },
    "detectedLanguages": sorted(language for language in detected if language),
    "fixture": fixture,
    "manifestKinds": sorted(kind for kind in manifest_kinds if kind),
    "primaryLanguages": primary,
    "sharedCandidatePaths": sorted(path for path in shared_paths if path),
    "symbolNames": sorted(name for name in symbol_names if name),
    "testFrameworks": sorted(framework for framework in test_frameworks if framework),
}
try:
    expected_summary = json.loads(golden_path.read_text(encoding="utf-8"))
except Exception as exc:
    expected_summary = None
    errors.append(f"golden summary is not parseable: {exc}")
if expected_summary is not None and summary != expected_summary:
    expected = json.dumps(expected_summary, indent=2, sort_keys=True).splitlines()
    actual = json.dumps(summary, indent=2, sort_keys=True).splitlines()
    diff = "\n".join(difflib.unified_diff(expected, actual, fromfile=str(golden_path), tofile=f"{fixture} actual", lineterm=""))
    errors.append(f"golden summary mismatch:\n{diff}")

if fixture == "basic-mixed":
    require({"typescript", "javascript", "python"} <= set(primary), "basic mixed primary languages lost MVP coverage")
    require("src/shared/validation.ts" in shared_paths, "basic mixed shared validation candidate missing")
    require(test_frameworks, "basic mixed tests were not detected")
elif fixture == "go-basic":
    require("go" in primary and "go" in detected, "Go language missing")
    require("go" in manifest_kinds, "go.mod manifest missing")
    require("pkg/validation" in shared_paths, "Go pkg/validation shared candidate missing")
    require("go-test" in test_frameworks, "go-test evidence missing")
    require({"go-internal", "go-cmd", "go-pkg"} <= boundary_kinds, "Go boundary hints missing")
elif fixture == "rust-basic":
    require("rust" in primary and "rust" in detected, "Rust language missing")
    require("cargo" in manifest_kinds, "Cargo manifest missing")
    require("validate_email" in symbol_names, "Rust validate_email symbol missing")
    require("crates/shared/src/validation.rs" in shared_paths, "Rust shared validation candidate missing")
    require(
        any(item.get("path") == "crates/shared/src/validation.rs" and item.get("inlineCfgTest") is True for item in records("tests")),
        "Rust inline #[cfg(test)] evidence missing",
    )
    require("rust-inline-cfg-test" in boundary_kinds, "Rust inline cfg test boundary missing")
    require("rust-crate-local-visibility" in boundary_kinds, "Rust pub(crate) boundary missing")
    require(
        not any(item.get("name") == "validates_email" and item.get("testOnly") is not True for item in records("symbols")),
        "Rust test-only validates_email surfaced as production helper",
    )
elif fixture == "csharp-basic":
    require("csharp" in primary and "csharp" in detected, "C# language missing")
    require({"dotnet-solution", "dotnet-project"} <= manifest_kinds, ".sln/.csproj manifests missing")
    require("src/Common" in shared_paths, "C# src/Common shared candidate missing")
    require("xunit" in test_frameworks, "xUnit test evidence missing")
    require("dotnet-internal-api" in boundary_kinds, "C# internal assembly-local boundary missing")
    validate_email = next((item for item in records("symbols") if item.get("name") == "ValidateEmail" and item.get("path") == "src/Common/EmailValidator.cs"), {})
    normalize_email = next((item for item in records("symbols") if item.get("name") == "NormalizeEmail" and item.get("path") == "src/Common/EmailValidator.cs"), {})
    require(validate_email.get("visibility") == "public", "C# public ValidateEmail symbol missing")
    require(not validate_email.get("visibilityRisks"), "C# public ValidateEmail inherited internal risk")
    require(normalize_email.get("visibility") == "internal" and normalize_email.get("visibilityRisks"), "C# internal boundary evidence missing")
elif fixture == "typescript-basic":
    require("typescript" in primary and "typescript" in detected, "TypeScript language missing")
    require({"npm-package", "pnpm-workspace", "tsconfig", "jsconfig"} <= manifest_kinds, "TypeScript JSON/YAML config manifests missing")
    require("packages/shared/src/validation.ts" in shared_paths, "TypeScript validation shared candidate missing")
    require("validateEmail" in symbol_names, "TypeScript validateEmail helper missing")
    require("vitest" in test_frameworks, "Vitest test evidence missing")
    require("npm-bin-entrypoint" in boundary_kinds, "TypeScript CLI/bin boundary missing")
    require("packages/shared/src/common-utils.ts" not in shared_paths, "common-utils became shared candidate from weak path only")
elif fixture == "python-basic":
    require("python" in primary and "python" in detected, "Python language missing")
    require({"python-project", "python-requirements"} <= manifest_kinds, "Python project/requirements manifests missing")
    require("src/acme_shared/validation.py" in shared_paths, "Python validation shared candidate missing")
    require("validate_email" in symbol_names, "Python validate_email helper missing")
    require("pytest" in test_frameworks, "pytest evidence missing")
    require({"python-project", "python-package", "python-cli-entrypoint", "python-test-file"} <= boundary_kinds, "Python boundary hints missing")
    require("src/shared/helpers.py" not in shared_paths, "Python weak shared/common/utils path became shared candidate")
else:
    errors.append(f"unknown fixture {fixture}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
}

validate_matcher_fixture() {
  local fixture="$1" project="$2"
  local index="$project/.signum/cache/codebase-index-v1.json"
  local reuse="$project/.signum/contracts/acceptance/reuse_candidates.json"
  local context="$project/.signum/contracts/acceptance/implementation_context.json"

  python3 - "$fixture" "$reuse" "$context" "$index" "$project" <<'PY'
import json
import sys
from pathlib import Path

fixture = sys.argv[1]
reuse = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
context = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
index = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
project = sys.argv[5]
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def records(section: str) -> list[dict]:
    value = index.get(section, [])
    return value if isinstance(value, list) else []


def boundary_kinds() -> set[str]:
    return {item.get("kind") for item in records("moduleBoundaries") if item.get("kind")}


def symbol(name: str, path: str | None = None) -> dict:
    for item in records("symbols"):
        if item.get("name") != name:
            continue
        if path is not None and item.get("path") != path:
            continue
        return item
    return {}


targets = {
    "basic-mixed": ("src/shared/validation.ts", "validateEmail"),
    "go-basic": ("pkg/validation", "ValidateEmail"),
    "rust-basic": ("crates/shared/src/validation.rs", "validate_email"),
    "csharp-basic": ("src/Common", "ValidateEmail"),
    "typescript-basic": ("packages/shared/src/validation.ts", "validateEmail"),
    "python-basic": ("src/acme_shared/validation.py", "validate_email"),
}
target_path, helper_symbol = targets[fixture]
candidates = reuse.get("candidates", [])
top_window = candidates[:8]
require(candidates, "matcher produced no candidates")
require(reuse.get("candidateCount") == len(candidates), "candidateCount does not match candidates length")
require(project not in json.dumps(reuse) and project not in json.dumps(context), "matcher artifacts leaked temp project path")
require(any(candidate.get("path") == target_path for candidate in top_window), f"{target_path} is not in top matcher candidates")

helper = next(
    (
        candidate
        for candidate in candidates
        if candidate.get("path") == target_path and candidate.get("symbol") == helper_symbol
    ),
    None,
)
require(helper is not None, f"{target_path} {helper_symbol} helper candidate is missing")
helper = helper or {}
why_list = helper.get("whyRelevant", [])
why = " ".join(why_list).lower()
non_contract_reasons = [reason for reason in why_list if not str(reason).startswith("contract terms matched")]
require(len(why_list) >= 4 and len(non_contract_reasons) >= 3, "known target has path/name-only relevance evidence")
strong_terms = (
    "imported",
    "paired test",
    "exported",
    "multiple reuse signals",
    "shared candidate",
    "validation helper",
    "project/assembly",
    "workspace",
)
require(sum(1 for term in strong_terms if term in why) >= 2, "known target lacks multiple strong evidence reasons")

weak_only_paths = {
    "packages/shared/src/common-utils.ts",
    "packages/cli/src/index.ts",
}
require(not any(candidate.get("path") in weak_only_paths for candidate in top_window), "weak-only shared/common/CLI candidate is top-ranked")
for candidate in candidates[:5]:
    candidate_why = " ".join(candidate.get("whyRelevant", [])).lower()
    mentions_weak_prior = "weak" in candidate_why or "shared/common directory hint" in candidate_why
    if mentions_weak_prior:
        require(any(term in candidate_why for term in strong_terms), f"top candidate {candidate.get('candidateId')} relies only on weak prior")

if fixture == "go-basic":
    require({"go-internal", "go-cmd"} <= boundary_kinds(), "Go internal/cmd boundary risks missing")
    require(any("internal package boundary" in " ".join(candidate.get("whyRelevant", [])).lower() for candidate in candidates), "Go matcher does not surface internal package boundary evidence")
elif fixture == "rust-basic":
    require({"rust-inline-cfg-test", "rust-crate-local-visibility"} <= boundary_kinds(), "Rust test/crate-local boundary risks missing")
    require(not any(candidate.get("symbol") == "validates_email" for candidate in candidates), "Rust test-only validates_email surfaced as matcher candidate")
elif fixture == "csharp-basic":
    require("dotnet-internal-api" in boundary_kinds(), "C# internal assembly boundary risk missing")
    require("internal assembly-local symbols" in json.dumps(context), "C# matcher context lacks internal assembly-local evidence")
    validate_email = symbol("ValidateEmail", "src/Common/EmailValidator.cs")
    require(validate_email and not validate_email.get("visibilityRisks"), "C# public ValidateEmail inherited internal risk")
elif fixture == "typescript-basic":
    require({"npm-bin-entrypoint", "tsjs-test-file"} <= boundary_kinds(), "TypeScript CLI/test boundaries missing")
    require(
        not any(candidate.get("path") == "packages/cli/src/index.ts" and candidate.get("kind") in {"existing-helper", "shared-module"} for candidate in candidates),
        "TypeScript CLI/bin entrypoint surfaced as reusable helper",
    )
elif fixture == "python-basic":
    require({"python-cli-entrypoint", "python-test-file"} <= boundary_kinds(), "Python CLI/test boundaries missing")
    validate_email = symbol("validate_email", "src/acme_shared/validation.py")
    require(validate_email is not None, "Python validate_email helper missing from matcher candidates")
    if validate_email:
        risks = " ".join(validate_email.get("risks", [])).lower()
        require("private" not in risks, "Python public validate_email inherited private risk")
        require("module-local" not in risks, "Python public validate_email inherited module-local risk")
        require("boundary review" not in risks, "Python public validate_email inherited boundary-review risk")
    shared_module = next(
        (
            candidate
            for candidate in candidates
            if candidate.get("path") == "src/acme_shared/validation.py"
            and candidate.get("kind") == "shared-module"
            and candidate.get("symbol") is None
        ),
        None,
    )
    require(shared_module is not None, "Python validation shared-module candidate missing")
    if shared_module:
        require(any("private" in risk.lower() for risk in shared_module.get("risks", [])), "Python shared-module lost private risk")
    require(
        not any(candidate.get("path") == "src/acme_cli/__main__.py" and candidate.get("kind") in {"existing-helper", "shared-module"} for candidate in candidates),
        "Python CLI entrypoint surfaced as reusable helper",
    )
    private = [candidate for candidate in candidates if candidate.get("symbol") == "_private_format_email"]
    if private:
        require(any("private" in " ".join(candidate.get("risks", [])).lower() for candidate in private), "Python private helper risk missing")
elif fixture == "basic-mixed":
    require("tsjs-test-file" in boundary_kinds(), "basic mixed test boundary missing")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
}

echo "=== Multi-language scanner acceptance ==="
for fixture in basic-mixed go-basic rust-basic csharp-basic typescript-basic python-basic; do
  project="$WORK/$fixture"
  cp -R "$FIXTURE_ROOT/$fixture" "$project"

  if run_scanner_full "$project"; then
    pass "$fixture full scanner exits 0"
  else
    fail "$fixture full scanner exits 0" "command failed"
    continue
  fi

  assert_file "$fixture codebase index exists" "$project/.signum/cache/codebase-index-v1.json"
  assert_file "$fixture style profile exists" "$project/.signum/cache/style-profile-v1.json"
  assert_file "$fixture file digests cache exists" "$project/.signum/cache/file-digests-v1.json"
  assert_file "$fixture file extracts cache exists" "$project/.signum/cache/file-extracts-v1.json"

  if run_scanner_cached "$project"; then
    pass "$fixture cached scanner exits 0"
  else
    fail "$fixture cached scanner exits 0" "command failed"
    continue
  fi

  if validate_scanner_fixture "$fixture" "$project"; then
    pass "$fixture scanner artifacts, cache parity, and golden summary match"
  else
    fail "$fixture scanner artifacts, cache parity, and golden summary match" "Python assertion failed"
  fi
done

echo ""
echo "=== Multi-language matcher acceptance ==="
for fixture in basic-mixed go-basic rust-basic csharp-basic typescript-basic python-basic; do
  project="$WORK/$fixture"
  contract="$(contract_for_fixture "$fixture")"
  if [ ! -f "$contract" ]; then
    pass "$fixture matcher skipped because no contract fixture exists"
    continue
  fi

  if run_matcher "$fixture" "$project"; then
    pass "$fixture matcher exits 0"
  else
    fail "$fixture matcher exits 0" "command failed"
    continue
  fi

  assert_file "$fixture reuse candidates exist" "$project/.signum/contracts/acceptance/reuse_candidates.json"
  assert_file "$fixture implementation context exists" "$project/.signum/contracts/acceptance/implementation_context.json"

  if validate_matcher_fixture "$fixture" "$project"; then
    pass "$fixture matcher target, evidence, weak-candidate, and boundary assertions hold"
  else
    fail "$fixture matcher target, evidence, weak-candidate, and boundary assertions hold" "Python assertion failed"
  fi
done

echo ""
echo "=== Proofpack cache exclusion guard ==="
if python3 - "$PACK_WIRING_TEST" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = {
    ".signum/cache/codebase-index-v1.json": "proofpack does not embed codebase index cache",
    ".signum/cache/style-profile-v1.json": "proofpack does not embed style profile cache",
    ".signum/cache/file-digests-v1.json": "proofpack does not embed future digest cache",
    ".signum/cache/file-extracts-v1.json": "proofpack does not embed extraction cache",
}
missing = [path for path, assertion in required.items() if path not in text or assertion not in text]
if missing:
    print("\n".join(missing), file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "PACK wiring test excludes all project-level Codebase Awareness cache files"
else
  fail "PACK wiring test excludes all project-level Codebase Awareness cache files" "missing exclusion assertion"
fi

echo ""
printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Codebase Awareness multi-language acceptance and golden parity coverage holds"
