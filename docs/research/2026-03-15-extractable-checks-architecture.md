---
title: Extracting Inline Checks into Standalone Testable Scripts
date: 2026-03-15
status: quick-scan
depth: shallow
verification: unverified
run_id: 20260315T170223Z-18868
---

# Extracting Inline Checks into Standalone Testable Scripts

## Problem

Signum's quality checks (glossary_check, overlap_check, assumption_contradiction_check, adr_relevance_check, upstream_staleness_check, terminology_consistency_check) are embedded as inline bash blocks in `commands/signum.md`. This makes them:
- Untestable independently (only exercised during full pipeline runs)
- Hard to debug (errors surface as LLM orchestrator failures)
- Duplicated across root and platform mirrors

## Research Findings

### 1. Interface Design: Unix Contract for AI-Callable Scripts

**Pattern from Jina AI CLI, AIRun, Claude Agent SDK:**
- stdout = structured data (JSON), stderr = diagnostics
- Exit 0 always for WARN-only checks (non-blocking)
- Accept paths as positional args, not stdin (simpler for LLM orchestrators)
- Output JSON to stdout, human-readable summary to stderr

**Recommended interface:**
```
lib/<check-name>.sh <contract.json> [<extra-args>...]
  stdout: JSON report (findings array + metadata)
  stderr: human-readable summary lines
  exit 0: always (WARN-only checks never fail the pipeline)
```

This matches the existing `lib/prose-check.sh` pattern already in Signum.

### 2. Existing Pattern in Signum

`lib/prose-check.sh` already implements this exact pattern:
- Accepts `contract.json` path as arg
- Outputs JSON report to stdout
- Exit 0 always
- Called from `commands/signum.md` with result captured: `PROSE_REPORT=$(lib/prose-check.sh ...)`

**Key insight:** The extraction is not novel architecture — it's extending an existing proven pattern to 6 more checks.

### 3. Testing Strategy

**BATS (Bash Automated Testing System)** is the standard for bash script testing:
- TAP-compliant output
- Setup/teardown per test
- Fixture-based: create temp contract.json with specific fields, run check, assert JSON output

**Simpler alternative for Signum:** pytest calling bash scripts via `subprocess.run()`:
- Already have pytest infrastructure
- Fixtures already exist in `tests/fixtures/`
- Python's `json.loads()` for output validation
- No new test framework dependency

### 4. Separation of Deterministic vs LLM Logic

**Key architectural principle (from Praetorian, Blueprint-First paper):**
> "Treat deterministic work as workflow and reserve agentic reasoning for ambiguity and judgment."

Signum's checks are 100% deterministic (jq, grep, shasum) — they should NEVER be inside LLM instruction files. The LLM orchestrator should only:
1. Call the script
2. Read its JSON output
3. Display results to user
4. Decide what to do based on output (the judgment part)

**Kiro parallel:** Kiro's spec-driven development also separates deterministic validation (file structure, link checking) from semantic LLM review. Same pattern.

### 5. Migration Plan

**Phase A: Extract scripts (no behavior change)**
Each check becomes `lib/<name>.sh` with identical logic, just pulled out of markdown. The markdown block becomes a 2-line call:

```bash
CONTRACT_PATH=".signum/contracts/<contractId>/contract.json"
RESULT=$(lib/glossary-check.sh "$CONTRACT_PATH" "$GLOSSARY_PATH" 2>/dev/null || echo '{}')
echo "$RESULT" | jq -r '.summary // "glossary check: no output"'
```

**Phase B: Add tests**
For each script, add pytest test using fixtures:
```python
def test_glossary_check_finds_synonym(tmp_path):
    contract = {"goal": "add developer support", ...}
    glossary = {"aliases": {"developer": "engineer"}, ...}
    # write fixtures, run script, assert JSON output
```

**Phase C: Platform sync simplification**
Since checks are now in `lib/`, platform mirrors of `commands/signum.md` automatically use the same scripts. No more duplicated logic.

## Scripts to Extract

| Current location | New script | Args | Output key |
|-----------------|------------|------|------------|
| commands/signum.md glossary_check block | `lib/glossary-check.sh` | contract.json, glossary.json | glossary_warnings |
| commands/signum.md terminology_consistency_check block | `lib/terminology-check.sh` | contract.json, index.json | terminology_warnings |
| commands/signum.md cross_contract_overlap_check block | `lib/overlap-check.sh` | contract.json, index.json | overlap_warnings |
| commands/signum.md assumption_contradiction_check block | `lib/assumption-check.sh` | contract.json, index.json | assumption_warnings |
| commands/signum.md adr_relevance_check block | `lib/adr-check.sh` | contract.json, project_root | adr_warnings |
| commands/signum.md upstream_staleness_check block | `lib/staleness-check.sh` | contract.json, project_root | staleness_result |

## Sources

- [Jina AI CLI — composable AI tools](https://github.com/jina-ai/cli)
- [AIRun — executable markdown with pipes](https://github.com/andisearch/airun)
- [Deterministic AI Orchestration (Praetorian)](https://www.praetorian.com/blog/deterministic-ai-orchestration-a-platform-architecture-for-autonomous-development/)
- [Blueprint First, Model Second (arXiv)](https://arxiv.org/pdf/2508.02721)
- [Kiro spec-driven development (Martin Fowler)](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
- [BATS testing framework](https://opensource.com/article/19/2/testing-bash-bats)
- [ShellSpec comparison](https://shellspec.info/comparison.html)
- [Claude Agent SDK stdin/stdout](https://buildwithaws.substack.com/p/inside-the-claude-agent-sdk-from)
