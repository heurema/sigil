#!/usr/bin/env bash
# run-cleanroom-smoke.sh -- validate deterministic release/package smoke from a clean source copy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANROOM_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/signum-cleanroom.XXXXXX")"
CLEANROOM="$CLEANROOM_PARENT/source"
MARKETPLACE_PATH="$CLEANROOM_PARENT/marketplace.json"

cleanup() {
  if [ "${SIGNUM_KEEP_CLEANROOM:-0}" = "1" ]; then
    echo "Keeping clean-room path: $CLEANROOM"
  else
    rm -rf "$CLEANROOM_PARENT"
  fi
}
trap cleanup EXIT

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: $tool" >&2
    exit 1
  fi
}

run_cleanroom_step() {
  local label="$1"
  shift
  echo "== $label =="
  (
    cd "$CLEANROOM"
    env \
      -u EMPORIUM_SSH_KEY \
      -u ANTHROPIC_API_KEY \
      -u CLAUDE_API_KEY \
      -u CODEX_API_KEY \
      -u GEMINI_API_KEY \
      -u GOOGLE_API_KEY \
      -u OPENAI_API_KEY \
      SIGNUM_CLEANROOM_SMOKE_ACTIVE=1 \
      "$@"
  )
  echo ""
}

copy_cleanroom_source() {
  python3 - "$SOURCE_ROOT" "$CLEANROOM" <<'PY'
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1]).resolve()
dest = Path(sys.argv[2]).resolve()

raw = subprocess.check_output(
    ["git", "-C", str(source), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
)
paths = [item.decode("utf-8") for item in raw.split(b"\0") if item]

excluded_names = {
    ".git",
    ".DS_Store",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".tox",
    "__pycache__",
    "node_modules",
}


def is_local_artifact(rel: str) -> bool:
    path = Path(rel)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"ERROR: unsafe git path: {rel!r}")
    for part in path.parts:
        if part in excluded_names:
            return True
        if part.startswith(".tmp-") or part.startswith("tmp-"):
            return True
    return False

copied = 0
seen: set[str] = set()
for rel in paths:
    if rel in seen or is_local_artifact(rel):
        continue
    seen.add(rel)
    src = source / rel
    dst = dest / rel
    try:
        st = os.lstat(src)
    except FileNotFoundError:
        print(f"WARN: tracked path missing in working tree, skipped: {rel}", file=sys.stderr)
        continue

    dst.parent.mkdir(parents=True, exist_ok=True)
    if stat.S_ISLNK(st.st_mode):
        target = os.readlink(src)
        if os.path.isabs(target):
            raise SystemExit(f"ERROR: absolute symlink target is not clean-room safe: {rel} -> {target}")
        os.symlink(target, dst)
        copied += 1
    elif stat.S_ISREG(st.st_mode):
        shutil.copy2(src, dst)
        copied += 1
    else:
        print(f"WARN: unsupported source file type, skipped: {rel}", file=sys.stderr)

print(copied)
PY
}

write_local_marketplace_fixture() {
  python3 - "$CLEANROOM/.claude-plugin/plugin.json" "$MARKETPLACE_PATH" <<'PY'
import json
import sys
from pathlib import Path

plugin_path = Path(sys.argv[1])
marketplace_path = Path(sys.argv[2])
plugin = json.loads(plugin_path.read_text(encoding="utf-8"))
name = plugin.get("name")
version = plugin.get("version")
if not name or not version:
    raise SystemExit(f"ERROR: missing name/version in {plugin_path}")
marketplace = {
    "plugins": [
        {
            "name": name,
            "version": version,
            "source": {
                "source": "url",
                "url": "https://github.com/heurema/signum.git",
                "ref": f"v{version}",
            },
        }
    ]
}
marketplace_path.write_text(json.dumps(marketplace, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

verify_required_source_surface() {
  local missing=0
  local required_paths=(
    ".claude-plugin/plugin.json"
    "commands/signum.md"
    "commands/signum.fragments/manifest.json"
    "commands/signum.shared.fragments/00-header.md"
    "platforms/claude-code/commands/signum.md"
    "platforms/claude-code/commands/signum.fragments/manifest.json"
    "scripts/render_signum_command.py"
    "platforms/claude-code/scripts/render_signum_command.py"
    "scripts/run-deterministic-tests.sh"
    "lib/release-smoke.sh"
    "lib/check-emporium-sync.sh"
    "lib/templates/signum-gate.yml"
    "platforms/claude-code/lib/templates/signum-gate.yml"
    "lib/templates/init-harness/agents.md.tmpl"
    "tests/test-signum-command-renderer.sh"
    "tests/test-signum-fragment-parity.sh"
    "tests/test-stabilization-summary.sh"
    "tests/test-release-smoke.sh"
    "docs/stabilization-summary.md"
    "tests/fixtures/stabilization-findings.json"
    "tests/fixtures/init-scanner/signum-state-project/.signum/policy.toml"
    "tests/fixtures/init-scanner/signum-state-project/.signum/project.glossary.json"
    "tests/fixtures/init-scanner/signum-state-project/.signum/project.intent.md"
  )

  for rel in "${required_paths[@]}"; do
    if [ ! -e "$CLEANROOM/$rel" ]; then
      echo "ERROR: clean-room copy missing required source path: $rel" >&2
      missing=$((missing + 1))
    fi
  done

  if [ "$missing" -gt 0 ]; then
    exit 1
  fi
}

for tool in bash python3 jq git; do
  require_tool "$tool"
done

mkdir -p "$CLEANROOM"
COPIED_COUNT="$(copy_cleanroom_source)"

if [ -d "$CLEANROOM/.git" ]; then
  echo "ERROR: .git directory was copied into clean-room source." >&2
  exit 1
fi

verify_required_source_surface
write_local_marketplace_fixture

echo "Source root: $SOURCE_ROOT"
echo "Clean-room path: $CLEANROOM"
echo "Copy strategy: git ls-files --cached --others --exclude-standard"
echo "Copied files: $COPIED_COUNT"
echo "Includes: tracked files + untracked non-ignored files"
echo "Excludes: .git, ignored files, caches, local temp artifacts"
echo "No .git directory copied"
echo "Secrets: not required"
echo "Network: not used by release smoke; local marketplace fixture is injected"
echo "External AI CLIs: not invoked"
echo "Checks: renderer, fragment parity, stabilization summary, release smoke local dry-run"
if [ "${SIGNUM_CLEANROOM_FULL:-0}" = "1" ]; then
  echo "Full deterministic suite: enabled"
else
  echo "Full deterministic suite: skipped (set SIGNUM_CLEANROOM_FULL=1 to enable)"
fi
echo ""

run_cleanroom_step "Command renderer" bash tests/test-signum-command-renderer.sh
run_cleanroom_step "Fragment parity" bash tests/test-signum-fragment-parity.sh
run_cleanroom_step "Stabilization summary" bash tests/test-stabilization-summary.sh
run_cleanroom_step \
  "Release smoke (local dry run)" \
  env \
    SIGNUM_RELEASE_DRY_RUN=1 \
    EMPORIUM_REPO="local/cleanroom" \
    EMPORIUM_GIT_REF="cleanroom" \
    EMPORIUM_PATH="marketplace.json" \
    EMPORIUM_MARKETPLACE_PATH="$MARKETPLACE_PATH" \
    bash lib/release-smoke.sh

if [ "${SIGNUM_CLEANROOM_FULL:-0}" = "1" ]; then
  run_cleanroom_step "Full deterministic suite" bash scripts/run-deterministic-tests.sh
fi

echo "Clean-room smoke passed."
