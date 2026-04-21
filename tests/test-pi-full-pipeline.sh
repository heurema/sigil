#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/platforms/pi/extensions/signum/index.ts"

if [ "${SIGNUM_PI_LIVE_SMOKE:-0}" != "1" ]; then
  echo "SKIP: set SIGNUM_PI_LIVE_SMOKE=1 to run the live pi full-pipeline smoke test"
  exit 0
fi

run_pi() {
  local cwd="$1"
  local command="$2"
  (
    cd "$cwd"
    SIGNUM_PI_AUTO_APPROVE=1 PI_SKIP_VERSION_CHECK=1 \
      pi --no-extensions -e "$EXT" --mode json --no-session "$command"
  )
}

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/src"
cat > "$WORK/README.md" <<'EOF'
# Demo Project

Small demo app for testing pi-native Signum flow.
EOF
cat > "$WORK/package.json" <<'EOF'
{
  "name": "demo-project",
  "version": "1.0.0",
  "type": "module"
}
EOF
cat > "$WORK/src/index.js" <<'EOF'
export function greet(name) {
  return `Hello, ${name}`;
}
EOF

(
  cd "$WORK"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git add .
  git commit -qm init
)

echo "=== /signum full pipeline live smoke ==="
OUTPUT="$(run_pi "$WORK" '/signum add a README usage example and keep scope minimal' | extract_content)"
printf '%s\n' "$OUTPUT"

assert_file "$WORK/.signum/contract.json"
assert_file "$WORK/.signum/approval.json"
assert_file "$WORK/.signum/contract-policy.json"
assert_file "$WORK/.signum/execute_log.json"
assert_file "$WORK/.signum/receipts/execute.json"
assert_file "$WORK/.signum/mechanic_report.json"
assert_file "$WORK/.signum/policy_scan.json"
assert_file "$WORK/.signum/holdout_report.json"
assert_file "$WORK/.signum/reviews/claude.json"
assert_file "$WORK/.signum/audit_summary.json"
assert_file "$WORK/.signum/proofpack.json"
assert_file "$WORK/.signum/anti_entropy_report.json"

python3 - "$WORK" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
execute = json.load(open(root / '.signum/execute_log.json'))
audit = json.load(open(root / '.signum/audit_summary.json'))
proof = json.load(open(root / '.signum/proofpack.json'))
contract = json.load(open(root / '.signum/contract.json'))
readme = (root / 'README.md').read_text()

assert execute['status'] == 'SUCCESS', execute
assert audit['decision'] in {'AUTO_OK', 'HUMAN_REVIEW', 'AUTO_BLOCK'}, audit
assert proof['decision'] == audit['decision'], (proof, audit)
assert contract['status'] == 'completed', contract
assert 'greet' in readme and 'Usage' in readme, readme
print('PASS: live full-pipeline artifacts verified')
print('decision=', proof['decision'])
print('runId=', proof['runId'])
PY
