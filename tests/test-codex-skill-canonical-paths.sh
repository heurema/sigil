#!/usr/bin/env bash
# test-codex-skill-canonical-paths.sh -- keep Codex Signum skill instructions aligned with canonical contract-root storage
set -euo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/platforms/codex/SKILL.md"

passed=0
failed=0

assert_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s -- missing "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq -- "$needle" "$DOC"; then
    printf '  FAIL: %s -- unexpectedly found "%s"\n' "$label" "$needle"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$label"
    passed=$((passed + 1))
  fi
}

echo "=== Codex skill canonical paths ==="

assert_contains '.signum/contracts/<contractId>/' "skill doc introduces canonical artifact root"
assert_contains '.signum/contracts/index.json.activeContractId' "skill doc mentions active contract registry"
assert_contains 'file-digests-v1.json' "skill doc mentions Codebase Awareness digest cache"
assert_contains 'file-extracts-v1.json' "skill doc mentions Codebase Awareness extraction cache"
assert_contains 'per-file scanner extraction payloads' "skill doc describes extraction cache payloads"
assert_contains 'not active contract root evidence and not proofpack payloads' "skill doc classifies digest cache outside proofpack"
assert_contains 'Neither cache adds AST, semantic, or external-tool scanning.' "skill doc avoids overclaiming extraction tooling"
assert_contains '--max-files 10000' "skill doc mentions bounded scanner defaults"
assert_contains 'TypeScript/JavaScript lexical/symbol support' "skill doc mentions TypeScript/JavaScript scanner support"
assert_contains '`package.json` workspaces, npm/pnpm/yarn lockfiles, `tsconfig`/`jsconfig` hints, imports/exports, exported and local symbols, tests, package boundaries, CLI `bin` entrypoints, and package/workspace reuse signals' "skill doc describes TypeScript/JavaScript scanner signals"
assert_contains 'it does not use Roslyn, TypeScript compiler API, AST parsing, type checking, semantic analysis, or semantic resolution' "skill doc denies TypeScript AST/compiler/semantic support"
assert_contains 'Record attempts and outcomes in `execute_log.json` under the active contract artifact root.' "skill doc uses canonical execute log wording"
assert_contains 'If `contracts/index.json.activeContractId` or other pipeline artifacts already exist:' "skill doc uses registry-first resume wording"
assert_contains 'implementation_context.json' "skill doc mentions implementation context"
assert_contains 'reuse_candidates.json' "skill doc mentions reuse candidates"
assert_contains 'reuse_decision.json' "skill doc mentions reuse decision"
assert_contains 'in `hint` mode `reuse_decision.json` is advisory' "skill doc keeps hint advisory"
assert_contains 'in `warn` or `gate` mode the Engineer must write `reuse_decision.json` before code changes with top/strong candidate coverage and `candidateId` on action-bearing decisions.' "skill doc requires covered reuse decision in warn/gate"
assert_contains 'top/strong candidate coverage' "skill doc mentions top/strong coverage"
assert_contains '`candidateId` on action-bearing decisions' "skill doc mentions candidateId binding"
assert_contains '`duplicate_scan.json`' "skill doc mentions duplicate scan"
assert_contains '`reuse_summary.json`' "skill doc mentions reuse summary"
assert_contains 'When Codebase Awareness is enabled, AUDIT may produce `duplicate_scan.json` as reuse/duplicate evidence. In `warn`, unresolved major/critical duplicate findings cap AUDIT at `HUMAN_REVIEW`; in `gate`, critical and narrow high-confidence unresolved major findings can force `AUTO_BLOCK`. PACK writes `reuse_summary.json` as compact run-scoped Codebase Awareness evidence and proofpack includes or references that summary. Do not pack project-level `.signum/cache/` scanner cache files by default.' "skill doc describes duplicate verdict mapping and PACK reuse summary evidence"
assert_contains 'Codebase Awareness `reuse_summary.json` evidence when Codebase Awareness was enabled' "skill doc includes reuse summary in proofpack contents"

assert_not_contains 'Keep all pipeline artifacts in `.signum/`.' "old root artifact rule removed"
assert_not_contains '- `.signum/contract.json`' "old root contract path removed"
assert_not_contains 'Capture baseline checks into `.signum/baseline.json`' "old root baseline wording removed"
assert_not_contains 'Record attempts and outcomes in `.signum/execute_log.json`.' "old root execute log wording removed"
assert_not_contains 'If `.signum/contract.json` or other pipeline artifacts already exist:' "old root resume wording removed"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
