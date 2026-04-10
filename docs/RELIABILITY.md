---
status: draft
owner: @vi
last_reviewed: 2026-04-10
review_cadence: quarterly
---

# signum — Reliability

## Critical User Journeys

| Journey | Why it matters | Primary Surfaces | Current Evidence |
| --- | --- | --- | --- |
| Run `/signum <task>` end-to-end | Core product promise | `commands/signum.md`, `agents/`, `lib/`, schemas | README + reference docs + deterministic shell tests |
| Generate correct runtime artifacts in `.signum/` | Needed for auditability and CI gating | `commands/signum.md`, `lib/`, `.signum/` artifact contract | `docs/reference.md`, `docs/how-it-works.md` |
| Bootstrap project context with `/signum init` | Reduces missing-context failures in downstream repos | `commands/init.md`, `agents/init-synthesizer.md`, `lib/init-scanner.sh`, `lib/init-harness-scaffold.sh` | `tests/test-init.sh`, `tests/test-init-harness-scaffold.sh` |
| Keep root docs and overlays aligned | Prevents trust loss from doc drift | `docs/reference.md`, `docs/overlay-deviations.json`, `lib/doc-parity-check.sh` | `tests/test-doc-parity.sh`, `.github/workflows/doc-parity.yml` |

## Reliability Strategy
- Prefer deterministic shell checks over prompt-only guardrails.
- Emit structured JSON from verification scripts so orchestration can reason about failures mechanically.
- Treat doc drift as a reliability issue when it changes operator understanding of canonical behavior.
- Keep overlays explicit and audited instead of letting them drift silently.

## Failure Modes and Recovery

| Failure Mode | Detection | Current Recovery |
| --- | --- | --- |
| Canonical docs drift from actual behavior | `lib/doc-parity-check.sh` warnings | Fix docs or record a documented deviation |
| Deterministic script regression | Failing `tests/test-*.sh` | Reproduce in shell, patch script, add/update regression test |
| Init/bootstrap drift | `tests/test-init.sh`, `tests/test-init-harness-scaffold.sh` | Keep scanner/scaffold deterministic, avoid LLM-only behavior for structure |
| Overlay divergence becomes accidental | Parity warnings and deviation review | Promote to root, remove from overlay, or document in `docs/overlay-deviations.json` |
| Artifact contract changes without docs/schema sync | Schema/docs mismatch, review confusion | Update schema + reference docs + tests in one bounded diff |

## Operational Checks
- `bash tests/test-init.sh`
- `bash tests/test-init-harness-scaffold.sh`
- `bash tests/test-doc-parity.sh`
- `bash lib/doc-parity-check.sh`
- Other deterministic checks under `tests/` should be run when changing matching `lib/` surfaces.

## Current Gaps
- There is no single repo-wide smoke test that exercises the full `/signum` product flow end-to-end in CI.
- Most reliability evidence is still shell-script unit coverage plus documentation, not integrated scenario runs.
- Anti-entropy / recurring cleanup mode is planned but not yet a canonical root feature.
