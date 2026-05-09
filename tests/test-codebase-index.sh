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

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

PROJECT="$WORK/basic-mixed"
cp -R "$FIXTURE" "$PROJECT"

INDEX_A="$PROJECT/.signum/run-a/cache/codebase-index-v1.json"
STYLE_A="$PROJECT/.signum/run-a/cache/style-profile-v1.json"
DIGEST_A="$PROJECT/.signum/run-a/cache/file-digests-v1.json"
INDEX_B="$PROJECT/.signum/run-b/cache/codebase-index-v1.json"
STYLE_B="$PROJECT/.signum/run-b/cache/style-profile-v1.json"
DIGEST_B="$PROJECT/.signum/run-b/cache/file-digests-v1.json"
ALIAS_STYLE="$PROJECT/.signum/alias/style-profile-v1.json"

run_scanner() {
  local output="$1"
  local style_output="$2"
  local digests_output="$3"
  (
    cd "$PROJECT"
    python3 "$SCANNER" \
      --project-root "." \
      --output "$output" \
      --style-output "$style_output" \
      --digests-output "$digests_output" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

echo "=== Scanner run ==="
if run_scanner ".signum/run-a/cache/codebase-index-v1.json" ".signum/run-a/cache/style-profile-v1.json" ".signum/run-a/cache/file-digests-v1.json"; then
  pass "scanner exits 0"
else
  fail "scanner exits 0" "command failed"
fi

assert_file "codebase index created" "$INDEX_A"
assert_file "style profile created" "$STYLE_A"
assert_file "file digest cache created" "$DIGEST_A"

echo ""
echo "=== Artifact contract ==="
if python3 - "$INDEX_A" "$STYLE_A" "$DIGEST_A" "$PROJECT" <<'PY'
import json
import sys
from pathlib import Path

index = json.loads(Path(sys.argv[1]).read_text())
style = json.loads(Path(sys.argv[2]).read_text())
digests = json.loads(Path(sys.argv[3]).read_text())
project = sys.argv[4]

errors = []
required_index = (
    "schemaVersion",
    "generatedAt",
    "scanMode",
    "languageDetections",
    "manifests",
    "symbols",
    "imports",
    "tests",
    "sharedCandidates",
    "scanStats",
)
required_style = (
    "schemaVersion",
    "generatedAt",
    "confidence",
    "testConventions",
    "errorHandling",
    "logging",
    "config",
    "validation",
)
for section in required_index:
    if section not in index:
        errors.append(f"missing index section {section}")
for section in required_style:
    if section not in style:
        errors.append(f"missing style section {section}")
if index.get("schemaVersion") != "1.0":
    errors.append("index schemaVersion")
if style.get("schemaVersion") != "1.0":
    errors.append("style schemaVersion")
if digests.get("schemaVersion") != "1.0":
    errors.append("digest schemaVersion")
if index.get("scanMode") != "shallow-regex-v1":
    errors.append("scanMode")
if digests.get("scanMode") != "lexical-symbol":
    errors.append("digest scanMode")
if not isinstance(index.get("languageDetections"), list) or not index["languageDetections"]:
    errors.append("languageDetections")
if not isinstance(index.get("scanStats"), dict) or index["scanStats"].get("fileCount", 0) <= 0:
    errors.append("scanStats")
if not isinstance(style.get("confidence"), (int, float)):
    errors.append("style confidence")
if not isinstance(digests.get("files"), dict) or not digests["files"]:
    errors.append("digest files")
if digests.get("scanStats", {}).get("filesReused") != 0:
    errors.append("digest filesReused")
if not any(item.get("path") == "src/shared/validation.ts" for item in index.get("sharedCandidates", [])):
    errors.append("shared validation candidate")
if not any(item.get("name") == "validateEmail" and item.get("path") == "src/shared/validation.ts" for item in index.get("symbols", [])):
    errors.append("validateEmail symbol")
if not any(item.get("resolvedPath") == "src/shared/validation.ts" for item in index.get("imports", [])):
    errors.append("resolved local import")
if not any(item.get("resolvedPath") == "src/shared/esm-helper.mjs" for item in index.get("imports", [])):
    errors.append("resolved extensionless mjs import")
if not any(item.get("path") == "tests/shared/validation.test.ts" for item in index.get("tests", [])):
    errors.append("validation test entry")
if not any(item.get("language") == "typescript" for item in index.get("languageDetections", [])):
    errors.append("typescript language detection")
if not any(item.get("language") == "python" for item in index.get("languageDetections", [])):
    errors.append("python language detection")
if not style.get("testConventions"):
    errors.append("test conventions")
if not style.get("validation"):
    errors.append("validation style conventions")
if project in json.dumps(index) or project in json.dumps(style) or project in json.dumps(digests):
    errors.append("scanner artifacts leaked temp project path")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "scanner artifact schema and key signals are valid"
else
  fail "scanner artifact schema and key signals are valid" "Python assertion failed"
fi

echo ""
echo "=== Determinism ==="
if run_scanner ".signum/run-b/cache/codebase-index-v1.json" ".signum/run-b/cache/style-profile-v1.json" ".signum/run-b/cache/file-digests-v1.json"; then
  pass "second scanner run exits 0"
else
  fail "second scanner run exits 0" "command failed"
fi

if cmp -s "$INDEX_A" "$INDEX_B"; then
  pass "codebase index is byte-stable with fixed generatedAt"
else
  fail "codebase index is byte-stable with fixed generatedAt" "$(diff -u "$INDEX_A" "$INDEX_B" || true)"
fi

if cmp -s "$STYLE_A" "$STYLE_B"; then
  pass "style profile is byte-stable with fixed generatedAt"
else
  fail "style profile is byte-stable with fixed generatedAt" "$(diff -u "$STYLE_A" "$STYLE_B" || true)"
fi

if cmp -s "$DIGEST_A" "$DIGEST_B"; then
  pass "file digest cache is byte-stable with fixed generatedAt"
else
  fail "file digest cache is byte-stable with fixed generatedAt" "$(diff -u "$DIGEST_A" "$DIGEST_B" || true)"
fi

echo ""
echo "=== CLI compatibility ==="
if (
  cd "$PROJECT"
  python3 "$SCANNER" \
    --project-root "." \
    --output ".signum/alias/codebase-index-v1.json" \
    --style-profile ".signum/alias/style-profile-v1.json" \
    --generated-at "2026-01-01T00:00:00Z"
); then
  pass "legacy --style-profile scanner alias still works"
else
  fail "legacy --style-profile scanner alias still works" "command failed"
fi
assert_file "legacy style alias wrote output" "$ALIAS_STYLE"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: codebase awareness scanner artifacts are deterministic"
