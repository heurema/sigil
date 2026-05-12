# Signum

Signum is a contract-first proof gate for agentic software changes: it turns a task into a reviewed contract, executes against that contract, audits the result, and packages evidence that humans and CI can inspect.

## Status

Signum is an active, experimental baseline for local deterministic development and review workflows. It is not a production certification system.

The canonical runtime docs are:

- `commands/signum.md` for the main `CONTRACT → EXECUTE → AUDIT → PACK` pipeline.
- `commands/init.md` for project bootstrap with `/signum:init`.

This README is an entry point, not the complete runtime specification. Use `docs/reference.md` when exact behavior matters.

## What Signum does

Signum follows one mental model:

```text
CONTRACT → EXECUTE → AUDIT → PACK
```

First it defines acceptance criteria and scope, then it implements against that contract, audits deterministic and model-assisted evidence, and writes a proofpack for review or CI gating.

## Install

Signum expects this local toolchain:

```text
bash
git
jq
python3
```

For Claude Code, install the plugin from the Emporium marketplace:

```bash
claude plugin marketplace add heurema/emporium
claude plugin install signum@emporium
claude "/signum explain"
```

For Codex App, Signum ships plugin metadata in this repository: `.codex-plugin/plugin.json`, `.agents/plugins/marketplace.json`, and `platforms/codex/.codex-plugin/plugin.json`. In **Plugins -> Add marketplace**, use:

```text
Source: heurema/signum
Git ref: main
Sparse paths: leave blank
```

After the marketplace is added, it appears in the Plugins source dropdown as **Heurema**; the installable plugin inside it is **Signum**. For fuller setup and platform notes, see `QUICKSTART.md`.

## First run

Run the main pipeline with a task:

```text
/signum "your task"
```

Signum asks for contract approval before execution. Normal run artifacts are written under:

```text
.signum/contracts/<contractId>/
```

## Command surface

| Command | Purpose |
| --- | --- |
| `/signum "<task>"` | Run the canonical Signum pipeline. |
| `/signum explain` | Explain the current pipeline and artifact model. |
| `/signum archive [contractId]` | Archive a completed contract; uses the active contract when no ID is provided. |
| `/signum close [contractId]` | Close or abandon a contract without generating a proofpack; uses the active contract when no ID is provided. |
| `/signum:init` | Bootstrap project context files. |
| `/signum:init --harness` | Bootstrap project context and scaffold repo-level harness docs. Requires Signum `>= v4.18.0`. |
| `/signum:init --force` | Overwrite existing bootstrap files. |
| `/signum:init --project-root <path>` | Run bootstrap against a specific project root. |

Use the colon form for init commands: `/signum:init` is the canonical init surface.

## Artifact model

`.signum/contracts/<contractId>/` is the canonical active contract artifact root. It holds run evidence such as `contract.json`, `combined.patch`, `audit_summary.json`, and `proofpack.json`.

Root `.signum/` is a registry/state/archive namespace with compatibility helpers; normal runs do not create root artifact files or root runtime dirs there.

For compatibility, resume checks use the registry first, with root `.signum/contract.json` only as a legacy import signal.

For the detailed artifact inventory, see `docs/artifact-path-inventory.md` and `docs/reference.md`.

## CI integration

Run the CI wrapper with:

```bash
bash lib/signum-ci.sh
```

The GitHub Actions workflow template lives at:

```text
lib/templates/signum-gate.yml
```

`lib/signum-ci.sh` maps proofpack decisions to exit codes:

| Exit code | Decision |
| --- | --- |
| `0` | `AUTO_OK` |
| `1` | `AUTO_BLOCK` |
| `78` | `HUMAN_REVIEW` |

The template uploads proofpack artifacts and comments the decision on pull requests. See `lib/signum-ci.sh`, `lib/templates/signum-gate.yml`, and `docs/reference.md` for the full CI behavior.

## Documentation

- `docs/README.md` — documentation index separating runtime references, maintainer docs, and historical context.
- `QUICKSTART.md` — setup and first-run walkthrough.
- `examples/README.md` — small, validator-backed examples for proofpacks, CI gating, and contract shape.
- `docs/how-it-works.md` — pipeline narrative and phase details.
- `docs/reference.md` — canonical reference for behavior, artifacts, and schemas.
- `docs/migration-notes.md` — compatibility notes for historical artifact roots, proofpack schema versions, and init command naming.
- `docs/RELIABILITY.md` — reliability notes and critical journeys.
- `docs/SECURITY.md` — trust boundaries and security review triggers.
- `ARCHITECTURE.md` — system overview and component map.

## Limitations

- Policy scanning is deterministic and regex-based, not a full semantic parser.
- Optional reviewer tools depend on external CLI availability and authentication.
- High-risk changes can still require maintainer review or an explicit override.
- Clean-room smoke checks are not a real package publish/install test.

## Development

Run the deterministic test suite:

```bash
bash scripts/run-deterministic-tests.sh
```

Useful focused checks while editing docs:

```bash
bash tests/test-doc-parity.sh
bash lib/doc-parity-check.sh
```

Maintainer release checks stay lower-level and deterministic:

```bash
bash lib/release-smoke.sh
```

The `Sync Emporium marketplace entry` workflow updates `heurema/emporium/.claude-plugin/marketplace.json`; non-dry-run sync needs `EMPORIUM_SSH_KEY`. It supports `workflow_dispatch` for controlled manual runs.
