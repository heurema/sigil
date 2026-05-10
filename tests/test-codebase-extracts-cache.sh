#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/basic-mixed"
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

assert_json() {
  local name="$1"
  local project="$2"
  local script="$3"
  shift 3
  if python3 - "$project" "$script" "$@" <<'PY'; then
import json
import sys
from pathlib import Path

project = sys.argv[1]
script = sys.argv[2]
paths = [Path(item) for item in sys.argv[3:]]
data = [json.loads(path.read_text(encoding="utf-8")) for path in paths]
namespace = {
    "data": data,
    "json": json,
    "project": project,
}
try:
    exec(script, namespace)
except AssertionError as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
    pass "$name"
  else
    fail "$name" "JSON assertion failed"
  fi
}

echo "=== First run writes extraction cache ==="
PROJECT_A="$(make_project first-run)"
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json"; then
  pass "scanner writes extraction cache"
else
  fail "scanner writes extraction cache" "command failed"
fi
assert_json "first run extraction cache schema and paths are portable" \
  "$PROJECT_A" \
  'extracts = data[0]
assert extracts["schemaVersion"] == "1.0", "schemaVersion"
assert extracts["generatedAt"] == "2026-01-01T00:00:00Z", "generatedAt"
assert extracts["projectRoot"] == ".", "projectRoot"
assert extracts["scanMode"] == "shallow-regex-v1", "scanMode"
assert extracts["extractorVersion"] == "codebase-awareness-extracts-v1", "extractorVersion"
files = extracts.get("files")
assert isinstance(files, dict) and files, "files"
stats = extracts.get("scanStats", {})
assert stats.get("filesReused") == 0, "first run reused files"
assert stats.get("filesExtracted", 0) > 0, "first run extracted files"
for key, record in files.items():
    assert not key.startswith("/"), f"absolute key: {key}"
    assert project not in key, f"temp path leaked in key: {key}"
    if record.get("indexed"):
        for field in ("sha256", "sizeBytes", "language", "module", "symbols", "imports", "tests", "manifest", "fileTextSignals"):
            assert field in record, f"missing {field} in {key}"
assert project not in json.dumps(extracts), "temp project path leaked"' \
  "$PROJECT_A/.signum/cache/file-extracts-v1.json"

echo ""
echo "=== Second unchanged run reuses payloads ==="
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-reuse.json" ".signum/cache/style-profile-reuse.json" ".signum/cache/file-digests-reuse.json" ".signum/cache/file-extracts-reuse.json" --previous-extracts ".signum/cache/file-extracts-v1.json"; then
  pass "unchanged reuse run exits 0"
else
  fail "unchanged reuse run exits 0" "command failed"
fi
if run_scanner "$PROJECT_A" ".signum/cache/codebase-index-full.json" ".signum/cache/style-profile-full.json" ".signum/cache/file-digests-full.json" ".signum/cache/file-extracts-full.json"; then
  pass "full comparison run exits 0"
else
  fail "full comparison run exits 0" "command failed"
fi
assert_json "unchanged run reports real reuse and preserves final scanner content" \
  "$PROJECT_A" \
  'first, reuse, full, style_reuse, style_full = data
first_stats = first["scanStats"]
reuse_stats = reuse["scanStats"]
assert reuse_stats["filesReused"] > 0, "no files reused"
assert reuse_stats["filesExtracted"] < first_stats["filesExtracted"], "filesExtracted did not drop"
assert style_reuse == style_full, "style profile changed under reuse"
reuse_index = data[1]
full_index = data[2]
for item in (reuse_index, full_index):
    item["scanStats"].pop("filesReused", None)
    item["scanStats"].pop("filesExtracted", None)
assert reuse_index == full_index, "index changed beyond honest reuse counters"' \
  "$PROJECT_A/.signum/cache/file-extracts-v1.json" \
  "$PROJECT_A/.signum/cache/codebase-index-reuse.json" \
  "$PROJECT_A/.signum/cache/codebase-index-full.json" \
  "$PROJECT_A/.signum/cache/style-profile-reuse.json" \
  "$PROJECT_A/.signum/cache/style-profile-full.json"

echo ""
echo "=== One changed file is freshly extracted ==="
PROJECT_C="$(make_project changed-file)"
run_scanner "$PROJECT_C" ".signum/cache/codebase-index-a.json" ".signum/cache/style-profile-a.json" ".signum/cache/file-digests-a.json" ".signum/cache/file-extracts-a.json"
cat >> "$PROJECT_C/src/shared/validation.ts" <<'TS'

export function changedCacheValidator(email: string): boolean {
  return validateEmail(email).ok;
}
TS
if run_scanner "$PROJECT_C" ".signum/cache/codebase-index-b.json" ".signum/cache/style-profile-b.json" ".signum/cache/file-digests-b.json" ".signum/cache/file-extracts-b.json" --previous-extracts ".signum/cache/file-extracts-a.json"; then
  pass "changed-file reuse run exits 0"
else
  fail "changed-file reuse run exits 0" "command failed"
fi
assert_json "changed file is extracted and changed symbol appears" \
  "$PROJECT_C" \
  'index, extracts = data
stats = extracts["scanStats"]
assert stats["filesReused"] > 0, "unchanged files not reused"
assert stats["filesExtracted"] == 1, f"changed file extraction count: {stats}"
record = extracts["files"]["src/shared/validation.ts"]
assert record["sha256"] is not None and record["indexed"] is True, "changed file record"
assert any(symbol.get("name") == "changedCacheValidator" for symbol in index["symbols"]), "changed symbol missing"' \
  "$PROJECT_C/.signum/cache/codebase-index-b.json" \
  "$PROJECT_C/.signum/cache/file-extracts-b.json"

echo ""
echo "=== Deleted file removes stale payloads ==="
PROJECT_D="$(make_project deleted-file)"
run_scanner "$PROJECT_D" ".signum/cache/codebase-index-a.json" ".signum/cache/style-profile-a.json" ".signum/cache/file-digests-a.json" ".signum/cache/file-extracts-a.json"
rm "$PROJECT_D/src/features/profile.ts"
if run_scanner "$PROJECT_D" ".signum/cache/codebase-index-b.json" ".signum/cache/style-profile-b.json" ".signum/cache/file-digests-b.json" ".signum/cache/file-extracts-b.json" --previous-extracts ".signum/cache/file-extracts-a.json"; then
  pass "deleted-file reuse run exits 0"
else
  fail "deleted-file reuse run exits 0" "command failed"
fi
assert_json "deleted file has no stale extraction or symbols" \
  "$PROJECT_D" \
  'index, extracts = data
assert "src/features/profile.ts" not in extracts["files"], "deleted file remains in extracts"
assert not any(symbol.get("path") == "src/features/profile.ts" for symbol in index["symbols"]), "deleted symbol path remains"
assert not any(symbol.get("name") == "canAttachRecoveryEmail" for symbol in index["symbols"]), "deleted symbol remains"' \
  "$PROJECT_D/.signum/cache/codebase-index-b.json" \
  "$PROJECT_D/.signum/cache/file-extracts-b.json"

echo ""
echo "=== New file is freshly extracted ==="
PROJECT_E="$(make_project new-file)"
run_scanner "$PROJECT_E" ".signum/cache/codebase-index-a.json" ".signum/cache/style-profile-a.json" ".signum/cache/file-digests-a.json" ".signum/cache/file-extracts-a.json"
cat > "$PROJECT_E/src/shared/cache-helper.ts" <<'TS'
export function newCacheHelper(value: string): string {
  return value.trim();
}
TS
if run_scanner "$PROJECT_E" ".signum/cache/codebase-index-b.json" ".signum/cache/style-profile-b.json" ".signum/cache/file-digests-b.json" ".signum/cache/file-extracts-b.json" --previous-extracts ".signum/cache/file-extracts-a.json"; then
  pass "new-file reuse run exits 0"
else
  fail "new-file reuse run exits 0" "command failed"
fi
assert_json "new file is extracted and symbol appears" \
  "$PROJECT_E" \
  'index, extracts = data
stats = extracts.get("scanStats")
assert stats, "scanStats"
assert stats["filesExtracted"] == 1, f"new file extraction count: {stats}"
assert "src/shared/cache-helper.ts" in extracts["files"], "new file missing from extracts"
assert any(symbol.get("name") == "newCacheHelper" for symbol in index["symbols"]), "new symbol missing"' \
  "$PROJECT_E/.signum/cache/codebase-index-b.json" \
  "$PROJECT_E/.signum/cache/file-extracts-b.json"

echo ""
echo "=== Invalid previous extracts fall back ==="
PROJECT_F="$(make_project invalid-cache)"
printf '{not-json\n' > "$PROJECT_F/invalid-extracts.json"
if run_scanner "$PROJECT_F" ".signum/cache/codebase-index-v1.json" ".signum/cache/style-profile-v1.json" ".signum/cache/file-digests-v1.json" ".signum/cache/file-extracts-v1.json" --previous-extracts "invalid-extracts.json"; then
  pass "invalid previous extracts exits 0"
else
  fail "invalid previous extracts exits 0" "command failed"
fi
assert_json "invalid previous extracts does full extraction with note" \
  "$PROJECT_F" \
  'extracts = data[0]
stats = extracts["scanStats"]
assert stats["filesReused"] == 0, "invalid cache reused files"
assert stats["filesExtracted"] > 0, "invalid cache did not extract"
assert any("previous-extracts ignored" in note for note in stats.get("notes", [])), "missing invalid-cache note"' \
  "$PROJECT_F/.signum/cache/file-extracts-v1.json"

echo ""
echo "=== Schema/version mismatch falls back ==="
PROJECT_G="$(make_project version-mismatch)"
run_scanner "$PROJECT_G" ".signum/cache/codebase-index-a.json" ".signum/cache/style-profile-a.json" ".signum/cache/file-digests-a.json" ".signum/cache/file-extracts-a.json"
python3 - "$PROJECT_G/.signum/cache/file-extracts-a.json" "$PROJECT_G/.signum/cache/file-extracts-bad-version.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
data["extractorVersion"] = "codebase-awareness-extracts-v0"
Path(sys.argv[2]).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
if run_scanner "$PROJECT_G" ".signum/cache/codebase-index-b.json" ".signum/cache/style-profile-b.json" ".signum/cache/file-digests-b.json" ".signum/cache/file-extracts-b.json" --previous-extracts ".signum/cache/file-extracts-bad-version.json"; then
  pass "version mismatch previous extracts exits 0"
else
  fail "version mismatch previous extracts exits 0" "command failed"
fi
assert_json "version mismatch does full extraction with note" \
  "$PROJECT_G" \
  'extracts = data[0]
stats = extracts["scanStats"]
assert stats["filesReused"] == 0, "mismatch cache reused files"
assert stats["filesExtracted"] > 0, "mismatch cache did not extract"
assert any("extractorVersion" in note for note in stats.get("notes", [])), "missing version note"' \
  "$PROJECT_G/.signum/cache/file-extracts-b.json"

echo ""
echo "=== Skipped files are not reused as indexed payloads ==="
PROJECT_H="$(make_project skipped-files)"
mkdir -p "$PROJECT_H/vendor" "$PROJECT_H/src"
printf 'export const ignoredVendor = true\n' > "$PROJECT_H/vendor/ignored.ts"
printf '// @generated\nexport const generatedValue = true\n' > "$PROJECT_H/src/generated.ts"
printf 'abc\000def\n' > "$PROJECT_H/src/binary.dat"
printf 'export const oversizedValue = "%080d";\n' 1 > "$PROJECT_H/src/oversized.ts"
if run_scanner "$PROJECT_H" ".signum/cache/codebase-index-a.json" ".signum/cache/style-profile-a.json" ".signum/cache/file-digests-a.json" ".signum/cache/file-extracts-a.json" --max-file-size 64; then
  pass "skipped-file scanner exits 0"
else
  fail "skipped-file scanner exits 0" "command failed"
fi
if run_scanner "$PROJECT_H" ".signum/cache/codebase-index-b.json" ".signum/cache/style-profile-b.json" ".signum/cache/file-digests-b.json" ".signum/cache/file-extracts-b.json" --previous-extracts ".signum/cache/file-extracts-a.json" --max-file-size 64; then
  pass "skipped-file reuse run exits 0"
else
  fail "skipped-file reuse run exits 0" "command failed"
fi
assert_json "generated vendor binary and oversized behavior is unchanged" \
  "$PROJECT_H" \
  'extracts = data[0]
files = extracts["files"]
assert "vendor/ignored.ts" not in files, "vendor file should be ignored"
assert files["src/generated.ts"]["indexed"] is False and files["src/generated.ts"]["reason"] == "generated", "generated skip"
assert files["src/binary.dat"]["indexed"] is False and files["src/binary.dat"]["reason"] == "binary", "binary skip"
assert files["src/oversized.ts"]["indexed"] is False and files["src/oversized.ts"]["reason"] == "oversized", "oversized skip"
for path in ("src/generated.ts", "src/binary.dat", "src/oversized.ts"):
    assert files[path]["symbols"] == [], f"skipped symbols in {path}"' \
  "$PROJECT_H/.signum/cache/file-extracts-b.json"

echo ""
echo "=== Proofpack/cache exclusion and determinism ==="
if grep -Fq 'file-extracts-v1.json' "$ROOT_DIR/commands/signum.fragments/100-phase-pack.md" "$ROOT_DIR/platforms/claude-code/commands/signum.fragments/100-phase-pack.md"; then
  fail "PACK fragments exclude extraction cache" "file-extracts-v1.json appears in PACK fragment"
else
  pass "PACK fragments exclude extraction cache"
fi
PROJECT_J="$(make_project deterministic)"
run_scanner "$PROJECT_J" ".signum/cache/codebase-index-a.json" ".signum/cache/style-profile-a.json" ".signum/cache/file-digests-a.json" ".signum/cache/file-extracts-a.json"
run_scanner "$PROJECT_J" ".signum/cache/codebase-index-b.json" ".signum/cache/style-profile-b.json" ".signum/cache/file-digests-b.json" ".signum/cache/file-extracts-b.json"
if cmp -s "$PROJECT_J/.signum/cache/file-extracts-a.json" "$PROJECT_J/.signum/cache/file-extracts-b.json"; then
  pass "extraction cache is byte-stable with fixed generatedAt"
else
  fail "extraction cache is byte-stable with fixed generatedAt" "$(diff -u "$PROJECT_J/.signum/cache/file-extracts-a.json" "$PROJECT_J/.signum/cache/file-extracts-b.json" || true)"
fi

echo ""
printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: Codebase Awareness extraction cache reuses unchanged indexed payloads honestly"
