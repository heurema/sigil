#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PI_NODE_MODULES="$(npm root -g)"
CREATED_ROOT_NODE_MODULES=0
CREATED_SCOPE_DIR=0
CREATED_PI_AI_LINK=0

cleanup() {
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
if [ ! -e "$ROOT/node_modules/@mariozechner/pi-ai" ]; then
  ln -s "$PI_NODE_MODULES/@mariozechner/pi-ai" "$ROOT/node_modules/@mariozechner/pi-ai"
  CREATED_PI_AI_LINK=1
fi

node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { selectRoleModel } from './platforms/pi/extensions/signum/models.ts'

const anthropicCurrent = { provider: 'anthropic', id: 'claude-3-7-sonnet', name: 'Claude 3.7 Sonnet' }
const openaiStrong = { provider: 'openai', id: 'gpt-5', name: 'GPT-5' }
const openaiMini = { provider: 'openai', id: 'gpt-5-mini', name: 'GPT-5 Mini' }
const anthropicSmall = { provider: 'anthropic', id: 'claude-3-5-haiku', name: 'Claude 3.5 Haiku' }
const anthropicAlt = { provider: 'anthropic', id: 'claude-3-7-opus', name: 'Claude 3.7 Opus' }
const googleFlash = { provider: 'google', id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash' }

for (const role of ['contractor', 'engineer', 'synthesizer', 'reviewer-semantic']) {
  const selected = selectRoleModel(role, {
    currentModel: anthropicCurrent,
    availableModels: [openaiStrong, anthropicCurrent, googleFlash],
    preferredModelId: 'gpt-5',
  })
  assert.deepEqual(selected, anthropicCurrent)
}
console.log('PASS: current-model-first')

const sameProviderFallback = selectRoleModel('engineer', {
  currentModel: anthropicCurrent,
  availableModels: [anthropicAlt, openaiStrong, googleFlash],
  preferFallback: true,
})
assert.deepEqual(sameProviderFallback, anthropicAlt)

const contractorFallback = selectRoleModel('contractor', {
  currentModel: openaiStrong,
  availableModels: [openaiMini, googleFlash, anthropicSmall],
  preferFallback: true,
})
assert.deepEqual(contractorFallback, openaiMini)
console.log('PASS: same-provider fallback')

const auditSource = await readFile('./platforms/pi/extensions/signum/phases/audit.ts', 'utf8')
assert.match(auditSource, /function buildReviewPlan[\s\S]*pickAdditionalReviewerModel\(availableModels, \[semanticModel\], "reviewer-security"\)/)
assert.match(auditSource, /const sameProvider = used.length > 0 \? candidates.filter\(\(model\) => model.provider === used\[used.length - 1\]\?\.provider\) : \[\]/)
assert.match(auditSource, /pickByPatterns\(sameProvider, preferredPatterns\) \?\?\s+sameProvider\[0\] \?\?/)
console.log('PASS: provider-agnostic review model planning')
EOF
