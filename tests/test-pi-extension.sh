#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/platforms/pi/extensions/signum/index.ts"
PI_NODE_MODULES="$(npm root -g)"
PI_AI_NODE_MODULES="$PI_NODE_MODULES/@mariozechner/pi-coding-agent/node_modules"
CREATED_ROOT_NODE_MODULES=0
CREATED_SCOPE_DIR=0
CREATED_PI_AGENT_LINK=0
CREATED_PI_AI_LINK=0

passed=0
failed=0

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if printf '%s' "$haystack" | grep -q -- "$needle"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected to find "%s"\n' "$name" "$needle"
    printf '    actual: %s\n' "$haystack"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if printf '%s' "$haystack" | grep -q -- "$needle"; then
    printf '  FAIL: %s — did not expect to find "%s"\n' "$name" "$needle"
    printf '    actual: %s\n' "$haystack"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

run_pi() {
  local cwd="$1"
  local command="$2"
  (
    cd "$cwd"
    PI_SKIP_VERSION_CHECK=1 pi --no-extensions -e "$EXT" --mode json --no-session "$command"
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

extract_details() {
  python3 -c 'import json,sys
payload={}
for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    obj=json.loads(line)
    if obj.get("type") == "message_end":
        msg=obj.get("message", {})
        if msg.get("customType") == "signum":
            payload=msg.get("details", {})
print(json.dumps(payload, sort_keys=True))'
}

cleanup() {
  rm -rf "$WORK"
  if [ "$CREATED_PI_AGENT_LINK" -eq 1 ]; then rm -f "$ROOT/node_modules/@mariozechner/pi-coding-agent"; fi
  if [ "$CREATED_PI_AI_LINK" -eq 1 ]; then rm -f "$ROOT/node_modules/@mariozechner/pi-ai"; fi
  if [ "$CREATED_SCOPE_DIR" -eq 1 ]; then rmdir "$ROOT/node_modules/@mariozechner" 2>/dev/null || true; fi
  if [ "$CREATED_ROOT_NODE_MODULES" -eq 1 ]; then rmdir "$ROOT/node_modules" 2>/dev/null || true; fi
}

WORK="$(mktemp -d)"
trap cleanup EXIT

if [ ! -d "$ROOT/node_modules" ]; then
  mkdir -p "$ROOT/node_modules"
  CREATED_ROOT_NODE_MODULES=1
fi
if [ ! -d "$ROOT/node_modules/@mariozechner" ]; then
  mkdir -p "$ROOT/node_modules/@mariozechner"
  CREATED_SCOPE_DIR=1
fi
if [ ! -e "$ROOT/node_modules/@mariozechner/pi-coding-agent" ]; then
  ln -s "$PI_NODE_MODULES/@mariozechner/pi-coding-agent" "$ROOT/node_modules/@mariozechner/pi-coding-agent"
  CREATED_PI_AGENT_LINK=1
fi
if [ ! -e "$ROOT/node_modules/@mariozechner/pi-ai" ]; then
  ln -s "$PI_AI_NODE_MODULES/@mariozechner/pi-ai" "$ROOT/node_modules/@mariozechner/pi-ai"
  CREATED_PI_AI_LINK=1
fi

echo "=== /signum explain ==="
EXPLAIN_OUTPUT="$(run_pi "$ROOT" '/signum explain' | extract_content)"
assert_contains "explain reports slice-6" "$EXPLAIN_OUTPUT" '"status": "slice-6"'
assert_contains "explain reports full pipeline task" "$EXPLAIN_OUTPUT" '"status": "full-pipeline-bounded-iterative-audit"'

echo ""
echo "=== /signum close ==="
CLOSE_DIR="$WORK/close"
mkdir -p "$CLOSE_DIR/.signum/contracts/sig-20260421-test/reviews"
cat > "$CLOSE_DIR/.signum/contracts/index.json" <<'EOF'
{
  "activeContractId": "sig-20260421-test",
  "contracts": [
    {
      "contractId": "sig-20260421-test",
      "status": "active",
      "directory": ".signum/contracts/sig-20260421-test/"
    }
  ]
}
EOF
CLOSE_OUTPUT="$(run_pi "$CLOSE_DIR" '/signum close sig-20260421-test' | extract_content)"
assert_contains "close reports closed contract" "$CLOSE_OUTPUT" 'Closed: sig-20260421-test'
assert_contains "close clears active contract" "$(cat "$CLOSE_DIR/.signum/contracts/index.json")" '"activeContractId": null'


echo ""
echo "=== /signum archive ==="
ARCHIVE_DIR="$WORK/archive"
mkdir -p "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/reviews" "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/receipts"
printf '{"ok":true}\n' > "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/contract.json"
printf '{"proof":true}\n' > "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/proofpack.json"
printf '{"approval":true}\n' > "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/approval.json"
printf '{"audit":true}\n' > "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/audit_summary.json"
printf '{"receipt":true}\n' > "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/receipts/execute.json"
printf 'temp\n' > "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch/baseline.json"
cat > "$ARCHIVE_DIR/.signum/contracts/index.json" <<'EOF'
{
  "activeContractId": "sig-20260421-arch",
  "contracts": [
    {
      "contractId": "sig-20260421-arch",
      "status": "active",
      "directory": ".signum/contracts/sig-20260421-arch/"
    }
  ]
}
EOF
ARCHIVE_OUTPUT="$(run_pi "$ARCHIVE_DIR" '/signum archive sig-20260421-arch' | extract_content)"
assert_contains "archive reports archived contract" "$ARCHIVE_OUTPUT" 'Archived: sig-20260421-arch'
assert_contains "archive kept proofpack" "$(find "$ARCHIVE_DIR/.signum/archive" -type f | sort)" 'proofpack.json'
assert_not_contains "archive purged baseline" "$(find "$ARCHIVE_DIR/.signum/contracts/sig-20260421-arch" -maxdepth 2 -type f | sort)" 'baseline.json'


echo ""
echo "=== execute artifact reuse ==="
REUSE_OUTPUT="$(node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { mkdtemp } from 'node:fs/promises'
import { readExecuteSuccess } from './platforms/pi/extensions/signum/orchestrator.ts'

const root = await mkdtemp(join(tmpdir(), 'signum-execute-reuse-'))
await mkdir(join(root, '.signum', 'contracts'), { recursive: true })
await mkdir(join(root, '.signum', 'receipts'), { recursive: true })

await writeFile(join(root, '.signum', 'execute_log.json'), JSON.stringify({ status: 'SUCCESS' }))
await writeFile(join(root, '.signum', 'contract.json'), JSON.stringify({ contractId: 'sig-new' }))
await writeFile(join(root, '.signum', 'contracts', 'index.json'), JSON.stringify({ activeContractId: 'sig-new' }))
await writeFile(join(root, '.signum', 'receipts', 'execute.json'), JSON.stringify({ contract_id: 'sig-old' }))
assert.equal(await readExecuteSuccess(root), false)
console.log('PASS: stale execute artifacts do not reuse for new contract')

await writeFile(join(root, '.signum', 'receipts', 'execute.json'), JSON.stringify({ contract_id: 'sig-new' }))
assert.equal(await readExecuteSuccess(root), true)
console.log('PASS: same-contract execute artifacts still reuse')
EOF
)"
assert_contains "stale execute artifacts do not reuse for new contract" "$REUSE_OUTPUT" 'PASS: stale execute artifacts do not reuse for new contract'
assert_contains "same-contract execute artifacts still reuse" "$REUSE_OUTPUT" 'PASS: same-contract execute artifacts still reuse'

echo ""
echo "=== Results ==="
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
