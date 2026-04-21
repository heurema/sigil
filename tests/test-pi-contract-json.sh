#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

node --input-type=module - <<'EOF'
import assert from 'node:assert/strict'
import { escapeControlCharactersInStrings, parsePossiblyBrokenJsonObject } from './platforms/pi/extensions/signum/runtime/contract-json.ts'

const escaped = escapeControlCharactersInStrings('{"pattern":"line1\nline2"}')
assert.equal(escaped, '{"pattern":"line1\\nline2"}')

const repairedEscapes = escapeControlCharactersInStrings('{"pattern":"foo\\[bar\\$baz"}')
assert.equal(repairedEscapes, '{"pattern":"foo\\\\[bar\\\\$baz"}')

const repaired = parsePossiblyBrokenJsonObject(`{
  "schemaVersion": "3.8",
  "pattern": "foo
bar"
}`)
assert.equal(repaired.schemaVersion, '3.8')
assert.equal(repaired.pattern, `foo
bar`)

const repairedPattern = parsePossiblyBrokenJsonObject('{"pattern":"foo\\[bar\\$baz"}')
assert.equal(repairedPattern.pattern, 'foo\\[bar\\$baz')

const valid = parsePossiblyBrokenJsonObject('{"goal":"ok","nested":{"value":1}}')
assert.equal(valid.goal, 'ok')
assert.deepEqual(valid.nested, { value: 1 })

console.log('PASS: pi contract json')
EOF
