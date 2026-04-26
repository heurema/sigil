---
status: draft
owner: @vi
last_reviewed: 2026-04-10
review_cadence: quarterly
---

# AGENTS.md

## Purpose
- Give human and AI contributors a short map of the repo surfaces that matter first.
- Keep repo-specific working rules in one file and link to deeper docs instead of duplicating them.
- Make it obvious which changes are just docs, which change deterministic core behavior, and which change LLM orchestration.

## Agent Entry Points

| Surface | Path | Role | Owner | Notes |
| --- | --- | --- | --- | --- |
| Primary product entry point | `commands/signum.md` | Canonical pipeline behavior (`CONTRACT -> EXECUTE -> AUDIT -> PACK`) | `@vi` | Source of truth for core Signum behavior |
| Init/bootstrap entry point | `commands/init.md` | Bootstraps `project.intent.md`, `project.glossary.json`, and optional harness docs | `@vi` | Root variant; Claude overlay lives under `platforms/claude-code/commands/init.md` |
| LLM prompts | `agents/` | Contractor, engineer, reviewer, synthesizer, init synthesizer prompts | `@vi` | Changes here affect agent behavior directly |
| Deterministic core | `lib/` | Shell checks, DSL runner, scanners, state/policy helpers | `@vi` | Prefer tests for every behavioral change |
| Schemas and contracts | `lib/schemas/` | Contract / proofpack / modules schemas | `@vi` | Treat schema changes as compatibility-sensitive |
| Platform overlays | `platforms/` | Surface-specific command/docs variants | `@vi` | Root command/docs remain canonical unless an overlay deviation is explicitly documented |
| Verification surface | `tests/` | Shell tests for deterministic behavior | `@vi` | If a deterministic behavior changes, add/update a test |

## Repo-Specific Rules
- Treat root `commands/signum.md` as the canonical source for pipeline behavior. See `docs/reference.md`.
- Treat `platforms/*/commands/*.md` as overlays, not peer sources of truth. Intentional deviations must be documented in `docs/overlay-deviations.json`.
- Prefer deterministic shell/JSON changes in `lib/` over adding more model behavior.
- If a change touches core behavior, update the matching docs or parity checks in the same diff.
- Keep changes bounded: docs-only, deterministic-core, or prompt/orchestration. Do not mix all three unless the change is impossible to split.
- When changing verification logic, prefer shell tests in `tests/` and keep outputs structured JSON.

## High-Risk Paths
- `commands/signum.md` — canonical orchestration behavior
- `agents/contractor.md`, `agents/engineer.md`, `agents/synthesizer.md`, `agents/reviewer-claude.md` — model prompts
- `lib/dsl-runner.sh` — verify DSL execution surface
- `lib/policy-scanner.sh`, `lib/policy-resolver.sh` — execution policy enforcement
- `lib/contract-injection-scan.sh` — prompt/contract injection defense
- `lib/schemas/*.json` — compatibility-sensitive contract/proofpack formats

## First Reads By Task Type
- **Understand the product**: `README.md`, `project.intent.md`, `docs/how-it-works.md`
- **Change core pipeline behavior**: `commands/signum.md`, `docs/reference.md`, matching `tests/*`
- **Change init/bootstrap behavior**: `commands/init.md`, `agents/init-synthesizer.md`, `lib/init-scanner.sh`, `lib/init-harness-scaffold.sh`, `tests/test-init*.sh`
- **Change docs/parity policy**: `docs/reference.md`, `docs/overlay-deviations.json`, `lib/doc-parity-check.sh`, `tests/test-doc-parity.sh`
- **Change future architecture direction**: `docs/plans/2026-03-15-large-project-support-roadmap.md`, `docs/thin-cli-extraction-plan.md`

## Update Protocol
- Update this file when a new agent-facing surface, canonical source, or high-risk path is introduced.
- Keep this file short; move detailed rationale into `ARCHITECTURE.md`, `docs/SECURITY.md`, `docs/RELIABILITY.md`, or `docs/QUALITY_SCORE.md`.
- Review after major pipeline, schema, or platform overlay changes.

## Review guidelines
- First check whether the PR should exist at all: non-trivial changes need linked Issue or Discussion intent before code review.
- Prefer no-code alternatives when possible: docs, configuration, process changes, or clearer existing workflows beat new code.
- Do not recommend adding dependencies unless the benefit is explicit and stdlib/built-in options are insufficient.
- Treat workflow, dependency, auth, security, eval/subprocess/shell, install scripts, public API, schema, command behavior, and runtime behavior changes as high-risk.
- For high-risk PRs, ask for maintainer attention instead of continuing ordinary review unless `maintainer/override-intake` is present.
- Public comments must be polite, concise, and actionable.
- Do not publish contributor trust scores.
