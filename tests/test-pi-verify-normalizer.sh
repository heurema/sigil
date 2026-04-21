#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/platforms/pi/extensions/signum/runtime/verify-normalizer.ts"

node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { collectPiContractVerifyIssues, normalizeContractForPiRuntime, normalizeVerifyForPiRuntime } from './platforms/pi/extensions/signum/runtime/verify-normalizer.ts'

const verify = normalizeVerifyForPiRuntime({
  steps: [
    { type: 'read-file', path: 'README.md' },
    { type: 'assert-contains', path: 'README.md', value: 'greet' },
    { type: 'assert-json-path-equals', path: 'package.json', json_path: '$.type', value: 'module' },
    { type: 'assert-no-file-changes-outside', allowed: ['README.md'] },
  ],
})

assert.equal(verify.timeout_ms, 30000)
assert.equal(verify.steps[0].type, 'readFile')
assert.equal(verify.steps[1].type, 'assertContains')
assert.equal(verify.steps[1].text, 'greet')
assert.equal(verify.steps[2].type, 'assertJsonPathEquals')
assert.equal(verify.steps[2].jsonPath, '$.type')
assert.equal(verify.steps[3].type, 'assertOnlyPathsChanged')
assert.deepEqual(verify.steps[3].paths, ['README.md'])

const contract = normalizeContractForPiRuntime({
  inScope: [
    'AUDIT phase changes in platforms/pi/extensions/signum/phases/audit.ts needed for the repair loop.',
    'Targeted docs in docs/reference.md and platforms/pi/README.md only.',
    'Tests under tests/ that verify the bounded loop.',
  ],
  allowNewFilesUnder: ['platforms/pi/extensions/signum/runtime/', 'tests/'],
  acceptanceCriteria: [
    {
      id: 'AC1',
      description: 'demo',
      verify: {
        steps: [
          { type: 'assert-file-unchanged', path: 'src/index.js' },
          { type: 'assert-not-contains', path: 'README.md', value: 'farewell(' },
        ],
      },
    },
  ],
  holdoutScenarios: [
    {
      id: 'HO1',
      verify: {
        timeout_ms: 10,
        steps: [{ type: 'git-diff-files' }],
      },
    },
  ],
})

assert.deepEqual(contract.inScope, [
  'platforms/pi/extensions/signum/phases/audit.ts',
  'docs/reference.md',
  'platforms/pi/README.md',
  'tests',
])
assert.deepEqual(contract.allowNewFilesUnder, [
  'platforms/pi/extensions/signum/runtime',
  'tests',
])
assert.equal(contract.acceptanceCriteria[0].visibility, 'visible')
assert.equal(contract.acceptanceCriteria[0].verify.steps[0].type, 'assertNotModified')
assert.equal(contract.acceptanceCriteria[0].verify.steps[1].type, 'assertNotContains')
assert.equal(contract.acceptanceCriteria[0].verify.steps[1].text, 'farewell(')
assert.equal(contract.acceptanceCriteria[0].verify.timeout_ms, 30000)
assert.equal(contract.holdoutScenarios[0].verify.steps[0].type, 'gitDiffFiles')
assert.equal(contract.holdoutScenarios[0].verify.timeout_ms, 10)

const brittleIssues = collectPiContractVerifyIssues({
  acceptanceCriteria: [
    {
      id: 'AC9',
      visibility: 'visible',
      verify: {
        steps: [
          { type: 'assert-not-contains', path: 'platforms/pi/extensions/signum/phases/audit.ts', text: 'iterativeAuditMode: "single-pass"' },
          { type: 'assert-not-contains-any', path: 'platforms/pi/extensions/signum/phases/audit.ts', texts: ['holdoutScenarios', 'Read .signum/holdout_report.json'] },
          { type: 'assertSemanticAlignment', sources: ['docs/reference.md', 'platforms/pi/README.md'] },
        ],
      },
    },
  ],
})
assert.equal(brittleIssues.length, 3)
assert.match(brittleIssues[0], /AC9/)
assert.match(brittleIssues[1], /holdout|engineer-facing/i)
assert.match(brittleIssues[2], /explicit file\/path assertions/i)

console.log('PASS: pi verify normalizer')
EOF
