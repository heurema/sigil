---
status: draft
owner: @vi
last_reviewed: 2026-04-26
review_cadence: quarterly
---

# Signum Command Structure Baseline

This inventory captures the current `commands/signum.md` and Claude overlay command structure before any future decomposition into fragments or generated output. It is a test-backed baseline only; it does not change runtime behavior.

## Command files

- Root canonical command: `commands/signum.md`
- Claude Code overlay command: `platforms/claude-code/commands/signum.md`

Root remains the canonical command surface. Overlay differences must stay bounded, documented, and guarded by deterministic tests.

## Shared high-level flow

Both command files preserve this shared core pipeline order:

1. `## Phase 1: CONTRACT`
2. `## Phase 2: EXECUTE`
3. `## Phase 3: AUDIT`
4. `## Phase 4: PACK`
5. `## Final Output`
6. `## Error Handling`

Shared pre-pipeline sections include:

- `## Init Command Redirect`
- `## Explain Mode`
- `## Archive Mode`
- `## Close Mode`
- `## Project Resolution`
- `## Setup`

## Critical runtime markers

The structure guard tracks these marker groups instead of snapshotting full prose:

- Project root resolution: `SIGNUM_PROJECT_ROOT`, explicit project placeholder, `git rev-parse --show-toplevel`, and current-directory-only fallback.
- Canonical artifact root: `.signum/contracts`, `active_artifact_root`, and `ARTIFACT_ROOT`.
- PACK/proofpack assembly: `schemaVersion`, `signumVersion`, `contractId`, `decision`, and the `checks` object with mechanic, holdout, policy scan, reviews, and audit summary envelopes.
- Canonical replacements for migrated legacy helpers: `reset_canonical_active_artifact` and `verify_canonical_contract_artifacts`.
- Forbidden regressions: old home-directory project scans and normal-runtime `reset_active_artifact` / `sync_contract_artifacts` command calls.

## Observed/bounded root-overlay differences

- Claude overlay has an extra `## Phase 5: RECONCILE` phase. This is also recorded in `docs/overlay-deviations.json`.
- Root has a Step 4.5 Final Output archive/delete/finalize flow. Its three `purge_root_working_set_views` calls are classified as `legacy-final-output-cleanup`: cleanup-only, bounded, and not shared normal-runtime behavior. Claude overlay Final Output has zero equivalent calls.
- Root and Claude overlay PACK both emit the validator-required receipt-compatible proofpack fields: `releaseVerdict`, `timing`, and `reviewCoverage`. This was aligned after the Step 23 baseline exposed the drift.
- Root has an optional `removalEvidence` proofpack extension for contracts with `removals` or `cleanupObligations`. It is not validator-required and remains root-only because Claude overlay resolves cleanup obligations later in `RECONCILE`; emitting root-style fulfilled evidence before that phase would be misleading. The validator accepts proofpacks with and without this optional field and validates its shape when present.

## Guard files

- Marker fixture: `tests/fixtures/signum-command-structure.json`
- Static test: `tests/test-signum-command-structure.sh`
- Fragment renderer: `scripts/render_signum_command.py`
- Root manifest: `commands/signum.fragments/manifest.json`
- Claude overlay manifest: `platforms/claude-code/commands/signum.fragments/manifest.json`
- Fragment parity inventory: `docs/signum-fragment-parity.md`
- Shared fragments: `commands/signum.shared.fragments/`

The guard intentionally avoids full-file snapshots so harmless wording changes can proceed while loss of key phases, proofpack markers, canonical artifact markers, project-root safety markers, or bounded legacy exceptions fails deterministically.

## Fragment renderer

The checked-in runtime command files remain `commands/signum.md` and `platforms/claude-code/commands/signum.md`. The fragment renderer is a deterministic maintenance tool: manifests list shared and platform-specific fragments in exact order, and `scripts/render_signum_command.py --check` must reproduce each runtime command byte-for-byte. Future command edits should update fragments, render the runtime file, and keep `tests/test-signum-command-renderer.sh` passing.

Root/overlay fragment parity is tracked by `tests/fixtures/signum-fragment-parity.json` and `tests/test-signum-fragment-parity.sh`. The parity inventory classifies `shared-source` fragments, bounded divergent fragments, and overlay-only fragments before any future parameterized-fragment work.
