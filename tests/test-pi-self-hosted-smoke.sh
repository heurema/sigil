#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
EXT_REL="./platforms/pi/extensions/signum/index.ts"

if [ "${SIGNUM_PI_SELF_HOSTED_SMOKE:-0}" != "1" ]; then
  echo "SKIP: set SIGNUM_PI_SELF_HOSTED_SMOKE=1 to run the optional self-hosted pi regression smoke"
  exit 0
fi

extract_content() {
  python3 -c 'import json,sys
content=""
for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    obj=json.loads(line)
    if obj.get("type") == "message_end":
        msg=obj.get("message", {})
        if msg.get("customType") == "signum":
            content=msg.get("content", "")
print(content)'
}

assert_file() {
  local path="$1"
  [ -f "$path" ] || { echo "FAIL: missing file $path"; exit 1; }
}

TMP_REPO="$(mktemp -d "${TMPDIR:-/tmp}/signum-pi-self-hosted-smoke.XXXXXX")"
trap 'rm -rf "$TMP_REPO"' EXIT

cp -R "$ROOT/." "$TMP_REPO/"

(
  cd "$TMP_REPO"

  if [ ! -d .git ]; then
    echo "FAIL: temporary repo copy is missing .git metadata"
    exit 1
  fi

  before_tracked="$(git status --porcelain --untracked-files=no)"

  OUTPUT="$(SIGNUM_PI_AUTO_APPROVE=1 PI_SKIP_VERSION_CHECK=1 pi --no-extensions -e "$EXT_REL" --mode json --no-session '/signum produce only bounded CONTRACT and EXECUTE artifacts for this temporary smoke run; keep changes scoped to .signum outputs and do not modify source files' | extract_content)"
  printf '%s\n' "$OUTPUT"

  assert_file .signum/contract.json
  assert_file .signum/execute_log.json
  assert_file .signum/receipts/execute.json

  after_tracked="$(git status --porcelain --untracked-files=no)"
  if [ "$before_tracked" != "$after_tracked" ]; then
    echo "FAIL: self-hosted smoke mutated tracked files in the temporary repo copy"
    printf 'Tracked changes before run:\n%s\n' "$before_tracked"
    printf 'Tracked changes after run:\n%s\n' "$after_tracked"
    exit 1
  fi
)

echo "PASS: self-hosted CONTRACT and EXECUTE artifacts verified in temporary repo copy"
