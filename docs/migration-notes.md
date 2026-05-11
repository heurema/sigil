# Migration notes

This document explains compatibility and historical transitions users or maintainers may encounter in older docs, old runs, or compatibility code. Current runtime behavior is defined by `commands/signum.md`, `commands/init.md`, and `docs/reference.md`. This file is not the primary runtime reference.

## Artifact root migration

Older Signum material may describe a root-based artifact model where root `.signum/` or root `.signum/*` artifact paths are treated as the normal place for run evidence. Those paths may still appear in older runs, old documentation, and compatibility code.

The current canonical model uses `.signum/contracts/<contractId>/` as the active contract artifact root for normal run artifacts. Contract evidence, execution logs, audit outputs, and proofpacks belong under that contract directory.

Root `.signum/` is now a registry/state/archive/compatibility namespace. Root `.signum/contract.json` is only a legacy import or resume signal where current docs and code still support it.

For the maintained artifact inventory and current reference behavior, see `docs/artifact-path-inventory.md` and `docs/reference.md`.

## Proofpack schema evolution

Older docs or runs may mention proofpack schema `v4.6`. That era introduced the iterative audit repair loop and related CI or baseline-comparison evolution.

The `4.7` era added removal and cleanup evidence for contracts that remove files or carry cleanup obligations.

Current PACK behavior emits proofpack schema `4.8`, as shown by `commands/signum.md`, the PACK fragments, and the validator's runtime source-of-truth check. The current proofpack surface includes fields such as `contractId`, `releaseVerdict`, `riskLevel`, `timing`, `reviewCoverage`, `approval`, `checks.policy_scan`, and optional `ciContext`, `baselineComparison`, `iterativeAudit`, and `removalEvidence`.

Do not treat this section as the field table. For the schema and validator contract, use `lib/schemas/proofpack.schema.json`, `scripts/validate_proofpack.py`, and `docs/reference.md`.

## Init command migration

`/signum:init` is the canonical init command. The init command with a space between `signum` and `init` is not the current command and should not be documented as current usage.

Current supported flags are `--harness`, `--force`, and `--project-root <path>`. See `commands/init.md`.

## Compatibility guidance

Old runs may contain root `.signum/*` artifacts or legacy root contract files. New runs should use `.signum/contracts/<contractId>/` for normal run artifacts.

For docs and integrations, prefer the canonical command docs, reference docs, schema, and validator over these historical notes.
