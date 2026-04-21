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
import {
  buildAuditIterationLog,
  buildIterativeAuditProofpackSummary,
  computeAuditIterationScore,
  sanitizeRepairText,
} from './platforms/pi/extensions/signum/runtime/audit-iterations.ts'

assert.equal(computeAuditIterationScore({
  findingsCount: { critical: 0, major: 1, minor: 2 },
  mechanicRegressions: false,
  holdoutFailures: 0,
}), -52)

const sanitized = sanitizeRepairText('Read .signum/contract.json and .signum/holdout_report.json; do not expose holdoutScenarios.')
assert.match(sanitized, /contract-engineer\.json/)
assert.doesNotMatch(sanitized, /holdoutScenarios/)
assert.doesNotMatch(sanitized, /holdout_report\.json/)

const log = buildAuditIterationLog([
  {
    pass: 1,
    decision: 'AUTO_BLOCK',
    score: -1050,
    findingsCount: { critical: 1, major: 1, minor: 0 },
    remainingSeverity: 'CRITICAL',
    consensus: '0/3 approve',
    reasoning: 'critical finding present',
    mechanicRegressions: false,
    holdoutFailures: 0,
    canonicalFindings: [
      { fingerprint: 'abc12345', category: 'bug', file: 'a.ts', severity: 'CRITICAL', comment: 'first' },
      { fingerprint: 'def67890', category: 'security', file: 'b.ts', severity: 'MAJOR', comment: 'second' },
    ],
  },
  {
    pass: 2,
    decision: 'HUMAN_REVIEW',
    score: -1,
    findingsCount: { critical: 0, major: 0, minor: 1 },
    remainingSeverity: 'MINOR',
    consensus: '2/3 approve',
    reasoning: 'minor finding remains',
    mechanicRegressions: false,
    holdoutFailures: 0,
    canonicalFindings: [
      { fingerprint: 'def67890', category: 'security', file: 'b.ts', severity: 'MINOR', comment: 'still minor' },
    ],
  },
], 20, 'bounded audit ended with MINOR findings only', 'major and critical findings are cleared')

assert.equal(log.bestIteration, 2)
assert.equal(log.earlyStop, true)
assert.equal(log.remainingSeverity, 'MINOR')

const proofpackSummary = buildIterativeAuditProofpackSummary(log)
assert.equal(proofpackSummary.auditIterations.length, 2)
assert.equal(proofpackSummary.auditIterations[0].pass, 1)
assert.equal(proofpackSummary.auditIterations[1].score, -1)
assert.equal(proofpackSummary.resolvedFindings.length, 1)
assert.equal(proofpackSummary.resolvedFindings[0].fingerprint, 'abc12345')
assert.equal(proofpackSummary.remainingFindings.length, 1)
assert.equal(proofpackSummary.remainingFindings[0].fingerprint, 'def67890')

console.log('PASS: pi audit iterations')
EOF
