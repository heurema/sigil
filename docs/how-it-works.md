# How Sigil Works

Sigil is a 4-phase development pipeline that scales review rigor to match task complexity. One command triggers the full cycle: risk assessment, codebase exploration, architecture design, implementation, and adversarial code review.

## Architecture

```
┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Scope  │───>│ Explore  │───>│  Design  │───>│  Build   │
│ (bash)  │    │ (sonnet) │    │(son/opus)│    │ (sonnet) │
└─────────┘    └──────────┘    └──────────┘    └──────────┘
     │              │               │               │
     ▼              ▼               ▼               ▼
 scope.json    exploration.md   design.md     review-verdict.md
```

Each phase writes a structured artifact to `.dev/`. Post-checks validate each artifact before the next phase begins. If you interrupt, Sigil detects existing artifacts and offers resume/restart/abort.

## Phase 1: Scope (zero LLM)

Pure bash. No AI calls.

- Creates a feature branch from current HEAD
- Parses the feature description to assess risk level (low/medium/high)
- Computes agent counts and review strategy based on risk
- Writes `scope.json` with the execution plan

Risk determines everything downstream:

| Risk | Explore Agents | Design Model | Build Agents | Review Strategy |
|------|---------------|--------------|--------------|-----------------|
| low  | 1             | sonnet       | 1            | simple          |
| med  | 2             | opus         | 2 + observer | adversarial     |
| high | 3             | opus         | 3 + observer | consensus       |

## Phase 2: Explore (parallel sonnet agents)

1-3 agents map the codebase in parallel:
- File structure and module boundaries
- Existing patterns, conventions, test infrastructure
- Dependencies and integration points relevant to the feature

Output: `exploration.md` — a structured map the Design phase uses as input.

## Phase 3: Design (user approval gate)

Produces an architecture document with:
- Implementation approach and file modifications
- Test plan
- Risk factors and mitigation

**This is the only phase that blocks on user input.** You review and approve the design before Build begins. For medium/high risk, Design uses Claude Opus for deeper reasoning.

## Phase 4: Build

Implementation agents write the code, then the review pipeline runs.

### Build Strategy

Before launching implementers, Sigil reads `build_strategy` from `scope.json`. Three paths are available:

**normal** (default): Standard flow — implementer agents write code directly into the feature branch, then tests, observer, and review run as usual.

**diverge**: Sigil delegates to the arbiter plugin to produce 3 independent implementations in isolated git worktrees — one each from Claude (minimal strategy), Codex (refactor strategy), and Gemini (redesign strategy). An anonymized evaluator scores them using a weighted decision matrix (correctness, maintainability, test coverage, security, etc.) and presents a Diverge Report. You pick the winning solution; arbiter merges it into the feature branch. Sigil then resumes its normal Phase 4 flow from the test step — tests, observer, and review run once on the selected implementation, not three times.

**diverge-lite**: Arbiter produces 3 alternative *designs* (not implementations) — useful for exploring architectural options without committing to code. On selection, the chosen design overwrites `.dev/design.md`, and Sigil re-enters Phase 4 from the task planning step, building from the updated design.

Sigil suggests diverge automatically at the scope confirmation prompt when:
- Estimated file count > 10 AND risk is not `low`, OR
- The feature description contains keywords: `refactor`, `redesign`, `migrate`, or `rewrite`

Both `diverge` and `diverge-lite` require arbiter to be installed. The strategy can also be set manually by typing `build=diverge` or `build=diverge-lite` at the scope confirmation prompt.

### Observer Agent

A read-only sonnet agent (medium/high risk only) that audits the implementation against the approved design. Checks for scope creep, missing test coverage, and deviations from the plan. Reports PASS/BLOCK/STOP verdict.

### Review Pipeline

The core differentiator. Three strategies, auto-selected by risk:

**Simple** (low risk): One Claude reviewer scans for bugs, security issues, and logic errors.

**Adversarial** (medium risk): Two Claude agents review the same diff independently — neither sees the other's findings:
- **Reviewer**: hunts for code bugs, security vulnerabilities, performance issues
- **Skeptic**: hunts for spec gaps, missing tests, hallucinated functionality, over-engineering

Findings from both agents go through machine validation:
1. File exists at the claimed path
2. Line range is within file bounds
3. Evidence grep confirms the cited code pattern
4. Finding is within the diff scope (not pre-existing code)

Invalid findings are silently dropped. Valid findings are deduplicated across agents.

If Codex CLI is available, it provides a 3rd independent review perspective.

**Consensus** (high risk): Adversarial + multi-AI escalation:
- All available providers (Claude + Codex + Gemini) review the diff blind in parallel
- Findings are clustered cross-provider by file + category + claim similarity
- Single-provider critical findings trigger Round 2: all other providers confirm or refute
- If a critical finding remains contested, a panel vote decides (the originating provider is excluded from voting)

### Verdict Logic

- Any machine-validated critical finding → **BLOCK**
- Important finding confirmed by 2+ providers → **WARN**
- Single-provider findings → informational only (shown but don't block)

## Components

| Component | File | Purpose |
|-----------|------|---------|
| Pipeline orchestrator | `commands/sigil.md` | Main command, all 4 phases |
| Observer agent | `agents/observer.md` | Post-build plan compliance (read-only) |
| Reviewer prompt | `lib/prompts/reviewer.md` | Code review: bugs, security, logic |
| Skeptic prompt | `lib/prompts/skeptic.md` | Design audit: spec gaps, missing tests |
| Round 2 prompt | `lib/prompts/round2.md` | Cross-verification of contested findings |
| External reviewer | `lib/prompts/external-reviewer.md` | Leaner prompt for Codex/Gemini |
| Observer body | `lib/prompts/observer-body.md` | Observer agent system prompt |

## Trust Boundaries

**What stays local:**
- All artifacts in `.dev/` (auto-added to `.gitignore`)
- Scope computation, risk assessment, agent orchestration
- Finding validation (file exists, line range, evidence grep)

**What goes to Anthropic (Claude API):**
- Feature description, codebase exploration queries, design doc, code diff
- This is standard Claude Code behavior — same as any Claude Code session

**What goes to external providers (optional, with consent):**
- **Codex CLI**: receives the diff for review (medium/high risk)
- **Gemini CLI**: receives the diff for review (high risk only)
- Both require explicit user consent before dispatch
- Only the diff is sent, never the full codebase
- Use `skip-external` at the consent prompt to opt out

**No telemetry. No analytics. No phone-home.**

## Session Management

- **Resume**: Sigil detects existing `.dev/` artifacts and offers to continue from the next incomplete phase
- **Archiving**: Completed runs are archived to `.dev/runs/<timestamp>/`
- **Cleanup**: `.dev/` is project-local and can be deleted safely at any time

## Limitations

- Interactive only — runs inside Claude Code sessions, not in CI/CD pipelines
- Risk assessment is heuristic-based (keyword matching), not semantic
- External provider quality depends on Codex/Gemini model capabilities and auth state
- Finding validation catches obvious hallucinations but cannot verify logical correctness
- Cost scales with risk level and diff size (~$0.05 for simple, ~$0.60 for consensus)
