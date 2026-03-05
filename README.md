# Signum

<div align="center">

**Write contracts before writing code**

![Claude Code Plugin](https://img.shields.io/badge/Claude_Code-Plugin-5b21b6?style=flat-square)
![Version](https://img.shields.io/badge/Version-4.0.0-5b21b6?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-5b21b6?style=flat-square)

```bash
claude plugin marketplace add heurema/emporium
claude plugin install signum@emporium
```

</div>

## What it does

AI can generate a function in seconds; telling you whether it is correct takes longer, because "correct" isn't defined until someone writes it down. Signum is a contract-first development pipeline for Claude Code that defines correctness before a line is written, then verifies against it deterministically — not by asking another model if the code looks right, but by running acceptance criteria the implementing agent never fully saw. Unlike generic code review, Signum produces a tamper-evident `proofpack.json` artifact that CI can gate on.

| Phase | What happens |
|-------|-------------|
| **CONTRACT** | Spec graded A–F. Codex + Gemini validate for gaps. |
| **EXECUTE** | Engineer builds against a redacted contract. |
| **AUDIT** | Deterministic checks + 3-model parallel review. |
| **PACK** | Self-contained `proofpack.json` for CI gating. |

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

Signum grades your spec, shows the contract for approval, implements with an automatic repair loop, audits from multiple angles, and produces `proofpack.json`.

## Commands

| Command | Description |
|---------|-------------|
| `/signum <task>` | Run the full CONTRACT → EXECUTE → AUDIT → PACK pipeline |

## Features

**Spec quality gate** — Before implementation starts, your spec is scored across six dimensions: Testability, Negative coverage, Clarity, Scope boundedness, Completeness, Boundary cases. Grade D (below 60) is a hard stop with specific feedback on what's missing. The gate runs on the specification, not the code.

**Holdout scenarios** — The Contractor generates hidden acceptance criteria the Engineer never sees. When implementation is complete, holdouts run against the result — blind testing for cases the agent couldn't optimize for. Minimum counts enforced by risk level: 0 for low, 2 for medium, 5 for high.

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

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  PHASE 1: CONTRACT                                      │
│                                                         │
│  Contractor → spec quality gate (A–F)                  │
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

All orchestration runs inside Claude Code. External providers (Codex CLI, Gemini CLI) receive the diff only — never the full codebase. Signum degrades gracefully if either is unavailable. No API keys required beyond standard CLI auth. No telemetry. Artifacts stored in `.signum/` (auto-added to `.gitignore`).

## See also

- [skill7.dev/development/signum](https://skill7.dev/development/signum) — full documentation, pipeline detail, artifacts schema, cost estimates
- [heurema/emporium](https://github.com/heurema/emporium) — plugin registry
- [How it works](docs/how-it-works.md) — agents, trust boundaries, limitations
- [Reference](docs/reference.md) — artifacts schema, troubleshooting
- [Report an issue](https://github.com/heurema/signum/issues)

## License

[MIT](LICENSE)
