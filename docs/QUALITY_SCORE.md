---
status: draft
owner: @vi
last_reviewed: 2026-04-10
review_cadence: quarterly
---

# signum — Quality Score

## Definition of Done
- Deterministic behavior changes in `lib/` must have a matching shell test or a clear extension of an existing one.
- Canonical behavior changes in `commands/signum.md` or `commands/init.md` must update the matching derived docs in the same bounded diff.
- Root-vs-overlay behavior differences must either be removed or documented in `docs/overlay-deviations.json`.
- Docs-only changes that affect operator understanding should pass doc parity checks.
- Prompt/orchestration-sensitive changes should run `python3 evals/run.py`; if behavior changes intentionally, update the matching fixtures/snapshots in the same diff.

## Repo-Specific Quality Dimensions

| Dimension | Minimum Bar | Evidence | Waiver Rule |
| --- | --- | --- | --- |
| Correctness | Deterministic scripts keep structured behavior and expected outputs | `tests/test-*.sh`, direct script runs | No waiver for silent behavior changes; document explicit scope if a test is impossible |
| Docs parity | Canonical-vs-derived docs remain aligned | `bash lib/doc-parity-check.sh`, `bash tests/test-doc-parity.sh` | Temporary warn-only findings are allowed only when a deviation is explicitly documented |
| Init/bootstrap quality | Init scanner/scaffold stays deterministic and brownfield-safe | `bash tests/test-init.sh`, `bash tests/test-init-harness-scaffold.sh` | No waiver for destructive overwrite behavior in MVP |
| Reliability | Critical user journeys stay explainable and testable | `docs/RELIABILITY.md`, matching tests/scripts | Gaps may be documented, not hidden |
| Security | Sensitive execution surfaces keep explicit review triggers and bounded behavior | `docs/SECURITY.md`, targeted script tests, pre-commit hooks | No waiver for widening trust boundaries without docs update |

## Review Policy
- **Blocking in practice**:
  - broken deterministic tests
  - undocumented schema drift
  - undocumented canonical-vs-overlay drift
  - unsafe widening of execution or provider boundaries
- **Warning-only for now**:
  - doc parity findings that are explicitly allowlisted
  - terminology/doc hygiene issues that do not alter runtime behavior

## Expected Checks by Change Type

| Change Type | Expected Checks |
| --- | --- |
| `lib/*.sh` deterministic behavior | matching `tests/test-*.sh` + direct script sanity run |
| `commands/*.md` behavior change | docs sync + relevant deterministic tests |
| init/bootstrap change | `tests/test-init.sh` and/or `tests/test-init-harness-scaffold.sh` |
| prompt/orchestration change | `python3 evals/run.py` + `bash tests/test-eval-harness.sh` |
| canonical/overlay doc change | `tests/test-doc-parity.sh` + `lib/doc-parity-check.sh` |
| schema change | schema consumers + docs/reference sync |

## Audit Trail
- Public behavior references: `README.md`, `docs/how-it-works.md`, `docs/reference.md`
- Planning trail: `docs/plans/*.md`, `docs/thin-cli-extraction-plan.md`
- Runtime artifact trail: `.signum/` and `proofpack.json`
- Intentional overlay exceptions: `docs/overlay-deviations.json`
