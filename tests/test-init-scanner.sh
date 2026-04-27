#!/usr/bin/env bash
# test-init-scanner.sh -- fixture/golden baseline for lib/init-scanner.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCANNER="$REPO_ROOT/lib/init-scanner.sh"
PY_SCANNER="$REPO_ROOT/scripts/init_scanner.py"
OVERLAY_SCANNER="$REPO_ROOT/platforms/claude-code/lib/init-scanner.sh"
OVERLAY_PY_SCANNER="$REPO_ROOT/platforms/claude-code/scripts/init_scanner.py"
FIXTURES="$REPO_ROOT/tests/fixtures/init-scanner"
DOC="$REPO_ROOT/docs/init-scanner-behavior.md"
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

assert_dir() {
  local name="$1" path="$2"
  if [ -d "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing directory $path"
  fi
}

assert_ok() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

assert_fail() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    fail "$name" "expected failure, got exit 0"
  else
    pass "$name"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s\n' "$haystack" | grep -q -- "$needle"; then
    pass "$name"
  else
    fail "$name" "expected to find $needle"
  fi
}

copy_fixture() {
  local fixture="$1" dest="$2"
  python3 - "$FIXTURES/$fixture" "$dest" <<'PY'
import shutil
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
if dst.exists():
    shutil.rmtree(dst)
shutil.copytree(src, dst)
PY
}

normalize_scan() {
  local input="$1" output="$2"
  python3 - "$input" "$output" <<'PY'
import json
import re
import sys
from pathlib import Path

input_path, output_path = map(Path, sys.argv[1:])
data = json.loads(input_path.read_text(encoding="utf-8"))

def sort_sections(value):
    if not isinstance(value, str) or not value:
        return value
    pattern = re.compile(r"\n=== ([^\n]+) ===\n")
    matches = list(pattern.finditer(value))
    if not matches:
        return value
    prefix = value[: matches[0].start()]
    sections = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(value)
        sections.append((match.group(1), value[match.start():end]))
    return prefix + "".join(section for _, section in sorted(sections, key=lambda item: item[0]))

data["scanTarget"] = "<PROJECT_ROOT>"
signals = data.get("signals", {})
for key in ("docs_deep", "ci_signals", "entrypoints"):
    signals[key] = sort_sections(signals.get(key, ""))

output_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

snapshot_tree() {
  local root="$1" output="$2"
  python3 - "$root" "$output" <<'PY'
import hashlib
import os
import sys
from pathlib import Path
root = Path(sys.argv[1])
output = Path(sys.argv[2])
rows = []
for path in sorted(root.rglob("*")):
    rel = path.relative_to(root).as_posix()
    if path.is_symlink():
        rows.append(f"L {rel} -> {os.readlink(path)}")
    elif path.is_file():
        rows.append(f"F {rel} {hashlib.sha256(path.read_bytes()).hexdigest()}")
output.write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8")
PY
}

run_scanner_case() {
  local fixture="$1"
  local case_dir="$WORK/$fixture"
  local root_raw="$WORK/$fixture.root.raw.json"
  local root_norm="$WORK/$fixture.root.norm.json"
  local overlay_raw="$WORK/$fixture.overlay.raw.json"
  local overlay_norm="$WORK/$fixture.overlay.norm.json"
  local py_raw="$WORK/$fixture.py.raw.json"
  local py_norm="$WORK/$fixture.py.norm.json"
  local overlay_py_raw="$WORK/$fixture.overlay.py.raw.json"
  local overlay_py_norm="$WORK/$fixture.overlay.py.norm.json"
  local before_tree="$WORK/$fixture.before.tree"
  local after_tree="$WORK/$fixture.after.tree"
  local expected="$FIXTURES/expected/$fixture.json"

  copy_fixture "$fixture" "$case_dir"
  snapshot_tree "$case_dir" "$before_tree"

  if bash "$SCANNER" --project-root "$case_dir" > "$root_raw" 2>"$WORK/$fixture.root.stderr"; then
    pass "$fixture root scanner exits 0"
  else
    fail "$fixture root scanner exits 0" "$(cat "$WORK/$fixture.root.stderr")"
    return
  fi
  normalize_scan "$root_raw" "$root_norm"

  if jq -e '.schemaVersion == "1.0" and (.signals|type == "object") and (.signals.go_mod|type == "string") and (.existingFiles|type == "object") and (.glossarySchema.canonicalTerms|type == "array") and (.glossarySchema.aliases|type == "object")' "$root_raw" >/dev/null; then
    pass "$fixture output shape is valid"
  else
    fail "$fixture output shape is valid" "jq contract failed"
  fi

  if diff -u "$expected" "$root_norm" > "$WORK/$fixture.diff"; then
    pass "$fixture normalized output matches golden"
  else
    fail "$fixture normalized output matches golden" "$(cat "$WORK/$fixture.diff")"
  fi

  if bash "$OVERLAY_SCANNER" --project-root "$case_dir" > "$overlay_raw" 2>"$WORK/$fixture.overlay.stderr"; then
    pass "$fixture overlay scanner exits 0"
  else
    fail "$fixture overlay scanner exits 0" "$(cat "$WORK/$fixture.overlay.stderr")"
    return
  fi
  normalize_scan "$overlay_raw" "$overlay_norm"

  if diff -u "$root_norm" "$overlay_norm" > "$WORK/$fixture.overlay.diff"; then
    pass "$fixture root and overlay normalized output match"
  else
    fail "$fixture root and overlay normalized output match" "$(cat "$WORK/$fixture.overlay.diff")"
  fi

  if python3 "$PY_SCANNER" --project-root "$case_dir" > "$py_raw" 2>"$WORK/$fixture.py.stderr"; then
    pass "$fixture direct Python scanner exits 0"
  else
    fail "$fixture direct Python scanner exits 0" "$(cat "$WORK/$fixture.py.stderr")"
    return
  fi
  normalize_scan "$py_raw" "$py_norm"

  if diff -u "$root_norm" "$py_norm" > "$WORK/$fixture.py.diff"; then
    pass "$fixture wrapper and direct Python output match"
  else
    fail "$fixture wrapper and direct Python output match" "$(cat "$WORK/$fixture.py.diff")"
  fi

  if python3 "$OVERLAY_PY_SCANNER" --project-root "$case_dir" > "$overlay_py_raw" 2>"$WORK/$fixture.overlay.py.stderr"; then
    pass "$fixture direct overlay Python scanner exits 0"
  else
    fail "$fixture direct overlay Python scanner exits 0" "$(cat "$WORK/$fixture.overlay.py.stderr")"
    return
  fi
  normalize_scan "$overlay_py_raw" "$overlay_py_norm"

  if diff -u "$root_norm" "$overlay_py_norm" > "$WORK/$fixture.overlay.py.diff"; then
    pass "$fixture root wrapper and overlay Python output match"
  else
    fail "$fixture root wrapper and overlay Python output match" "$(cat "$WORK/$fixture.overlay.py.diff")"
  fi

  snapshot_tree "$case_dir" "$after_tree"
  if diff -u "$before_tree" "$after_tree" > "$WORK/$fixture.tree.diff"; then
    pass "$fixture scanner does not mutate project files"
  else
    fail "$fixture scanner does not mutate project files" "$(cat "$WORK/$fixture.tree.diff")"
  fi
}

echo "=== Init scanner wiring ==="
assert_file "root init scanner exists" "$SCANNER"
assert_file "root Python init scanner exists" "$PY_SCANNER"
assert_file "overlay init scanner exists" "$OVERLAY_SCANNER"
assert_file "overlay Python init scanner exists" "$OVERLAY_PY_SCANNER"
assert_file "behavior doc exists" "$DOC"
assert_ok "overlay init scanner mirrors root" cmp -s "$SCANNER" "$OVERLAY_SCANNER"
assert_ok "overlay Python init scanner mirrors root" cmp -s "$PY_SCANNER" "$OVERLAY_PY_SCANNER"
assert_ok "root scanner syntax is valid" bash -n "$SCANNER"
assert_ok "overlay scanner syntax is valid" bash -n "$OVERLAY_SCANNER"
assert_ok "root Python scanner compiles" python3 -m py_compile "$PY_SCANNER"
assert_ok "overlay Python scanner compiles" python3 -m py_compile "$OVERLAY_PY_SCANNER"

if grep -q 'exec python3 "$PYTHON_SCANNER" "$@"' "$SCANNER" \
  && grep -q 'scripts/init_scanner.py' "$DOC" \
  && ! grep -q 'AUTHORITATIVE_DOCS=' "$SCANNER" \
  && ! grep -q 'jq -n' "$SCANNER"; then
  pass "shell wrapper is thin and delegates to Python"
else
  fail "shell wrapper is thin and delegates to Python" "wrapper still contains scanning/json construction logic"
fi

for fixture in \
  minimal-empty-project \
  docs-rich-project \
  manifest-project \
  signum-state-project \
  noisy-ignored-project; do
  assert_dir "fixture exists: $fixture" "$FIXTURES/$fixture"
  assert_file "golden exists: $fixture" "$FIXTURES/expected/$fixture.json"
done

echo ""
echo "=== Golden fixture behavior ==="
for fixture in \
  minimal-empty-project \
  docs-rich-project \
  manifest-project \
  signum-state-project \
  noisy-ignored-project; do
  run_scanner_case "$fixture"
done

echo ""
echo "=== Focused behavior assertions ==="
DOCS_RICH="$WORK/docs-rich-project.root.norm.json"
assert_contains "docs-rich captures README negative signal" "$(jq -r '.signals.readme_negative' "$DOCS_RICH")" "Limitations"
assert_contains "docs-rich captures rejected ADR" "$(jq -r '.signals.adr_signals' "$DOCS_RICH")" "REJECTED ADR"
assert_contains "docs-rich captures CLAUDE negative signal" "$(jq -r '.signals.claude_negative' "$DOCS_RICH")" "Non-goals"

MANIFEST="$WORK/manifest-project.root.norm.json"
assert_contains "manifest captures package.json" "$(jq -r '.signals.package_json' "$MANIFEST")" "manifest-project"
assert_contains "manifest captures package bin" "$(jq -r '.signals.pkg_bin' "$MANIFEST")" "manifest-cli"
assert_contains "manifest captures pyproject scripts" "$(jq -r '.signals.console_scripts' "$MANIFEST")" "manifest-py"
assert_contains "manifest captures Cargo.toml" "$(jq -r '.signals.cargo_toml' "$MANIFEST")" "manifest-project"
assert_contains "manifest captures go.mod" "$(jq -r '.signals.go_mod' "$MANIFEST")" "module example.com/manifest-project"

SIGNUM_STATE="$WORK/signum-state-project.root.norm.json"
assert_contains "signum-state reads legacy glossary fallback" "$(jq -r '.existingFiles.glossary.path' "$SIGNUM_STATE")" ".signum/project.glossary.json"
assert_contains "signum-state reads legacy intent fallback" "$(jq -r '.existingFiles.intent.path' "$SIGNUM_STATE")" ".signum/project.intent.md"

NOISY="$WORK/noisy-ignored-project.root.norm.json"
NOISY_FULL=$(cat "$NOISY")
if printf '%s\n' "$NOISY_FULL" | grep -qE 'NODE_MODULE_SHOULD_NOT_APPEAR|DIST_SHOULD_NOT_APPEAR|BUILD_SHOULD_NOT_APPEAR|VENV_SHOULD_NOT_APPEAR|PYCACHE_SHOULD_NOT_APPEAR|COVERAGE_SHOULD_NOT_APPEAR|TEST_FIXTURE_SHOULD_NOT_APPEAR'; then
  fail "ignored noisy files are absent from normalized output" "ignored marker leaked"
else
  pass "ignored noisy files are absent from normalized output"
fi
NOISY_MODULE_DIRS=$(jq -r '.signals.module_dirs' "$NOISY")
assert_contains "module_dirs still includes legitimate src dir" "$NOISY_MODULE_DIRS" "src"
if jq -e '.signals.module_dirs | split(" ") | map(select(length > 0)) | index("tests") | not' "$NOISY" >/dev/null; then
  pass "module_dirs excludes top-level tests dir"
else
  fail "module_dirs excludes top-level tests dir" "$(jq -r '.signals.module_dirs' "$NOISY")"
fi

SYMLINK_CASE="$WORK/symlink-project"
mkdir -p "$SYMLINK_CASE"
printf '# Symlinked README\n\nCurrent behavior follows file symlinks.\n' > "$SYMLINK_CASE/README.source.md"
ln -s README.source.md "$SYMLINK_CASE/README.md"
bash "$SCANNER" --project-root "$SYMLINK_CASE" > "$WORK/symlink.raw.json"
normalize_scan "$WORK/symlink.raw.json" "$WORK/symlink.norm.json"
assert_contains "scanner follows README symlink" "$(jq -r '.signals.readme' "$WORK/symlink.norm.json")" "Symlinked README"

GIT_CASE="$WORK/git-dirstat-project"
mkdir -p "$GIT_CASE/docs/adr" "$GIT_CASE/bin" "$GIT_CASE/commands"
printf '# Git dirstat project\n' > "$GIT_CASE/README.md"
printf 'how it works\n' > "$GIT_CASE/docs/how-it-works.md"
printf 'adr\n' > "$GIT_CASE/docs/adr/001.md"
printf '#!/usr/bin/env bash\n' > "$GIT_CASE/bin/cli"
printf 'command\n' > "$GIT_CASE/commands/demo.md"
printf '{"name":"git-dirstat-project"}\n' > "$GIT_CASE/package.json"
(
  cd "$GIT_CASE"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Signum Test"
  git add .
  git commit -q -m "fixture"
)
bash "$SCANNER" --project-root "$GIT_CASE" > "$WORK/git-dirstat.raw.json"
normalize_scan "$WORK/git-dirstat.raw.json" "$WORK/git-dirstat.norm.json"
python3 - "$WORK/git-dirstat.norm.json" <<'PY' > "$WORK/git-dirstat.paths"
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
lines = [line.split()[-1] for line in data["signals"]["git_dirstat"].splitlines() if line.strip()]
print("\n".join(lines))
PY
if diff -u <(printf '%s\n' "docs/adr/" "docs/" "commands/" "bin/") "$WORK/git-dirstat.paths" > "$WORK/git-dirstat.diff"; then
  pass "git dirstat preserves historical shell sort order"
else
  fail "git dirstat preserves historical shell sort order" "$(cat "$WORK/git-dirstat.diff")"
fi

assert_fail "unknown argument fails" bash "$SCANNER" --unknown
assert_fail "missing project root fails" bash "$SCANNER" --project-root "$WORK/does-not-exist"

if grep -q 'Python compatibility rewrite' "$DOC" && grep -q 'does not write project files' "$DOC" && grep -q '`go.mod`, first 50 lines' "$DOC" && grep -q 'Go checksum files such as `go.sum` are not captured' "$DOC"; then
  pass "behavior doc records baseline and limitations"
else
  fail "behavior doc records baseline and limitations" "missing expected wording"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
