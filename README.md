```
         _
   _____(_)___ _____  __  ______ ___
  / ___/ / __ `/ __ \/ / / / __ `__ \
 (__  ) / /_/ / / / / /_/ / / / / / /
/____/_/\__, /_/ /_/\__,_/_/ /_/ /_/
       /____/
```

**Write contracts before writing code.**

[![Claude Code Plugin](https://img.shields.io/badge/Claude_Code-Plugin-5b21b6?style=flat-square)]()
[![Version](https://img.shields.io/badge/Version-4.18.1-5b21b6?style=flat-square)]()
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> Your AI agent writes code. Signum makes sure it writes the *right* code.

[Landing page](https://skill7.dev/signum?ref=readme) · [Book a setup call](https://skill7.dev/signum?ref=readme#setup-call) · [Discussions](https://github.com/heurema/signum/discussions)

---

## What it does

AI can generate a function in seconds; telling you whether it is correct takes longer, because "correct" isn't defined until someone writes it down. Signum is a contract-first development pipeline for Claude Code that defines correctness before a line is written, then verifies against it deterministically — not by asking another model if the code looks right, but by running acceptance criteria the implementing agent never fully saw. Unlike generic code review, Signum produces a tamper-evident `proofpack.json` artifact that CI can gate on, plus an advisory `anti_entropy_report.json` for follow-up hygiene work.

| Phase | What happens |
|-------|-------------|
| **CONTRACT** | Spec graded A–F. Codex + Gemini validate for gaps. |
| **EXECUTE** | Engineer builds against a redacted contract. |
| **AUDIT** | Deterministic checks + 3-model parallel review + iterative fix loop. |
| **PACK** | Self-contained `proofpack.json` for CI gating + advisory `anti_entropy_report.json`. |

## Install

<!-- INSTALL:START -->
```bash
claude plugin marketplace add heurema/emporium
claude plugin install signum@emporium
```
<!-- INSTALL:END -->

<details>
<summary>Manual install from source</summary>

```bash
git clone https://github.com/heurema/signum.git
cd signum
claude plugin install .
```

</details>

## Quick start

```bash
# Run — describe what you want to build
/signum "your task description"
```

Signum grades your spec, shows the contract for approval, implements with an automatic repair loop, audits from multiple angles, and produces `proofpack.json` plus an advisory `anti_entropy_report.json`.

For an existing repo, bootstrap project context first:

```bash
/signum init --harness
```

This generates `project.intent.md`, `project.glossary.json`, and repo-level harness docs such as `AGENTS.md`, `ARCHITECTURE.md`, `docs/PLANS.md`, `docs/RELIABILITY.md`, `docs/SECURITY.md`, and `docs/QUALITY_SCORE.md`. In brownfield repos, existing context files are preserved unless you also pass `--force`.

## Commands

| Command | Description |
|---------|-------------|
| `/signum <task>` | Run the full CONTRACT → EXECUTE → AUDIT → PACK pipeline |
| `/signum init [--force] [--harness] [--project-root <path>]` | Bootstrap `project.intent.md` / `project.glossary.json`; `--harness` also scaffolds repo-level harness docs |

## Features

**Spec quality gate** — Before implementation starts, your spec is scored across seven dimensions: Testability, Negative coverage, Clarity, Scope boundedness, Completeness, Boundary cases, NL Consistency. Grade D (below 60) is a hard stop with specific feedback on what's missing. The gate runs on the specification, not the code.

**Holdout scenarios** — The Contractor generates hidden acceptance criteria the Engineer never sees. When implementation is complete, holdouts run against the result — blind testing for cases the agent couldn't optimize for. Verification uses a typed DSL with `http`, `exec` (whitelisted binaries only), and `expect` primitives — no shell execution, no `eval`. Minimum counts enforced by risk level: 0 for low, 2 for medium, 5 for high.

**Project intent alignment** — If the target project has a `project.intent.md` at its root, the contractor reads it before generating contracts. Non-goals and glossary terms flow into contract scope and terminology. For medium/high-risk tasks, missing project intent triggers a blocking question. An LLM-based alignment check warns when the contract diverges from project goals. `/signum init` bootstraps this file from an existing codebase.

**Glossary enforcement** — A `project.glossary.json` at the project root defines canonical terms and forbidden synonyms. `glossary_check` scans contracts for alias usage, `terminology_consistency_check` detects synonym proliferation across active contracts. Both are WARN-only.

**Harness bootstrap** — `/signum init --harness` adds deterministic repo-level scaffolding for `AGENTS.md`, `ARCHITECTURE.md`, `docs/PLANS.md`, `docs/RELIABILITY.md`, `docs/SECURITY.md`, and `docs/QUALITY_SCORE.md`. These files make repo conventions, architecture, planning, and review policy explicit without changing Signum runtime behavior.

**Brownfield validation pattern** — When extending harness bootstrap or advisory anti-entropy behavior, prefer a downstream-style temporary repo test that preserves existing `project.intent.md` / `project.glossary.json`, materializes scaffold docs, and checks the resulting `.signum/anti_entropy_report.json`. `tests/test-brownfield-harness-flow.sh` is the reference pattern.

**Cross-contract coherence** — `overlap_check` detects inScope file overlap between active contracts. `assumption_check` flags contradictions in assumptions across related contracts. `adr_check` warns when relevant ADRs exist but aren't referenced. Contract lineage is tracked via `parentContractId`, `relatedContractIds`, and `interfacesTouched`.

**Upstream staleness detection** — Contractor computes SHA-256 over upstream artifacts (`project.intent.md`, `project.glossary.json`) at contract creation. `staleness_check` recomputes the hash at execution time. Configurable policy: `warn` (default) or `block`.

**Within-task refinement** — For medium/high-risk tasks, the contractor runs a 4-pass self-critique (ambiguity, missing-input, contradiction, coverage), capped at 2 auto-revision rounds. Typed findings and a `readinessForPlanning` gate are written to the contract.

**Data-level blinding** — The Engineer reads `contract-engineer.json`, not `contract.json`. Holdout scenarios are physically removed from the file — not hidden by instruction. The agent cannot infer them from context or structure.

**Execution policy** — `contract-policy.json` is derived from the contract before EXECUTE begins. It defines which tools the Engineer may use, which bash commands are denied, and which paths are in scope. Policy violations after execution are `AUTO_BLOCK`.

**Repo invariant contracts** — Add `repo-contract.json` to your project root — invariants that must always hold, independent of task. Any regression is `AUTO_BLOCK`, regardless of task-level acceptance criteria results.

```json
{
  "schemaVersion": "1.0",
  "invariants": [
    { "id": "I-1", "description": "All tests pass", "verify": "pytest -q", "severity": "critical" },
    { "id": "I-2", "description": "No type errors", "verify": "mypy src/", "severity": "critical" },
    { "id": "I-3", "description": "No lint errors", "verify": "ruff check src/", "severity": "high" }
  ],
  "owner": "human"
}
```

**Immutable audit chain** — At user approval, Signum computes SHA-256 of the contract and records the timestamp. The base commit is captured before the Engineer runs. `proofpack.json` anchors the full chain: contract hash → approval timestamp → base commit → implementation diff → audit results.

**Multi-model audit panel** — Claude, Codex, and Gemini review the diff independently in parallel. The Mechanic runs first — deterministic checks: lint, typecheck, new test failures (by name, not exit code). Then models weigh in. Critical findings from any model block.

**Iterative review-fix loop** — When reviewers find MAJOR or CRITICAL issues, the AUDIT phase doesn't stop — it iterates. A fresh Engineer agent receives a repair brief with specific findings, fixes them, and the full review cycle re-runs from scratch. Best-of-N selection keeps the highest-scoring candidate across iterations. Early stop halts after 2 consecutive non-improving rounds. Up to 20 iterations (configurable via `SIGNUM_AUDIT_MAX_ITERATIONS`). Holdout details are never revealed to the engineer — only failure categories.

**Diff progression** — On review pass 2+, reviewers receive both the full feature diff and an iteration delta showing only what changed in the fix. This focuses review on the actual repair, reduces noise from re-discovering accepted code, and improves convergence speed.

**Module lifecycle tracking** — A `modules.yaml` manifest at the project root declares module status: `active`, `experimental`, `deprecated`, or `removed`. Deprecated modules carry `remove_after` deadlines and `replaced_by` pointers. The contractor reads this before generating contracts — cleanup tasks auto-detect removal candidates and generate structured `removals` and `cleanupObligations` entries.

**Cleanup contracts** — Contract schema v3.8 adds first-class support for code removal. `removals` entries specify files/directories to delete with `preventReintroduction` flags. `cleanupObligations` use K8s Finalizer semantics — blocking obligations (e.g., "remove all imports of deleted module") must be fulfilled before `AUTO_OK`. The DSL supports `file_not_exists` assertions and `grep` for reference-checking verify blocks. Evidence of successful removals is captured in `proofpack.json`.

**Advisory anti-entropy report** — PACK also writes `.signum/anti_entropy_report.json`: a non-blocking follow-up report that can surface unresolved cleanup evidence, overdue `modules.yaml` lifecycle drift, and optional imported metric regressions. It never changes the pipeline decision.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  PHASE 1: CONTRACT                                      │
│                                                         │
│  Contractor → spec quality gate (A–F)                  │
│            → prose check (lib/prose-check.sh)           │
│            → glossary check (lib/glossary-check.sh)     │
│            → terminology check (lib/terminology-check.sh)│
│            → overlap check (lib/overlap-check.sh)       │
│            → assumption check (lib/assumption-check.sh) │
│            → ADR check (lib/adr-check.sh)               │
│            → staleness check (lib/staleness-check.sh)   │
│            → spec validation (Codex + Gemini, parallel) │
│            → holdout count gate (by risk level)         │
│            → [user approval + contract-hash.txt]        │
│            → contract-engineer.json  (holdouts removed) │
│            → contract-policy.json    (execution rules)  │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│  PHASE 2: EXECUTE                                       │
│                                                         │
│  baseline (lint, typecheck, per-test failing names)     │
│  + repo-contract baseline                               │
│  → Engineer (no holdouts, policy-constrained)           │
│  → scope gate → policy compliance check                 │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│  PHASE 3: AUDIT                                         │
│                                                         │
│  repo-contract invariant check                          │
│  → Mechanic (deterministic, zero LLM)                   │
│  → Claude + Codex + Gemini (parallel, independent)      │
│  → holdout verification                                 │
│  → Synthesizer (verdict + confidence score)             │
│  → if MAJOR/CRITICAL: iterative fix loop ───────┐      │
│      engineer fixes → full re-review → repeat   │      │
│      best-of-N selection, up to 20 iterations   │      │
│      diff progression: full patch + delta ◄─────┘      │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│  PHASE 4: PACK                                          │
│                                                         │
│  all artifacts embedded → self-contained proofpack.json  │
└─────────────────────────────────────────────────────────┘
```

## Provider Configuration (optional)

Create `~/.claude/emporium-providers.local.md` to customize which models Codex and Gemini use:

```yaml
---
version: 1
defaults:
  codex:
    model: "gpt-5.3-codex"
  gemini:
    model: "gemini-3.1-pro"
routing:
  review:
    gemini: "gemini-3-flash"
---
```

Without this file, signum uses each CLI's default model. See `forge doctor` to validate your config.

## Requirements

- Claude Code v2.1+
- `git`, `jq`, `python3`
- Optional: [Codex CLI](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli)

## Privacy

All orchestration runs inside Claude Code. External providers (Codex CLI, Gemini CLI) receive the diff only — never the full codebase. Signum degrades gracefully if either is unavailable. No API keys required beyond standard CLI auth. No telemetry. Artifacts stored in `.signum/` (auto-added to `.gitignore`), including the advisory `anti_entropy_report.json`.

## Why Signum

| | Signum | CodeRabbit | Codacy |
|---|---|---|---|
| **Approach** | Contract-first: define correctness before code | Post-hoc review | Static analysis |
| **Models** | 3 independent (Claude + Codex + Gemini) | Single model | Rule-based |
| **Proof artifact** | `proofpack.json` — tamper-evident, CI-gatable | Comment on PR | Report |
| **Blind testing** | Holdout scenarios engineer never sees | None | None |
| **Iterative fix** | Auto-repair loop (up to 20 iterations) | Manual fix cycle | Manual |
| **SOC2 evidence** | Proofpack = CC8.1 attestation | None | Partial |

## Support the project

If Signum saves you time, consider sponsoring its development:

[![Sponsor](https://img.shields.io/badge/Sponsor-♥-ea4aaa?style=flat-square)](https://github.com/sponsors/heurema)

- **$5/mo** — Individual: early access to new check types
- **$20/mo** — Team: priority support + roadmap input

## See also

- [skill7.dev/signum](https://skill7.dev/signum?ref=readme) — landing page, setup call, email updates
- [heurema/emporium](https://github.com/heurema/emporium) — plugin registry
- [How it works](docs/how-it-works.md) — agents, trust boundaries, limitations
- [Reference](docs/reference.md) — artifacts schema, troubleshooting
- [Report an issue](https://github.com/heurema/signum/issues)

## License

[MIT](LICENSE)
