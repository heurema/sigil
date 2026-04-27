---
status: draft
owner: @vi
last_reviewed: 2026-04-27
review_cadence: quarterly
---

# Signum Fragment Parity Inventory

This inventory classifies the relationship between shared, root-specific, and Claude overlay Signum command fragments after shared-source extraction. It is a parity map only; it does not change rendered command output.

Rendering remains guarded separately: `scripts/render_signum_command.py --check` must reproduce both checked-in runtime command files byte-for-byte.

## Inputs

- Shared fragment source: `commands/signum.shared.fragments/`
- Root manifest: `commands/signum.fragments/manifest.json`
- Claude overlay manifest: `platforms/claude-code/commands/signum.fragments/manifest.json`
- Machine-readable parity fixture: `tests/fixtures/signum-fragment-parity.json`
- Static guard: `tests/test-signum-fragment-parity.sh`

Logical fragment names strip the leading numeric prefix and `.md` suffix from the fragment path basename, so `110-final-output.md` and `120-final-output.md` both map to `final-output`. This avoids false drift from overlay's extra `phase-reconcile` fragment.

## Summary

| Class | Count | Logical fragments |
| --- | ---: | --- |
| `shared-source` | 5 | `header`, `archive-mode`, `close-mode`, `project-resolution`, `error-handling` |
| `divergent-bounded` | 8 | `init-command-redirect`, `explain-mode`, `setup`, `phase-contract`, `phase-execute`, `phase-audit`, `phase-pack`, `final-output` |
| `root-only` | 0 | none |
| `overlay-only` | 1 | `phase-reconcile` |
| `unknown` | 0 | none |

## Shared-source fragments

These fragments are referenced by both root and overlay manifests through the same repo-scoped shared files:

| Logical fragment | Shared source |
| --- | --- |
| `header` | `commands/signum.shared.fragments/00-header.md` |
| `archive-mode` | `commands/signum.shared.fragments/30-archive-mode.md` |
| `close-mode` | `commands/signum.shared.fragments/40-close-mode.md` |
| `project-resolution` | `commands/signum.shared.fragments/50-project-resolution.md` |
| `error-handling` | `commands/signum.shared.fragments/120-error-handling.md` |

The local root/overlay duplicates for these logical fragments were removed. The parity guard fails if a stale local duplicate with the same logical name reappears in either manifest directory.

## Divergent-bounded fragments

| Logical fragment | Reason IDs | Notes |
| --- | --- | --- |
| `init-command-redirect` | `overlay-init-actualize` | Claude overlay includes the overlay-only `init --actualize` redirect. |
| `explain-mode` | `overlay-explain-summary` | Claude overlay explain text reflects its shorter platform flow summary. |
| `setup` | `legacy-cleanup-order` | Cleanup list order differs while the explicit cleanup token set stays bounded by existing parity guards. |
| `phase-contract` | `overlay-contract-flow` | Claude overlay keeps platform-specific contractor retry and module lifecycle behavior. |
| `phase-execute` | `overlay-execute-flow` | Claude overlay keeps platform-specific snapshot and scope-gate behavior. |
| `phase-audit` | `overlay-audit-flow` | Claude overlay keeps platform-specific reviewer failure and repair-loop behavior. |
| `phase-pack` | `root-optional-removal-evidence`, `root-proofpack-index` | Root PACK can emit optional `removalEvidence` and append to the proofpack index; overlay handles cleanup obligations in `RECONCILE` and does not currently append the root proofpack index. |
| `final-output` | `root-final-output-cleanup`, `overlay-reconcile-phase` | Root has bounded Final Output archive/delete/finalize cleanup; overlay Final Output reports RECONCILE results. |

## Overlay-only fragments

| Logical fragment | Reason IDs | Notes |
| --- | --- | --- |
| `phase-reconcile` | `overlay-reconcile-phase` | Claude overlay has an extra `RECONCILE` phase for cleanup obligations after PACK. |

## Root-only fragments

None.

## Shared-source manifest rule

A shared fragment reference is explicit and repo-scoped:

```json
{ "path": "commands/signum.shared.fragments/00-header.md", "scope": "repo" }
```

Manifest-local string entries still refer to fragments beside that manifest. The renderer rejects absolute paths, `..` traversal, duplicate fragment entries, missing fragments, and fragments outside the repository root.

## Next step

Future decomposition can either keep this shared-source baseline stable or consider parameterized templates for selected divergent fragments. Do not share a divergent fragment until its reason IDs are resolved or intentionally preserved.
