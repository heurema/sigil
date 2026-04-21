#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/platforms/pi/extensions/signum/runtime/verify-normalizer.ts"

node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { normalizeContractForPiRuntime, normalizeVerifyForPiRuntime } from './platforms/pi/extensions/signum/runtime/verify-normalizer.ts'

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

assert.equal(contract.acceptanceCriteria[0].visibility, 'visible')
assert.equal(contract.acceptanceCriteria[0].verify.steps[0].type, 'assertNotModified')
assert.equal(contract.acceptanceCriteria[0].verify.steps[1].type, 'assertNotContains')
assert.equal(contract.acceptanceCriteria[0].verify.steps[1].text, 'farewell(')
assert.equal(contract.acceptanceCriteria[0].verify.timeout_ms, 30000)
assert.equal(contract.holdoutScenarios[0].verify.steps[0].type, 'gitDiffFiles')
assert.equal(contract.holdoutScenarios[0].verify.timeout_ms, 10)

console.log('PASS: pi verify normalizer')
EOF
