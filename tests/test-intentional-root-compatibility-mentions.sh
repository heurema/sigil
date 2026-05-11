#!/usr/bin/env bash
# test-intentional-root-compatibility-mentions.sh -- keep remaining root-path mentions explicit and intentional
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"

passed=0
failed=0

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_no_matches() {
  local label="$1"
  shift
  if "$@" >/tmp/test_out.$$ 2>&1; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s\n' "$label"
    sed 's/^/    /' /tmp/test_out.$$
    failed=$((failed + 1))
  fi
  rm -f /tmp/test_out.$$
}

assert_exact_file_set() {
  local label="$1"
  local actual expected
  actual="$2"
  expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s\n' "$label"
    printf '    expected:\n%s\n' "$expected"
    printf '    actual:\n%s\n' "$actual"
    failed=$((failed + 1))
  fi
}

# python_search: portable stdlib helper used in place of ripgrep below.
# Walks tracked + untracked-not-ignored files via `git ls-files`, applies
# negation globs (matching ripgrep's --glob '!pattern' semantics), searches for
# a regex, prints `./path` or `./path:line:content`, and exits 1 on
# assert-empty mode if any match is found. No external deps.
python_search() {
  ROOT_DIR="$ROOT_DIR" python3 - "$@" <<'PY'
import os
import re
import subprocess
import sys

mode = sys.argv[1]
pattern = sys.argv[2]
exclude_globs = sys.argv[3:]

root_dir = os.environ["ROOT_DIR"]
regex = re.compile(pattern)


def glob_to_regex(g):
    out = ""
    i = 0
    while i < len(g):
        if g[i:i + 3] == "**/":
            out += "(?:.*/)?"
            i += 3
        elif g[i:i + 2] == "**":
            out += ".*"
            i += 2
        elif g[i] == "*":
            out += "[^/]*"
            i += 1
        elif g[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(g[i])
            i += 1
    return re.compile("^" + out + "$")


excluders = []
for g in exclude_globs:
    if not g.startswith("!"):
        sys.stderr.write(f"python_search: only negation globs supported, got: {g!r}\n")
        sys.exit(2)
    excluders.append(glob_to_regex(g[1:]))


def excluded(path):
    return any(rx.match(path) for rx in excluders)


def list_via_git():
    if not os.path.isdir(os.path.join(root_dir, ".git")):
        return None
    try:
        ls = subprocess.run(
            ["git", "-C", root_dir, "ls-files", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    return [f for f in ls.stdout.splitlines() if f]


def list_via_walk():
    out = []
    for dirpath, dirnames, filenames in os.walk(root_dir):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root_dir)
            out.append(rel.replace(os.sep, "/"))
    return out


tracked = list_via_git()
if tracked is None:
    tracked = list_via_walk()
candidates = sorted({f for f in tracked if f and not excluded(f)})

list_hits = []
match_lines = []
for rel in candidates:
    full = os.path.join(root_dir, rel)
    if not os.path.isfile(full):
        continue
    try:
        with open(full, "rb") as fh:
            data = fh.read()
    except OSError:
        continue
    if b"\x00" in data:
        continue
    text = data.decode("utf-8", errors="replace")
    matched_in_file = False
    for line_no, line in enumerate(text.splitlines(), 1):
        if regex.search(line):
            if mode == "list":
                if not matched_in_file:
                    list_hits.append(rel)
                    matched_in_file = True
                break
            elif mode == "assert-empty":
                match_lines.append((rel, line_no, line))

if mode == "list":
    for rel in list_hits:
        print(f"./{rel}")
    sys.exit(0)
elif mode == "assert-empty":
    if match_lines:
        for rel, line_no, line in match_lines:
            print(f"./{rel}:{line_no}:{line}")
        sys.exit(1)
    sys.exit(0)
else:
    sys.stderr.write(f"python_search: unknown mode: {mode}\n")
    sys.exit(2)
PY
}

echo "=== Intentional root compatibility mentions ==="

CONTRACT_HITS="$(
  python_search list '\.signum/contract\.json' \
    '!**/tests/**' \
    '!commands/signum.md' \
    '!commands/signum.fragments/**' \
    '!platforms/claude-code/commands/signum.md' \
    '!platforms/claude-code/commands/signum.fragments/**' \
    '!docs/artifact-path-inventory.md' \
    '!lib/contract-injection-scan.sh' \
    '!platforms/claude-code/lib/signum-ci.sh' \
    '!lib/signum-ci.sh' \
    '!lib/snapshot-tree.sh' \
    '!lib/proofpack-index.sh'
)"

EXPECTED_CONTRACT_HITS=$'./README.md\n./agents/contractor.md\n./docs/migration-notes.md\n./docs/reference.md\n./platforms/claude-code/agents/contractor.md\n./platforms/claude-code/docs/reference.md'

assert_exact_file_set \
  "only intentional non-test root contract mentions remain" \
  "$CONTRACT_HITS" \
  "$EXPECTED_CONTRACT_HITS"

assert_contains "$ROOT_DIR/README.md" \
  'resume checks use the registry first, with root `.signum/contract.json` only as a legacy import signal' \
  "README frames root contract path as legacy import signal"
assert_contains "$ROOT_DIR/docs/reference.md" \
  'Root `.signum/contract.json` is only a legacy import signal' \
  "reference doc frames root contract path as legacy import signal"
assert_contains "$ROOT_DIR/docs/migration-notes.md" \
  'Root `.signum/contract.json` is only a legacy import or resume signal' \
  "migration notes frame root contract path as legacy import/resume signal"
assert_contains "$ROOT_DIR/platforms/claude-code/docs/reference.md" \
  'Root `.signum/contract.json` is only a legacy import signal' \
  "overlay reference doc frames root contract path as legacy import signal"
assert_contains "$ROOT_DIR/agents/contractor.md" \
  'Do not write root `.signum/contract.json`; that path is only a legacy import signal' \
  "root contractor prompt blocks root contract writes"
assert_contains "$ROOT_DIR/platforms/claude-code/agents/contractor.md" \
  'Do not write root `.signum/contract.json`; that path is only a legacy import signal' \
  "overlay contractor prompt blocks root contract writes"

assert_no_matches \
  "no stray root proofpack path remains outside legacy helpers and tests" \
  python_search assert-empty '\.signum/proofpack\.json' \
    '!**/tests/**' \
    '!commands/signum.md' \
    '!commands/signum.fragments/**' \
    '!platforms/claude-code/commands/signum.md' \
    '!platforms/claude-code/commands/signum.fragments/**' \
    '!docs/artifact-path-inventory.md' \
    '!lib/signum-ci.sh' \
    '!platforms/claude-code/lib/signum-ci.sh' \
    '!lib/proofpack-index.sh'

assert_no_matches \
  "no stray root audit-summary path remains outside commands and tests" \
  python_search assert-empty '\.signum/audit_summary\.json' \
    '!**/tests/**' \
    '!commands/signum.md' \
    '!commands/signum.fragments/**' \
    '!platforms/claude-code/commands/signum.md' \
    '!platforms/claude-code/commands/signum.fragments/**'

assert_no_matches \
  "no stray root baseline path remains outside commands and tests" \
  python_search assert-empty '\.signum/baseline\.json' \
    '!**/tests/**' \
    '!commands/signum.md' \
    '!commands/signum.fragments/**' \
    '!platforms/claude-code/commands/signum.md' \
    '!platforms/claude-code/commands/signum.fragments/**'

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [[ "$failed" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
