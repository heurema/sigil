---
status: draft
owner: @vi
last_reviewed: 2026-04-10
review_cadence: quarterly
---

# signum — Architecture

## System Overview
- Signum is a contract-first development pipeline for Claude Code that defines correctness before implementation and packages proof artifacts after audit.
- The canonical execution flow is `CONTRACT -> EXECUTE -> AUDIT -> PACK`.
- The product mixes two layers:
  - deterministic shell/JSON verification in `lib/`
  - LLM orchestration in `commands/` and `agents/`
- The main output artifact is `proofpack.json` under the active contract artifact root (`.signum/contracts/<contractId>/proofpack.json`), intended for CI gating and auditability.

## Main Components

| Component | Path | Responsibility | Depends On | Notes |
| --- | --- | --- | --- | --- |
| Canonical orchestrator | `commands/signum.md` | Defines the root pipeline behavior | `agents/`, `lib/`, schemas | Source of truth for core pipeline |
| Init orchestrator | `commands/init.md` | Bootstraps project context and harness docs | `agents/init-synthesizer.md`, `lib/init-scanner.sh`, `lib/init-harness-scaffold.sh` | Separate from main pipeline |
| Agent prompts | `agents/` | Contract generation, implementation, review, synthesis | Claude Code subagents / CLIs | LLM-dependent layer |
| Deterministic checks | `lib/` | Policy, DSL, prose, overlap, staleness, ADR, glossary, receipt helpers | `jq`, `python3`, shell | Should stay testable and structured |
| Schemas | `lib/schemas/` | Contract / proofpack / module manifest schemas | JSON consumers and docs | Compatibility-sensitive |
| Test suite | `tests/` | Shell tests for deterministic scripts and contracts | `bash`, `jq`, fixture repos | Main trust layer for shell logic |
| Docs / plans | `docs/` | Reference, architecture explanations, roadmaps, research | Root commands + code | Derived unless explicitly canonical |
| Platform overlays | `platforms/` | Surface-specific command/docs variants | Root commands/docs | Must not silently drift from root |

## Critical Flows

### 1. Main product flow
1. User runs `/signum <task>`.
2. Contractor creates canonical `contract.json` under the active contract artifact root, applies spec-quality checks, and prepares execution policy.
3. Engineer implements against the redacted contract.
4. AUDIT runs deterministic checks + holdouts + multi-model review panel.
5. PACK assembles `proofpack.json` under the active contract artifact root.

### 2. Project-context bootstrap flow
1. User runs `/signum init`.
2. `lib/init-scanner.sh` extracts deterministic repo signals.
3. `agents/init-synthesizer.md` turns those signals into `project.intent.md` and `project.glossary.json`.
4. Optional `--harness` mode adds deterministic repo-level docs through `lib/init-harness-scaffold.sh`.

### 3. Documentation/parity control loop
1. Root docs declare canonical-vs-derived policy in `docs/reference.md`.
2. Known overlay deviations are listed in `docs/overlay-deviations.json`.
3. `lib/doc-parity-check.sh` validates parity assumptions and emits warnings in CI.

## State and Data
- `.signum/` is the runtime workspace for contracts, patches, mechanic reports, reviews, and proofpacks.
- `project.intent.md` and `project.glossary.json` are project-level upstream context inputs that can affect contract generation.
- `modules.yaml` is the repo’s lightweight module inventory and lifecycle manifest.
- `docs/plans/*.md` and `docs/research/*.md` hold planning and research context, but are derived documentation, not runtime state.

## Trust Boundaries
- **Local deterministic boundary**: shell scripts in `lib/`, schemas, receipt/proofpack assembly.
- **LLM boundary**: prompts and orchestration in `commands/` and `agents/`.
- **External review boundary**: Codex/Gemini CLI review surfaces receive diffs, not the full repo, per current docs.
- **Overlay boundary**: `platforms/` can adapt surfaces but must not redefine canonical core behavior without an explicit deviation record.

## Current Architectural Direction
- Near-term priority is harness legibility and anti-drift, not adding more model complexity.
- Root docs and commands now explicitly separate canonical behavior from overlay behavior.
- `docs/thin-cli-extraction-plan.md` tracks the longer-term split between deterministic core and orchestration wrappers.

## Known Risks
- Root-vs-overlay drift can reappear if command/docs changes are not reflected in parity policy.
- Large markdown command files are hard to diff mentally; they need mechanical parity checks.
- The repo still mixes product docs, research, plans, and overlays in one tree, which increases doc entropy.
- Thin CLI extraction is planned but not yet implemented, so deterministic and orchestration layers are still tightly coupled by repo layout.
