#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PI_NODE_MODULES="/home/limerc/.local/share/mise/installs/node/25.9.0/lib/node_modules"
CREATED_ROOT_NODE_MODULES=0
CREATED_SCOPE_DIR=0
CREATED_PI_AGENT_LINK=0
CREATED_PI_AI_LINK=0

cleanup() {
  if [ "$CREATED_PI_AGENT_LINK" -eq 1 ]; then rm -f "$ROOT/node_modules/@mariozechner/pi-coding-agent"; fi
  if [ "$CREATED_PI_AI_LINK" -eq 1 ]; then rm -f "$ROOT/node_modules/@mariozechner/pi-ai"; fi
  if [ "$CREATED_SCOPE_DIR" -eq 1 ]; then rmdir "$ROOT/node_modules/@mariozechner" 2>/dev/null || true; fi
  if [ "$CREATED_ROOT_NODE_MODULES" -eq 1 ]; then rmdir "$ROOT/node_modules" 2>/dev/null || true; fi
}
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
  ln -s "$PI_NODE_MODULES/@mariozechner/pi-ai" "$ROOT/node_modules/@mariozechner/pi-ai"
  CREATED_PI_AI_LINK=1
fi

node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { normalizeContractForPiRuntime } from './platforms/pi/extensions/signum/runtime/verify-normalizer.ts'
import { deriveExecutionPolicy, isMutationPathAllowed, isReadablePathAllowed } from './platforms/pi/extensions/signum/runtime/policy-tools.ts'

const contract = normalizeContractForPiRuntime({
  contractId: 'sig-demo',
  riskLevel: 'medium',
  inScope: [
    'AUDIT phase changes in platforms/pi/extensions/signum/phases/audit.ts needed for iterative parity.',
    'PACK updates in platforms/pi/extensions/signum/phases/pack.ts to persist metadata.',
    'Targeted documentation updates in docs/reference.md and platforms/pi/README.md only.',
    'Tests under tests/ that verify the bounded loop.',
  ],
  allowNewFilesUnder: ['platforms/pi/extensions/signum/runtime/', 'tests/'],
  acceptanceCriteria: [],
})

const policy = deriveExecutionPolicy(contract)

assert(policy.allowed_paths.includes('platforms/pi/extensions/signum/phases/audit.ts'))
assert(policy.allowed_paths.includes('platforms/pi/extensions/signum/phases/pack.ts'))
assert(policy.allowed_paths.includes('docs/reference.md'))
assert(policy.allowed_paths.includes('platforms/pi/README.md'))
assert(policy.allowed_paths.includes('tests'))
assert(policy.allow_new_files_under.includes('platforms/pi/extensions/signum/runtime'))
assert(policy.allow_new_files_under.includes('tests'))
assert.equal(isReadablePathAllowed('platforms/pi/extensions/signum/phases/execute.ts'), true)
assert.equal(isMutationPathAllowed('tests/test-pi-extension.sh', true, policy), true)
assert.equal(isMutationPathAllowed('tests/test-pi-iterative-audit-parity.sh', false, policy), true)
assert.equal(isMutationPathAllowed('README.md', true, policy), false)

console.log('PASS: pi policy tools')
EOF
