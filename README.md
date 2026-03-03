# Signum

**The code is the easy part.**

AI can generate a function in seconds. Telling you whether it's *correct* takes longer — because "correct" isn't defined until someone writes it down first.

> Contract-first AI development for Claude Code.

<!-- INSTALL:START — auto-synced from emporium/INSTALL_REFERENCE.md -->
```bash
claude plugin marketplace add heurema/emporium
claude plugin install signum@emporium
```
<!-- INSTALL:END -->

```bash
/signum "add JWT authentication to the API"
```

---

## The Problem

The industry's response to unreliable AI output is more review: run the diff through Claude, then Codex, then Gemini. But review is probabilistic — three models can share the same blind spots, and none of them know what "done" looks like unless you told them.

The problem isn't the reviewer. It's that there's no contract.

Without a contract, "did the AI do it right?" has no principled answer. You're comparing output to a mental model that was never written down. Code review becomes archaeology — reconstructing intent from evidence rather than verifying against a specification.

Signum is the contract layer.

---

## What Signum Does

Before a line is written, Signum defines correctness. After implementation, it verifies against it deterministically — not by asking another AI if the code looks right, but by running acceptance criteria the implementing agent never fully saw.

```
CONTRACT → EXECUTE → AUDIT → PACK
```

| Phase | What happens |
|-------|-------------|
| **CONTRACT** | Spec graded A–F. Low-quality specs blocked before implementation starts. Codex + Gemini validate the spec for gaps — before code is written, not after. |
| **EXECUTE** | Engineer implements against `contract-engineer.json` — the contract with holdout scenarios physically removed. It cannot see what it will be tested against. |
| **AUDIT** | Mechanic runs deterministic checks (zero LLM). Claude, Codex, and Gemini review the diff independently in parallel. Holdout scenarios run against the result. |
| **PACK** | Contract hash, base commit, audit results, and verdict assembled into `proofpack.json` — a tamper-evident artifact CI can gate on. |

---

## Key Features

### Spec quality gate
Before implementation starts, your spec is scored across six dimensions: Testability, Negative coverage, Clarity, Scope boundedness, Completeness, Boundary cases. Grade D (below 60) is a hard stop with specific feedback on what's missing. The gate runs on the *specification*, not the code.

### Holdout scenarios
The Contractor generates hidden acceptance criteria the Engineer never sees. When implementation is complete, holdouts run against the result — blind testing for cases the agent couldn't optimize for. Minimum counts enforced by risk level: 0 for low, 2 for medium, 5 for high.

### Data-level blinding
The Engineer reads `contract-engineer.json`, not `contract.json`. Holdout scenarios are physically removed from the file — not hidden by instruction. The agent cannot infer them from context or structure.

### Execution policy
`contract-policy.json` is derived from the contract before EXECUTE begins. It defines which tools the Engineer may use, which bash commands are denied, and which paths are in scope. Policy violations after execution are `AUTO_BLOCK`.

### Repo invariant contracts
Add `repo-contract.json` to your project root — invariants that must always hold, independent of task. Any regression is `AUTO_BLOCK`, regardless of task-level acceptance criteria results.

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

### Immutable audit chain
At user approval, Signum computes SHA-256 of the contract and records the timestamp. The base commit is captured before the Engineer runs. `proofpack.json` anchors the full chain: contract hash → approval timestamp → base commit → implementation diff → audit results.

### Multi-model audit panel
Claude, Codex, and Gemini review the diff independently in parallel. The Mechanic runs first — deterministic checks: lint, typecheck, new test failures (by name, not exit code). Then models weigh in. Critical findings from any model block.

---

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
│  checksums + auditChain → proofpack.json                │
└─────────────────────────────────────────────────────────┘
```

---

## Quick Start

```bash
# Install
claude plugin marketplace add heurema/emporium
claude plugin install signum@emporium

# Optional: external model CLIs for multi-model audit
# https://github.com/openai/codex
# https://github.com/google-gemini/gemini-cli

# Run — describe what you want to build
/signum "your task description"
```

Signum grades your spec, shows the contract for approval, implements with an automatic repair loop, audits from multiple angles, and produces `proofpack.json`.

---

## Privacy & Data

All orchestration runs inside Claude Code. External providers (Codex CLI, Gemini CLI) receive the diff only — never the full codebase. Signum degrades gracefully if either is unavailable. No API keys required beyond standard CLI auth. No telemetry. Artifacts stored in `.signum/` (auto-added to `.gitignore`).

---

## Requirements

- Claude Code v2.1+
- `git`, `jq`, `python3`
- Optional: [Codex CLI](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli)

---

## Status

We run Signum on Signum's own development. v3 is the first version we'd stake our own projects on.

---

## Documentation

- **[How it Works](docs/how-it-works.md)** — pipeline detail, agents, trust boundaries, limitations
- **[Reference](docs/reference.md)** — artifacts schema, troubleshooting, cost estimates

## Links

- [skill7.dev/development/signum](https://skill7.dev/development/signum)
- [github.com/heurema/signum](https://github.com/heurema/signum)
- [Report Issue](https://github.com/heurema/signum/issues)

## License

MIT
