#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/platforms/pi/extensions/signum/runtime/verify-normalizer.ts"

node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { analyzePiContractForRuntime, collectPiContractVerifyIssues, normalizeContractForPiRuntime, normalizeVerifyForPiRuntime } from './platforms/pi/extensions/signum/runtime/verify-normalizer.ts'

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

const rawBrittleContract = {
  inScope: ['platforms/pi/extensions/signum/phases/audit.ts', 'tests/'],
  acceptanceCriteria: [
    {
      id: 'AC9',
      visibility: 'visible',
      verify: {
        steps: [
          { type: 'assert-not-contains', path: 'platforms/pi/extensions/signum/phases/audit.ts', text: 'iterativeAuditMode: "single-pass"' },
          { type: 'assert-not-contains-any', path: 'platforms/pi/extensions/signum/phases/audit.ts', texts: ['holdoutScenarios', 'Read .signum/holdout_report.json'] },
          { type: 'assert-file-exists', path: '.signum/repair_brief.json' },
          { type: 'assertSemanticAlignment', sources: ['docs/reference.md', 'platforms/pi/README.md'] },
        ],
      },
    },
  ],
}
const brittleContract = normalizeContractForPiRuntime(rawBrittleContract)
assert.equal(brittleContract.acceptanceCriteria[0].verify.steps.length, 2)
assert.equal(brittleContract.acceptanceCriteria[0].verify.steps[0].type, 'assertFileExists')
assert.equal(brittleContract.acceptanceCriteria[0].verify.steps[1].type, 'assertSemanticAlignment')

const brittleIssues = collectPiContractVerifyIssues(brittleContract)
assert.equal(brittleIssues.length, 2)
assert.match(brittleIssues[0], /later-phase \.signum artifacts/i)
assert.match(brittleIssues[1], /explicit file\/path assertions/i)

const analysis = analyzePiContractForRuntime(rawBrittleContract, brittleContract)
assert.equal(analysis.profile.kind, 'meta-task')
assert.equal(analysis.sanitizedVisibleVerifySteps, 2)
assert.equal(analysis.errors.length, 2)
assert.match(analysis.warnings[0], /meta-task profile active/i)
assert.match(analysis.warnings[1], /sanitized 2 brittle visible verify step/i)

const invalidRegexIssues = collectPiContractVerifyIssues(normalizeContractForPiRuntime({
  acceptanceCriteria: [
    {
      id: 'AC10',
      visibility: 'visible',
      verify: {
        steps: [
          { type: 'assertMatches', path: 'README.md', pattern: '(?x)greet\\(' },
        ],
      },
    },
  ],
}))
assert.equal(invalidRegexIssues.length, 1)
assert.match(invalidRegexIssues[0], /not portable to the pi runtime/i)

const brittleShellRaw = {
  acceptanceCriteria: [
    {
      id: 'AC11',
      visibility: 'visible',
      verify: {
        steps: [
          { type: 'assertContains', path: 'tests/test-pi-self-hosted-smoke.sh', text: 'mktemp -d' },
          { type: 'assertContains', path: 'tests/test-pi-self-hosted-smoke.sh', text: 'platforms/pi/extensions/signum/index.ts' },
          { type: 'assertMatches', path: 'tests/test-pi-self-hosted-smoke.sh', pattern: 'pi --no-extensions -e .*platforms/pi/extensions/signum/index\\.ts' },
          { type: 'assertMatches', path: 'tests/test-pi-self-hosted-smoke.sh', pattern: '(cp -R|rsync .*signum|tar .*\\|.*tar)' },
          { type: 'assertMatches', path: 'tests/test-pi-self-hosted-smoke.sh', pattern: 'EXT=.*platforms/pi/extensions/signum/index\\.ts' },
          { type: 'assertMatches', path: 'tests/test-pi-self-hosted-smoke.sh', pattern: 'python3 - .*json' },
        ],
      },
    },
  ],
}
const brittleShellContract = normalizeContractForPiRuntime(brittleShellRaw)
assert.equal(brittleShellContract.acceptanceCriteria[0].verify.steps.length, 2)
assert.equal(brittleShellContract.acceptanceCriteria[0].verify.steps[0].type, 'assertContains')
assert.equal(brittleShellContract.acceptanceCriteria[0].verify.steps[1].type, 'assertContains')
const brittleShellAnalysis = analyzePiContractForRuntime(brittleShellRaw, brittleShellContract)
assert.equal(brittleShellAnalysis.sanitizedVisibleVerifySteps, 4)
assert.equal(brittleShellAnalysis.errors.length, 0)
assert.match(brittleShellAnalysis.warnings[0], /sanitized 4 brittle visible verify step/i)

console.log('PASS: pi verify normalizer')
EOF
