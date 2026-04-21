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
import { classifyVerifyStrength } from './platforms/pi/extensions/signum/phases/execute.ts'

assert.equal(classifyVerifyStrength({ steps: [{ type: 'readFile', path: 'a.ts' }] }), 'observational')
assert.equal(classifyVerifyStrength({ steps: [{ type: 'assertContains', path: 'a.ts', text: 'x' }] }), 'observational')
assert.equal(classifyVerifyStrength({ steps: [{ type: 'gitDiffFiles' }] }), 'observational')
assert.equal(classifyVerifyStrength({ steps: [{ exec: { argv: ['grep', '-q', 'x', 'a.ts'] } }] }), 'predicate')
assert.equal(classifyVerifyStrength({ steps: [{ type: 'run', command: 'echo ok' }] }), 'exit_only')

console.log('PASS: pi execute verify classification')
EOF
