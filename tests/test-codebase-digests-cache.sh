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

assert_digest() {
  local name="$1"
  local path="$2"
  local project="$3"
  local script="$4"
  if python3 - "$path" "$project" "$script" <<'PY'; then
import json
import sys
from pathlib import Path

digest_path = Path(sys.argv[1])
project = sys.argv[2]
script = sys.argv[3]
data = json.loads(digest_path.read_text(encoding="utf-8"))

errors = []
if data.get("schemaVersion") != "1.0":
    errors.append("schemaVersion")
if data.get("generatedAt") != "2026-01-01T00:00:00Z":
    errors.append("generatedAt")
if data.get("projectRoot") != ".":
    errors.append("projectRoot")
if data.get("scanMode") != "lexical-symbol":
    errors.append("scanMode")
files = data.get("files")
if not isinstance(files, dict) or not files:
    errors.append("files")
stats = data.get("scanStats")
if not isinstance(stats, dict):
    errors.append("scanStats")
else:
    for key in ("filesSeen", "filesIndexed", "filesReused", "filesSkipped", "bytesIndexed", "truncated"):
        if key not in stats:
            errors.append(f"scanStats.{key}")
if isinstance(files, dict):
    for key in files:
        if key.startswith("/") or project in key:
            errors.append(f"non-portable key {key}")
    if project in json.dumps(data):
        errors.append("temp project path leaked")

namespace = {"data": data, "files": files if isinstance(files, dict) else {}, "stats": stats if isinstance(stats, dict) else {}}
try:
    exec(script, namespace)
except AssertionError as exc:
    errors.append(str(exc))

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
    pass "$name"
  else
    fail "$name" "digest assertion failed"
  fi
}

echo "=== Digest artifact creation ==="
PROJECT_A="$(make_project artifact)"
if run_scanner "$PROJECT_A"; then
  pass "scanner writes digest artifact"
else
  fail "scanner writes digest artifact" "command failed"
fi

assert_digest "digest schema uses repo-relative indexed files" \
  "$PROJECT_A/.signum/cache/file-digests-v1.json" \
  "$PROJECT_A" \
  'assert "src/shared/validation.ts" in files, "missing validation digest"
assert files["src/shared/validation.ts"]["indexed"] is True, "validation not indexed"
assert files["src/shared/validation.ts"]["reason"] == "indexed", "validation reason"
assert stats["filesReused"] == 0, "filesReused not honest zero"'

echo ""
echo "=== Determinism ==="
PROJECT_B="$(make_project deterministic)"
if run_scanner "$PROJECT_B" --digests-output ".signum/cache/file-digests-a.json"; then
  pass "first deterministic digest run exits 0"
else
  fail "first deterministic digest run exits 0" "command failed"
fi
if run_scanner "$PROJECT_B" --digests-output ".signum/cache/file-digests-b.json"; then
  pass "second deterministic digest run exits 0"
else
  fail "second deterministic digest run exits 0" "command failed"
fi
if cmp -s "$PROJECT_B/.signum/cache/file-digests-a.json" "$PROJECT_B/.signum/cache/file-digests-b.json"; then
  pass "digest output is byte-stable with fixed generatedAt"
else
  fail "digest output is byte-stable with fixed generatedAt" "$(diff -u "$PROJECT_B/.signum/cache/file-digests-a.json" "$PROJECT_B/.signum/cache/file-digests-b.json" || true)"
fi

echo ""
echo "=== Ignore behavior ==="
PROJECT_C="$(make_project ignored)"
for dir in .git .signum node_modules dist build target .venv venv __pycache__ coverage .pytest_cache .mypy_cache bin obj; do
  mkdir -p "$PROJECT_C/$dir"
  printf 'export const ignored = true\n' > "$PROJECT_C/$dir/ignored.ts"
done
printf '// @generated\nexport const generatedValue = true\n' > "$PROJECT_C/src/generated.ts"
printf 'abc\000def\n' > "$PROJECT_C/src/binary.dat"
if run_scanner "$PROJECT_C"; then
  pass "scanner exits 0 with ignored directories present"
else
  fail "scanner exits 0 with ignored directories present" "command failed"
fi
assert_digest "ignored directories and generated/binary files are skipped" \
  "$PROJECT_C/.signum/cache/file-digests-v1.json" \
  "$PROJECT_C" \
  'ignored = (".git/", ".signum/", "node_modules/", "dist/", "build/", "target/", ".venv/", "venv/", "__pycache__/", "coverage/", ".pytest_cache/", ".mypy_cache/", "bin/", "obj/")
for key in files:
    assert not key.startswith(ignored), f"ignored path present: {key}"
assert "tests/shared/validation.test.ts" in files, "tests should not be skipped by default"
assert files["src/generated.ts"]["indexed"] is False, "generated file indexed"
assert files["src/generated.ts"]["reason"] == "generated", "generated reason"
assert files["src/binary.dat"]["indexed"] is False, "binary file indexed"
assert files["src/binary.dat"]["reason"] == "binary", "binary reason"'

echo ""
echo "=== Oversized file ==="
PROJECT_D="$(make_project oversized)"
printf 'export const oversizedValue = "%080d";\n' 1 > "$PROJECT_D/src/oversized.ts"
if run_scanner "$PROJECT_D" --max-file-size 16; then
  pass "scanner exits 0 with oversized file"
else
  fail "scanner exits 0 with oversized file" "command failed"
fi
assert_digest "oversized file is skipped and counted" \
  "$PROJECT_D/.signum/cache/file-digests-v1.json" \
  "$PROJECT_D" \
  'assert files["src/oversized.ts"]["indexed"] is False, "oversized indexed"
assert files["src/oversized.ts"]["reason"] == "oversized", "oversized reason"
assert stats["filesSkipped"] >= 1, "skipped count did not increase"'

echo ""
echo "=== Max files cap ==="
PROJECT_E="$(make_project max-files)"
if run_scanner "$PROJECT_E" --max-files 1; then
  pass "scanner exits 0 with max-files cap"
else
  fail "scanner exits 0 with max-files cap" "command failed"
fi
assert_digest "max-files cap marks scan truncated" \
  "$PROJECT_E/.signum/cache/file-digests-v1.json" \
  "$PROJECT_E" \
  'assert stats["truncated"] is True, "max-files did not truncate"
assert stats["filesIndexed"] == 1, "max-files indexed count"
assert any(item.get("reason") == "max-files" for item in files.values()), "missing max-files reason"'

echo ""
echo "=== Max bytes cap ==="
PROJECT_F="$(make_project max-bytes)"
if run_scanner "$PROJECT_F" --max-bytes 1; then
  pass "scanner exits 0 with max-bytes cap"
else
  fail "scanner exits 0 with max-bytes cap" "command failed"
fi
assert_digest "max-bytes cap marks scan truncated" \
  "$PROJECT_F/.signum/cache/file-digests-v1.json" \
  "$PROJECT_F" \
  'assert stats["truncated"] is True, "max-bytes did not truncate"
assert any(item.get("reason") == "max-bytes" for item in files.values()), "missing max-bytes reason"'

echo ""
echo "=== Previous digest input ==="
PROJECT_G="$(make_project previous)"
if run_scanner "$PROJECT_G" --digests-output ".signum/cache/first-digests.json"; then
  pass "initial previous-digest fixture run exits 0"
else
  fail "initial previous-digest fixture run exits 0" "command failed"
fi
if run_scanner "$PROJECT_G" --previous-digests ".signum/cache/first-digests.json"; then
  pass "previous digest input is accepted"
else
  fail "previous digest input is accepted" "command failed"
fi
assert_digest "previous digest input does not fake reuse" \
  "$PROJECT_G/.signum/cache/file-digests-v1.json" \
  "$PROJECT_G" \
  'assert stats["filesReused"] == 0, "filesReused should remain honest zero"'

echo ""
echo "=== Proofpack cache exclusion ==="
if grep -Fq 'file-digests-v1.json' "$ROOT_DIR/commands/signum.fragments/100-phase-pack.md" "$ROOT_DIR/platforms/claude-code/commands/signum.fragments/100-phase-pack.md"; then
  fail "PACK fragments exclude file digest cache" "file-digests-v1.json appears in PACK fragment"
else
  pass "PACK fragments exclude file digest cache"
fi

echo ""
echo "=== Invalid arguments ==="
PROJECT_H="$(make_project invalid-args)"
if run_scanner "$PROJECT_H" --max-files -1 >/dev/null 2>&1; then
  fail "negative max-files exits non-zero" "command unexpectedly succeeded"
else
  pass "negative max-files exits non-zero"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: codebase awareness digest cache is bounded and deterministic"
