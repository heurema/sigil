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
assert.match(uiSource, /(recent|events?)/)
assert.match(uiSource, /(phase|milestone)/)
assert.match(uiSource, /setStatus|heartbeat/)
assert.match(uiSource, /setWidget/)
assert.match(uiSource, /SIGNUM_PROGRESS_WIDGET_ID/)
assert.match(uiSource, /spinner|loader|frameIndex|SIGNUM_SPINNER_FRAMES/)
assert.match(uiSource, /CONTRACT[\s\S]*EXECUTE[\s\S]*AUDIT[\s\S]*PACK/)
assert.match(uiSource, /currentPhase|isActive|highlight/)
assert.doesNotMatch(uiSource, /tool log|per-tool|every tool event|low-level log line/)
assert.doesNotMatch(uiSource, /% complete|percent|hidden thinking/)
assert.match(uiSource, /ctx\.ui\.setWidget\(SIGNUM_PROGRESS_WIDGET_ID, widgetLines\)/)
assert.match(uiSource, /clearSignumProgress[\s\S]{0,200}ctx\.ui\.setWidget\(SIGNUM_PROGRESS_WIDGET_ID, undefined\)/)
assert.doesNotMatch(uiSource, /ctx\.ui\.custom\(|main-window widget[\s\S]{0,80}custom/)

for (const token of ['preflight', 'contract', 'execute', 'audit', 'pack', 'foreground']) {
  assert.match(orchestratorSource, new RegExp(token))
}
assert.doesNotMatch(orchestratorSource, /background job|queueWorker|detached/)

for (const token of ['workspace', 'contractor', 'validation', 'deterministic', 'approval']) {
  assert.match(contractSource, new RegExp(token))
}
assert.match(contractSource, new RegExp(String.raw`emitSignumMessage\([\s\S]{0,1200}runContractor\(`))

assert.match(executeSource, /(setSignumProgress|pushSignumProgressEvent|milestone|heartbeat)/)
assert.match(auditSource, /(setSignumProgress|pushSignumProgressEvent|milestone|heartbeat)/)
assert.match(packSource, /(setSignumProgress|pushSignumProgressEvent|milestone|heartbeat)/)

console.log('PASS: pi progress visibility')
EOF
