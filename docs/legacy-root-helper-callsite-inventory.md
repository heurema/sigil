---
status: draft
owner: @vi
last_reviewed: 2026-04-26
---

# Legacy root helper call-site inventory

This inventory is maintained with `tests/test-legacy-root-helper-callsites.sh` and `tests/fixtures/legacy-root-helper-callsite-allowlist.txt`. The inventory itself does not change runtime behavior; migration notes below record subsequent targeted call-site changes.

## Helpers

The current `LEGACY_ROOT_COMPAT` helper set is:

- `sync_contract_artifacts`
- `remove_root_artifact_view`
- `purge_root_working_set_views`
- `link_active_artifact`
- `ensure_active_artifact_dir`
- `reset_active_artifact`
- `promote_root_artifact_to_active`

## `sync_contract_artifacts` characterization

`sync_contract_artifacts <contractId> <path...>` remains a legacy root compatibility helper.

Observed behavior:

- Inputs: one contract id and one or more relative artifact paths.
- Canonical side effects: creates the canonical contract directory if needed, then copies each existing root working-set source into `.signum/contracts/<contractId>/<relative_path>`.
- Root compatibility side effects: reads from root `.signum/<relative_path>` sources; it does not write, create, or update root compatibility views.
- Direction: root-to-canonical only. It does not copy canonical artifacts back to root.
- Missing root source: no-op for that relative path; existing canonical artifacts remain untouched, and no root artifact is materialized from canonical.
- Directories: copies directory contents into the matching canonical directory without nesting the directory name.
- Symlink/self-copy case: if root source and canonical destination resolve to the same path, the helper skips that path.

Step 12 replaced the normal-runtime PACK completed-contract calls with canonical-only `verify_canonical_contract_artifacts`. That helper reports canonical artifact presence and does not read, write, import, or materialize root compatibility views.

## Final Output cleanup characterization

The remaining root-only `purge_root_working_set_views` difference is kept as explicit `legacy-final-output-cleanup`.

Root `commands/signum.md` has three Final Output cleanup calls:

1. `AUTO_OK` finalize flow: `finalize_run()` archives canonical artifacts, appends session notes, clears the active contract, then purges root compatibility views.
2. Manual `archive` choice: archives canonical artifacts, clears the active contract, then purges root compatibility views.
3. Manual `delete` choice: clears the active contract and purges root compatibility views without archive.

All three calls are cleanup-only. They do not create, import, promote, or sync root artifacts; they only delete root compatibility views after canonical artifacts were archived or the user chose delete.

Claude overlay `platforms/claude-code/commands/signum.md` has no equivalent Step 4.5 Final Output finalize/archive/delete flow; adding it would be a larger overlay behavior change. Therefore this step does not synchronize overlay Final Output behavior. The divergence is bounded and guarded: root Final Output has exactly three `purge_root_working_set_views` calls and the overlay Final Output has zero `LEGACY_ROOT_COMPAT` helper calls.

## Live/runtime call sites

| Category | File | Helpers | Count | Notes |
| --- | --- | --- | ---: | --- |
| definition | `lib/contract-dir.sh` | all seven helpers | 7 | Root helper definitions. |
| definition | `platforms/claude-code/lib/contract-dir.sh` | all seven helpers | 7 | Claude overlay helper definitions; byte-for-byte mirror of root. |
| legacy-resume-import-restart | `lib/contract-dir.sh` | `remove_root_artifact_view`, `link_active_artifact` | 5 | Helper-internal composition for purging, relinking, ensuring, and resetting root compatibility views. |
| legacy-resume-import-restart | `platforms/claude-code/lib/contract-dir.sh` | `remove_root_artifact_view`, `link_active_artifact` | 5 | Same as root helper internals. |
| legacy-archive-close-cleanup | `commands/signum.md` | `purge_root_working_set_views` | 2 | Explicit archive/close mode cleanup when the archived/closed contract was active. |
| legacy-archive-close-cleanup | `platforms/claude-code/commands/signum.md` | `purge_root_working_set_views` | 2 | Same explicit archive/close mode cleanup as root. |
| legacy-final-output-cleanup | `commands/signum.md` | `purge_root_working_set_views` | 3 | Root-only Step 4.5 Final Output finalize/archive/delete cleanup. Bounded exception; overlay has no Step 4.5 cleanup flow. |
| legacy-resume-import-restart | `commands/signum.md` | `promote_root_artifact_to_active`, `remove_root_artifact_view` | 3 | Legacy root import and restart cleanup. |
| legacy-resume-import-restart | `platforms/claude-code/commands/signum.md` | `promote_root_artifact_to_active`, `remove_root_artifact_view` | 3 | Same legacy root import and restart cleanup as root. |

No shared root/overlay normal-runtime `LEGACY_ROOT_COMPAT` helper call sites remain after the canonical reset and PACK sync migrations.

## Test call sites

| Category | File | Count | Notes |
| --- | --- | ---: | --- |
| test | `tests/test-contract-dir.sh` | 22 | Behavioral coverage for root compatibility helpers. |
| test | `platforms/claude-code/tests/test-contract-dir.sh` | 22 | Mirrored behavioral coverage for the overlay helper copy. |

## Docs/prose mentions

`docs/artifact-path-inventory.md`, `CHANGELOG.md`, and `platforms/claude-code/CHANGELOG.md` mention one or more helper names as prose/history, not executable runtime call sites. Static grep assertions in tests are also prose-like references and are intentionally not counted as runtime calls.

## Root/overlay consistency notes

- `lib/contract-dir.sh` and `platforms/claude-code/lib/contract-dir.sh` have identical definition and helper-internal call counts.
- Root and Claude overlay commands have matching counts for explicit archive/close cleanup, legacy import, and restart cleanup call sites.
- Root `commands/signum.md` intentionally has three additional `purge_root_working_set_views` call sites in Final Output archive/delete/finalize handling. The Claude overlay has no equivalent Step 4.5 cleanup flow. This is now classified as `legacy-final-output-cleanup` and guarded by exact counts.

## Migration candidates

Completed in the canonical reset migration step:

- `reset_active_artifact` normal-runtime calls in iterative repair/audit flow were replaced with canonical-only `reset_canonical_active_artifact`.

Completed in the canonical PACK sync migration step:

- `sync_contract_artifacts` normal-runtime calls in PACK completed-contract sync were replaced with canonical-only `verify_canonical_contract_artifacts`.

Resolved in the Final Output cleanup characterization step:

- Root-only `purge_root_working_set_views` Final Output calls are kept as bounded `legacy-final-output-cleanup` because they are cleanup-only and the Claude overlay lacks the surrounding Step 4.5 flow.

Keep explicit legacy resume/import/restart/archive/close cleanup paths until explicit legacy migration support is removed.
