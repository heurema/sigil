#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'

const [uiSource, orchestratorSource, contractSource, executeSource, auditSource, packSource] = await Promise.all([
  readFile('platforms/pi/extensions/signum/ui.ts', 'utf8'),
  readFile('platforms/pi/extensions/signum/orchestrator.ts', 'utf8'),
  readFile('platforms/pi/extensions/signum/phases/contract.ts', 'utf8'),
  readFile('platforms/pi/extensions/signum/phases/execute.ts', 'utf8'),
  readFile('platforms/pi/extensions/signum/phases/audit.ts', 'utf8'),
  readFile('platforms/pi/extensions/signum/phases/pack.ts', 'utf8'),
])

assert.match(uiSource, /elapsed/)
assert.match(uiSource, /setStatus|heartbeat/)
assert.doesNotMatch(uiSource, /tool log|per-tool/)

for (const token of ['preflight', 'contract', 'execute', 'audit', 'pack']) {
  assert.match(orchestratorSource, new RegExp(token))
}
assert.doesNotMatch(orchestratorSource, /background job|queueWorker|detached/)

for (const token of ['workspace', 'contractor', 'validation', 'deterministic', 'approval']) {
  assert.match(contractSource, new RegExp(token))
}
assert.match(contractSource, new RegExp(String.raw`emitSignumMessage\([\s\S]{0,1200}runContractor\(`))

assert.match(executeSource, /execute/)
assert.match(auditSource, /audit/)
assert.match(packSource, /pack/)

console.log('PASS: pi progress visibility')
EOF
