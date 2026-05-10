#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
ADAPTER_DIR="$ROOT_DIR/scripts/codebase_awareness/adapters"
BUILD_INDEX="$ROOT_DIR/scripts/codebase_awareness/build_index.py"

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

echo "=== Adapter module layout ==="
assert_file "adapter package exists" "$ADAPTER_DIR/__init__.py"
assert_file "common adapter helpers exist" "$ADAPTER_DIR/common.py"
assert_file "Go adapter exists" "$ADAPTER_DIR/go.py"
assert_file "Rust adapter exists" "$ADAPTER_DIR/rust.py"
assert_file "C# adapter exists" "$ADAPTER_DIR/csharp.py"
assert_file "TypeScript/JavaScript adapter exists" "$ADAPTER_DIR/typescript_js.py"
assert_file "Python adapter exists" "$ADAPTER_DIR/python.py"

if grep -Eq 'from scripts\.codebase_awareness\.adapters import csharp, go, python, rust, typescript_js' "$BUILD_INDEX"; then
  pass "build_index imports language adapters"
else
  fail "build_index imports language adapters" "adapter import missing"
fi

if python3 - "$ADAPTER_DIR" <<'PY'
import ast
import sys
from pathlib import Path

root = Path(sys.argv[1])
allowed_roots = {
    "__future__",
    "collections",
    "configparser",
    "pathlib",
    "re",
    "scripts",
    "tomllib",
    "typing",
    "xml",
    "json",
}
errors = []
for path in sorted(root.glob("*.py")):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                root_name = alias.name.split(".", 1)[0]
                if root_name not in allowed_roots:
                    errors.append(f"{path.name}: import {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            root_name = module.split(".", 1)[0]
            if root_name and root_name not in allowed_roots:
                errors.append(f"{path.name}: from {module} import ...")
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
PY
then
  pass "adapters use only stdlib and local scanner helpers"
else
  fail "adapters use only stdlib and local scanner helpers" "unexpected import found"
fi

if python3 - "$ADAPTER_DIR" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
pattern = re.compile(r"subprocess|os\.system|os\.popen|Popen|check_call|check_output|execv|spawn")
errors = []
for path in sorted(root.glob("*.py")):
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if pattern.search(line):
            errors.append(f"{path.name}:{line_number}: {line.strip()}")
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
PY
then
  pass "adapters do not invoke external commands"
else
  fail "adapters do not invoke external commands" "process execution API found"
fi

if python3 - "$ADAPTER_DIR" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
pattern = re.compile(r"go list|cargo metadata|msbuild|nuget|roslyn|tree-sitter|typescript compiler|tsc\s|npm\s|pnpm\s|yarn\s|node\s")
errors = []
for path in sorted(root.glob("*.py")):
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if pattern.search(line):
            errors.append(f"{path.name}:{line_number}: {line.strip()}")
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
PY
then
  pass "adapters avoid banned external tooling strings"
else
  fail "adapters avoid banned external tooling strings" "banned tooling string found"
fi

echo ""
echo "=== Existing language coverage hooks ==="
for test_file in \
  "$ROOT_DIR/tests/test-codebase-go-adapter.sh" \
  "$ROOT_DIR/tests/test-codebase-rust-adapter.sh" \
  "$ROOT_DIR/tests/test-codebase-csharp-adapter.sh" \
  "$ROOT_DIR/tests/test-codebase-typescript-adapter.sh" \
  "$ROOT_DIR/tests/test-codebase-python-adapter.sh"
do
  if grep -Eq 'sharedCandidates|moduleBoundaries|symbols|imports|tests' "$test_file" && grep -Eq 'SCANNER=' "$test_file"; then
    pass "$(basename "$test_file") exercises scanner output"
  else
    fail "$(basename "$test_file") exercises scanner output" "expected output assertions missing"
  fi
done

echo ""
echo "=== Scanner compile ==="
if python3 -m compileall -q "$ROOT_DIR/scripts/codebase_awareness" "$ROOT_DIR/scripts/build_codebase_index.py"; then
  pass "scanner and adapters compile"
else
  fail "scanner and adapters compile" "compileall failed"
fi

echo ""
printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: codebase awareness adapter module layout is stdlib-only and wired into build_index"
