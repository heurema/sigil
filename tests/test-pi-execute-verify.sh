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
import { execFile } from 'node:child_process'
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { buildCombinedPatch, classifyVerifyStrength, collectDiffStatus, evaluateVerifySteps } from './platforms/pi/extensions/signum/phases/execute.ts'

const execFileAsync = promisify(execFile)

assert.equal(classifyVerifyStrength({ steps: [{ type: 'readFile', path: 'a.ts' }] }), 'observational')
assert.equal(classifyVerifyStrength({ steps: [{ type: 'assertContains', path: 'a.ts', text: 'x' }] }), 'observational')
assert.equal(classifyVerifyStrength({ steps: [{ type: 'gitDiffFiles' }] }), 'observational')
assert.equal(classifyVerifyStrength({ steps: [{ exec: { argv: ['grep', '-q', 'x', 'a.ts'] } }] }), 'predicate')
assert.equal(classifyVerifyStrength({ steps: [{ type: 'run', command: 'echo ok' }] }), 'exit_only')

const projectRoot = await mkdtemp(join(tmpdir(), 'signum-execute-verify-'))
await writeFile(join(projectRoot, 'sample.txt'), 'iterative audit metadata\n', 'utf8')
await writeFile(join(projectRoot, 'multiline.txt'), '## Usage\n\nconsole.log(greet("World"))\n', 'utf8')

const ok = await evaluateVerifySteps(projectRoot, {
  steps: [
    { type: 'assertMatches', path: 'sample.txt', pattern: 'iterative\\s+audit' },
  ],
}, [])
assert.equal(ok.exitCode, 0)

const fail = await evaluateVerifySteps(projectRoot, {
  steps: [
    { type: 'assertMatches', path: 'sample.txt', pattern: 'proofpack' },
  ],
}, [])
assert.equal(fail.exitCode, 1)
assert.equal(fail.reason, 'assert_failed')

const scoped = await evaluateVerifySteps(projectRoot, {
  steps: [
    { type: 'assertOnlyPathsChanged', paths: ['tests/'] },
  ],
}, ['tests/test-pi-full-pipeline.sh'])
assert.equal(scoped.exitCode, 0)

const runOk = await evaluateVerifySteps(projectRoot, {
  steps: [
    { type: 'run', command: 'printf ok' },
    { type: 'assertMatches', valueFrom: 'stdout', pattern: 'ok' },
  ],
}, [], {
  exec: async (_cmd, _args, _opts) => ({ code: 0, stdout: 'ok', stderr: '' }),
})
assert.equal(runOk.exitCode, 0)

const equalsStdout = await evaluateVerifySteps(projectRoot, {
  steps: [
    { type: 'run', command: 'printf stable' },
    { type: 'assertEquals', valueFrom: 'stdout', value: 'stable' },
  ],
}, [], {
  exec: async (_cmd, _args, _opts) => ({ code: 0, stdout: 'stable', stderr: '' }),
})
assert.equal(equalsStdout.exitCode, 0)

const dotAll = await evaluateVerifySteps(projectRoot, {
  steps: [
    { type: 'assertMatches', path: 'multiline.txt', pattern: '(?s)(Usage|Example).*(greet\\s*\\()' },
  ],
}, [])
assert.equal(dotAll.exitCode, 0)

const gitRoot = await mkdtemp(join(tmpdir(), 'signum-execute-diff-status-'))
await writeFile(join(gitRoot, 'README.md'), '# Demo\n', 'utf8')
await mkdir(join(gitRoot, 'tests'), { recursive: true })
await execFileAsync('git', ['init', '-q'], { cwd: gitRoot })
await execFileAsync('git', ['config', 'user.email', 'test@example.com'], { cwd: gitRoot })
await execFileAsync('git', ['config', 'user.name', 'test'], { cwd: gitRoot })
await execFileAsync('git', ['add', 'README.md'], { cwd: gitRoot })
await execFileAsync('git', ['commit', '-qm', 'init'], { cwd: gitRoot })
await writeFile(join(gitRoot, 'README.md'), '# Demo\n\nupdated\n', 'utf8')
await writeFile(join(gitRoot, 'tests', 'self-hosted.sh'), '#!/usr/bin/env bash\n', 'utf8')

const execAdapter = {
  exec: async (cmd, args, opts = {}) => {
    try {
      const { stdout, stderr } = await execFileAsync(cmd, args, {
        cwd: opts.cwd,
        timeout: opts.timeout,
      })
      return { code: 0, stdout, stderr }
    } catch (error) {
      return {
        code: error.code ?? 1,
        stdout: error.stdout ?? '',
        stderr: error.stderr ?? String(error),
      }
    }
  },
}
const diffStatus = await collectDiffStatus(execAdapter, gitRoot, ['README.md', 'tests/self-hosted.sh'])
assert.deepEqual(diffStatus.added, ['tests/self-hosted.sh'])
assert.deepEqual(diffStatus.modified, ['README.md'])
assert.equal(diffStatus.statusByPath.get('tests/self-hosted.sh'), 'A')
assert.equal(diffStatus.statusByPath.get('README.md'), 'M')

const combinedPatch = await buildCombinedPatch(execAdapter, gitRoot)
assert.match(combinedPatch, /README\.md/)
assert.match(combinedPatch, /tests\/self-hosted\.sh/)

console.log('PASS: pi execute verify classification')
EOF
