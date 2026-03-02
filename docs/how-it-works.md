# How Sigil Works

## Philosophy

Contract-first, multi-model-verified, proof-packaged.

Sigil treats every development task as a formal contract. Before any code is written, a structured `contract.json` captures the exact acceptance criteria, affected files, and test strategy. Implementation is measured against the contract. A panel of independent AI models audits the result. Everything is packaged into a `proofpack.json` that serves as a CI-gate artifact.

The core insight: a single-model review is a self-audit. Sigil removes that by routing the finished diff to models with different training provenance — Claude Opus, OpenAI Codex, and Google Gemini — each reviewing blind, without seeing the others' findings.

## Pipeline

```
CONTRACT → EXECUTE → AUDIT → PACK
                       ↓
                  ┌────┼────┐
               Claude Codex Gemini
                  └────┼────┘
                       ↓
                  proofpack.json
```

### Phase 1: CONTRACT

**Agent:** Contractor (haiku or sonnet, zero implementation risk)

The contractor ingests the task description and produces `contract.json`:

```json
{
  "task": "...",
  "acceptance_criteria": [...],
  "affected_files": [...],
  "test_strategy": "...",
  "risk": "low|medium|high"
}
```

Risk is assessed structurally (file count, keywords, surface area) and drives model selection for all downstream phases. The contract is shown to the user before execution begins — this is the only approval gate.

### Phase 2: EXECUTE

**Agent:** Engineer (sonnet)

The engineer implements against the contract with a 3-attempt repair loop:

1. Implement changes
2. Run tests and linters
3. If failures: read errors, patch, retry (up to 3 times)

If the repair loop exhausts its attempts, execution halts with a BLOCKED status and the error log is written to the proofpack.

All changes land on a feature branch. The finished diff is extracted and passed to AUDIT.

### Phase 3: AUDIT

**Agents:** Reviewer-Claude (opus), Reviewer-Codex (CLI), Reviewer-Gemini (CLI), Synthesizer (sonnet)

The multi-model audit panel is the primary differentiator. Each reviewer receives:
- The contract (acceptance criteria, affected files)
- The unified diff only — never the full codebase

Reviews run sequentially (CLI constraint). Each reviewer produces structured findings: file, line range, severity (critical/important/minor), claim, evidence.

**Finding validation** runs on every result before it reaches synthesis:
1. File exists at the claimed path
2. Line range is within file bounds
3. Evidence grep confirms the cited code pattern
4. Finding is within the diff scope (not pre-existing code)

Invalid findings are dropped. Valid findings from all providers go to the Synthesizer.

**Synthesizer** applies deterministic rules:
- Any critical finding from any provider → **BLOCK**
- Important finding confirmed by 2+ providers → **WARN**
- Single-provider important finding → informational
- Minor findings → collected, not blocking

External providers (Codex, Gemini) require explicit consent before dispatch. Use `skip-external` to run Claude-only review. Both CLIs must be authenticated; Sigil degrades gracefully if either is unavailable.

### Phase 4: PACK

**Agent:** Synthesizer (sonnet, continuation)

Assembles `proofpack.json`:

```json
{
  "task": "...",
  "contract": { ... },
  "verdict": "PASS|WARN|BLOCK",
  "audit": {
    "providers": ["claude", "codex", "gemini"],
    "findings": [...],
    "synthesis": "..."
  },
  "execution": {
    "branch": "...",
    "commits": [...],
    "tests_passed": true,
    "repair_attempts": 0
  },
  "timestamp": "..."
}
```

PASS and WARN proofpacks are CI-gate artifacts: they prove the change was reviewed by multiple independent models, all findings were surfaced, and the implementation passed tests. BLOCK proofpacks halt the workflow.

## Agents

| Agent | Model | Phase | Responsibility |
|-------|-------|-------|----------------|
| Contractor | haiku (low) / sonnet (med/high) | CONTRACT | Parse task, produce contract.json |
| Engineer | sonnet | EXECUTE | Implement with repair loop |
| Reviewer-Claude | opus | AUDIT | Semantic review of diff |
| Reviewer-Codex | codex CLI | AUDIT | Independent review via CLI adapter |
| Reviewer-Gemini | gemini CLI | AUDIT | Independent review via CLI adapter |
| Synthesizer | sonnet | AUDIT + PACK | Verdict synthesis, proofpack assembly |

## CLI Adapter

External model reviews run through a thin CLI adapter that:
1. Serializes the prompt (contract + diff) to a temp file
2. Invokes the CLI with appropriate flags (`--no-interactive`, output to stdout)
3. Parses structured JSON from stdout
4. Validates the schema before passing findings to synthesis

If the CLI returns malformed output or a non-zero exit code, the provider is marked `unavailable` in the proofpack — the audit continues with remaining providers.

## Artifacts

All artifacts are written to `.dev/` (auto-added to `.gitignore`):

| File | Phase | Description |
|------|-------|-------------|
| `contract.json` | CONTRACT | Structured task contract |
| `execution.log` | EXECUTE | Implementation log, repair attempts |
| `audit/*.json` | AUDIT | Per-provider findings |
| `proofpack.json` | PACK | Final CI-gate artifact |

## Cost Estimates

Approximate per-run costs at standard API rates:

| Configuration | Estimate |
|---------------|----------|
| Claude only (haiku + sonnet) | ~$0.44 |
| Claude only (opus audit) | ~$0.85 |
| Claude + Codex | ~$1.20 |
| Claude + Codex + Gemini | ~$1.80 |
| High-risk, all providers | ~$2.35 |

Costs vary with diff size and contract complexity.

## Trust Boundaries

**Stays local:** contract generation, orchestration, finding validation, proofpack assembly.

**Sent to Anthropic:** feature description, diff, contract (standard Claude Code behavior).

**Sent to external providers (with consent):** diff only — never the full codebase.

No telemetry. No analytics. No phone-home.

## Limitations

- **Sequential execution**: CLI adapters for Codex and Gemini run sequentially, not in parallel. A 3-provider audit adds wall-clock time proportional to diff size.
- **CLI fragility**: External reviews depend on Codex/Gemini CLI auth state and version compatibility. Sigil degrades gracefully but cannot guarantee external availability.
- **200K context limit**: Very large diffs (>10K lines) may exceed model context windows. The contract + diff must fit within 200K tokens.
- **Heuristic risk**: Risk level is computed from file count and keyword patterns, not semantic analysis. It can under-estimate novel refactors.
- **Interactive only**: Runs inside Claude Code sessions. Not suitable for unattended CI pipelines.
- **Finding validation**: Catches hallucinated file paths and line ranges, but cannot verify logical correctness of a finding's claim.
