---
status: draft
owner: @vi
last_reviewed: 2026-04-26
---

# Signum artifact path inventory

This inventory is maintained with `tests/test-artifact-path-inventory.sh` and `tests/fixtures/artifact-path-allowlist.txt`. It is a guard before canonical artifact migration; it does not change runtime behavior.

See `docs/legacy-root-helper-callsite-inventory.md` for the separate call-site map of `LEGACY_ROOT_COMPAT` helpers.

## Canonical model

Canonical run artifacts live under the active contract artifact root:

```text
.signum/contracts/<contractId>/
```

Root `.signum/*` artifact files are compatibility or legacy migration inputs only. Root `.signum/contracts/`, `.signum/archive/`, project-level indexes, policy, metrics, rebuildable derived cache, and session files are registry/state surfaces, not per-run working-set artifact roots.

Codebase Awareness run evidence (`implementation_context.json`, `reuse_candidates.json`, `reuse_decision.json`, `duplicate_scan.json`, `reuse_summary.json`) belongs under the active contract artifact root; `.signum/cache/` remains rebuildable project-level derived state.

## Live root `.signum` usage groups

| Group | Files | Current usage | Recommendation |
| --- | --- | --- | --- |
| Legacy import and cleanup in slash command | `commands/signum.md`, `platforms/claude-code/commands/signum.md` | Reads legacy `.signum/contract.json` and `.signum/execution_context.json`; migrates dynamic `.signum/$rel` paths into the active contract; removes explicit root artifact files on restart; keeps repeated `ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"` fallback. | Keep temporarily; isolate next before migration. |
| Compatibility helpers | `lib/contract-dir.sh`, `platforms/claude-code/lib/contract-dir.sh` | `sync_contract_artifacts`, `remove_root_artifact_view`, `purge_root_working_set_views`, `link_active_artifact`, `ensure_active_artifact_dir`, `reset_active_artifact`, and `promote_root_artifact_to_active` operate on dynamic `.signum/${rel}` root compatibility views and are explicitly marked as the legacy root artifact compatibility layer. Runtime behavior is unchanged for the helpers themselves; normal-runtime reset and PACK sync call sites now use canonical-only helpers. | Keep temporarily; migrate remaining explicit legacy cleanup/import paths later. |
| CI and scanner fallback | `lib/signum-ci.sh`, `platforms/claude-code/lib/signum-ci.sh`, `lib/contract-injection-scan.sh` | Fall back to root `.signum/proofpack.json` or `.signum/contract.json` when canonical contract artifacts are unavailable. | Keep as explicit migration fallback; migrate after compatibility layer is isolated. |
| Project-level state, policy, metrics, and derived cache | `commands/signum.md`, `platforms/claude-code/commands/signum.md`, `lib/proofpack-index.sh`, `lib/metric-ratchet.sh`, `lib/pack-anti-entropy.sh`, `lib/policy-resolver.sh`, `lib/session-manager.sh` | Uses `.signum/proofpack-index.jsonl`, `.signum/metrics/ratchet-report.json`, `.signum/policy.toml`, `.signum/cache/`, and `.signum/session.json`. `.signum/cache/` is rebuildable derived state for project-level Codebase Awareness cache files, not an active contract artifact root. `.signum/cache/file-digests-v1.json` is a rebuildable Codebase Awareness project cache used for bounded/incremental lexical scanning; it is not active contract root evidence, not run-scoped evidence, and not a proofpack payload. These are project-level state/config/cache surfaces, not per-run root artifacts. | Keep; do not mix with per-run artifact migration. |
| Init/bootstrap compatibility inputs | `scripts/init_scanner.py`, `platforms/claude-code/scripts/init_scanner.py` | Ignores `.signum` during project scans; can read `.signum/project.glossary.json` and `.signum/project.intent.md` as legacy/bootstrap inputs. Shell wrappers remain thin entrypoints. | Keep; separate from run artifact migration. |
| Public docs | `README.md`, `docs/how-it-works.md`, `platforms/claude-code/docs/how-it-works.md` | Describe root `.signum/` as registry/state/archive namespace and `.signum/contract.json` as legacy import signal. | Keep docs aligned with migration state. |

## Explicit root artifact names currently seen in live command cleanup/import

The live command docs mention these root per-run artifact names only in legacy resume/import/restart paths:

```text
approval.json
audit_iteration_log.json
audit_summary.json
baseline.json
clover_report.json
combined.patch
contract-engineer.json
contract-hash.txt
contract-policy.json
contract.json
contract.json.tmp
execute_log.json
execution_context.json
flaky_tests.json
holdout_report.json
intent_check.json
iteration_delta.patch
mechanic_report.json
policy_scan.json
policy_violations.json
proofpack.json
repair_brief.json
repo_contract_baseline.json
repo_contract_violations.json
review_prompt_codex.txt
review_prompt_gemini.txt
spec_quality.json
spec_validation.json
```

## Root/overlay consistency notes

- `lib/contract-dir.sh` and `platforms/claude-code/lib/contract-dir.sh` are byte-for-byte consistent for legacy root compatibility helpers, with canonical helpers and the legacy root artifact compatibility layer explicitly separated by comments.
- `commands/signum.md` and `platforms/claude-code/commands/signum.md` have matching legacy resume/import/fallback structure and matching counts for the repeated artifact-root fallback.
- `commands/signum.md` and `platforms/claude-code/commands/signum.md` both clean `.signum/policy_scan.json` and `.signum/policy_violations.json` in the legacy restart cleanup list.

## Historical and test references

The guard intentionally scans live/runtime-relevant files only. It does not fail on historical references in `docs/plans/`, `docs/research/`, changelog/history, synthetic fixtures, or tests that intentionally construct legacy `.signum/*` layouts.
