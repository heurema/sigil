---
status: draft
owner: @vi
last_reviewed: 2026-04-10
review_cadence: monthly
---

# signum — Plans Index

## Canonical Planning Rule
- `docs/plans/2026-03-15-large-project-support-roadmap.md` is the current top-level roadmap for large-project / harness follow-up work.
- Root command files remain canonical for shipped behavior; plan docs must not be treated as behavior truth when they disagree with `commands/signum.md`.
- When a capability ships, update the roadmap status in the same change or immediately after. Do not leave “not started” on already shipped behavior.

## Idea Intake Rule
- Before adopting a new Signum idea from adjacent tools, research, or competitor repos, first compare it against the current approaches and stated directions of relevant providers (`Anthropic`, `OpenAI`, `Google`, and others when relevant).
- Prefer provider-aligned ideas over clever local additions when the tradeoff is unclear.
- Until that comparison exists, treat the idea as exploratory only — not committed roadmap work.

## Active Workstreams

| Workstream | Source Doc | Status | Notes |
| --- | --- | --- | --- |
| Harness legibility / anti-drift | `docs/plans/2026-03-15-large-project-support-roadmap.md` | active | Current focus: parity checks, harness bootstrap, anti-entropy follow-up |
| Root anti-entropy / RECONCILE design | `docs/plans/2026-04-10-root-anti-entropy-reconcile-design.md` | active | Current recommendation: report-only anti-entropy first, no root Phase 5 mutation |
| Thin CLI extraction | `docs/thin-cli-extraction-plan.md` | active | Tracks deterministic-core extraction to Rust / `signum-core` |
| Iterative audit behavior | `docs/plans/2026-03-15-iterative-audit-design.md` | active | Design reference for review/fix loop behavior |

## Recent Resolved Planning Debt
- Canonical source policy is now documented in `docs/reference.md`.
- Root-vs-overlay `RECONCILE` divergence is now tracked as an explicit deviation in `docs/overlay-deviations.json`.
- Warn-only doc parity CI now exists through `lib/doc-parity-check.sh` and `.github/workflows/doc-parity.yml`.
- `init --harness` MVP now exists to bootstrap repo-level harness docs in addition to project intent/glossary.

## Next Planned Steps
- Add an evaluation harness first; this is the current lowest-risk provider-aligned follow-up for prompt/orchestration work.
- Decide which docs should remain hand-maintained versus eventually derived/generated.
- Implement the first report-only anti-entropy artifact without changing the canonical root phase model.
- Extend thin-cli planning from extraction inventory to a stable protocol/event model for `signum-core`.
- Decide whether `README.md` and `CHANGELOG.md` need an immediate sync pass for `init --harness`.

## Archive Rules
- Keep active planning docs under `docs/plans/`.
- When a plan is superseded, add a note pointing to the newer plan instead of deleting history.
- When shipped behavior changes, update both the plan status and any canonical/derived-doc policy that references it.
