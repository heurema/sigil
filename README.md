# Sigil

> Evidence-driven development pipeline with multi-model code review

Sigil is a Claude Code plugin that turns a task description into a complete development cycle: contract generation, implementation with repair loop, and parallel audit by independent AI models. One command, four phases, verifiable output.

Contract-first, multi-model-verified, proof-packaged.

```
/sigil "add JWT authentication to the API"
```

## Quick Start

<!-- INSTALL:START — auto-synced from emporium/INSTALL_REFERENCE.md -->
```bash
claude plugin marketplace add heurema/emporium
claude plugin install sigil@emporium
```
<!-- INSTALL:END -->

```bash
# Run — describe what you want to build
/sigil "your task description"
```

Sigil generates a contract, shows it for approval, implements the code with an automatic repair loop, audits the result with multiple independent AI models, and produces a `proofpack.json` artifact.

## Architecture

```
CONTRACT → EXECUTE → AUDIT → PACK
                       ↓
                  ┌────┼────┐
               Claude Codex Gemini
                  └────┼────┘
                       ↓
                  proofpack.json
```

| Phase | Agent | Output |
|-------|-------|--------|
| CONTRACT | Contractor (haiku/sonnet) | `contract.json` |
| EXECUTE | Engineer (sonnet) + repair loop | feature branch, commits |
| AUDIT | Claude Opus + Codex + Gemini | per-provider findings |
| PACK | Synthesizer (sonnet) | `proofpack.json` |

## Key Features

- **Multi-model audit panel**: Claude Opus, Codex, and Gemini each review the diff independently. Findings are cross-validated and synthesized with deterministic rules — any critical finding blocks, important findings confirmed by 2+ providers warn.
- **Contract-driven**: Every run starts with a structured `contract.json` defining acceptance criteria, affected files, and test strategy. Implementation is measured against it.
- **Proofpack output**: `proofpack.json` is a CI-gate artifact — it records the contract, all audit findings, verdict, execution log, and provider availability in a single verifiable file.
- **Repair loop**: The engineer agent retries failing tests up to 3 times before halting, reducing noise from transient build issues.
- **CLI adapter for external models**: Codex and Gemini are invoked via their CLIs with explicit user consent. Sigil degrades gracefully if either is unavailable or unauthenticated.
- **Finding validation**: Every AI finding is validated against the actual diff — file existence, line range bounds, evidence grep, scope check. Hallucinated findings are dropped before synthesis.

## Privacy & Data

All orchestration runs inside Claude Code. External providers (Codex CLI, Gemini CLI) require explicit consent and receive the diff only — never the full codebase. Use `skip-external` to run Claude-only audit. No API keys required beyond standard CLI auth. No telemetry. Artifacts stored in `.dev/` (auto-added to `.gitignore`).

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) v2.1+
- `git`, `jq`
- Optional: [Codex CLI](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli)

## Documentation

- **[How it Works](docs/how-it-works.md)** — pipeline, agents, multi-model audit, trust boundaries, limitations
- **[Reference](docs/reference.md)** — usage examples, artifacts, troubleshooting, cost estimates

## Links

- [skill7.dev/development/sigil](https://skill7.dev/development/sigil)
- [Report Issue](https://github.com/heurema/sigil/issues)

## Version

2.0.0

## License

MIT
