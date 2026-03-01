# Sigil

> Risk-adaptive dev pipeline with adversarial code review

Sigil is a Claude Code plugin that turns a feature description into a complete development cycle — risk assessment, codebase mapping, architecture design, implementation, and multi-agent code review. One command, four phases.

**v1.1.0** adds the `diverge` build strategy: for complex changes, Sigil can dispatch three independent implementations (via arbiter) and let you choose the best solution before tests, observer, and review run on the winner.

Review rigor scales automatically with complexity. Low-risk changes get a fast single-reviewer pass. High-risk changes escalate to adversarial consensus: independent AI agents (Claude Reviewer + Skeptic + Codex + Gemini) review the same diff blind, with machine-validated findings and cross-provider verification.

```
/sigil add JWT authentication to the API
```

## Quick Start

<!-- INSTALL:START — auto-synced from emporium/INSTALL_REFERENCE.md -->
```bash
claude plugin marketplace add heurema/emporium
claude plugin install sigil@emporium
```
<!-- INSTALL:END -->

```bash
# Use — describe what you want to build
/sigil add user authentication with JWT
```

Sigil assesses risk, maps the codebase, presents a design for your approval, implements the code, and reviews it — all automatically.

## How It Works

```
┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Scope  │───>│ Explore  │───>│  Design  │───>│  Build   │
│ (bash)  │    │ (sonnet) │    │(son/opus)│    │ (sonnet) │
└─────────┘    └──────────┘    └──────────┘    └──────────┘
```

| Risk  | Explore | Design  | Build        | Review Strategy |
|-------|---------|---------|--------------|-----------------|
| low   | 1 agent | sonnet  | 1 agent      | simple (1 reviewer) |
| med   | 2 agents| opus    | 2 + observer | adversarial (Reviewer + Skeptic + Codex) |
| high  | 3 agents| opus    | 3 + observer | consensus (all providers, 2 rounds) |

## Key Features

- **4-phase pipeline**: Scope (zero-LLM) → Explore → Design (approval gate) → Build + Review
- **3 review strategies** auto-selected by risk: simple, adversarial, consensus
- **Diverge build strategy**: dispatch 3 independent implementations (Claude + Codex + Gemini via arbiter), pick the winner — then tests, observer, and review run normally on the selected solution
- **Machine-validated findings**: file existence, line range, evidence grep, scope check — hallucinated findings are silently dropped
- **Session resume**: interrupt and pick up where you left off
- **External AI optional**: Codex and Gemini provide independent review perspectives with explicit consent

## Privacy & Data

All orchestration runs inside Claude Code. External AI providers (Codex CLI, Gemini CLI) are **optional** — they require explicit consent and receive only the diff, never your full codebase. Use `skip-external` to opt out entirely. No API keys required. No telemetry. Artifacts stored in `.dev/` (auto-added to `.gitignore`).

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) v2.1.47+
- `git`, `jq`
- Optional: [Codex CLI](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli)

## Documentation

- **[How it Works](docs/how-it-works.md)** — architecture, review pipeline, trust boundaries
- **[Reference](docs/reference.md)** — usage examples, artifacts, troubleshooting, cost estimates

## Links

- [skill7.dev/development/sigil](https://skill7.dev/development/sigil)
- [Report Issue](https://github.com/heurema/sigil/issues)

## License

MIT
