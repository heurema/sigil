# Signum for pi

`platforms/pi/` is the pi-native runtime overlay for Signum.
The root `commands/signum.md` remains the canonical pipeline source; this directory contains the pi-specific extension surface.

## Current status

Slice 6 is in progress:
- repo root is packable as a pi package
- pi can load the extension from this repository
- `/signum explain` returns a pi-native status summary aligned to Signum phases
- `/signum init` runs the deterministic scan, uses pi-native review/accept UI, and writes files from the extension runtime
- `/signum archive` and `/signum close` manage contract state natively in TypeScript
- `/signum <task>` now runs CONTRACT -> EXECUTE -> AUDIT -> PACK in pi
- engineer execution uses runtime policy-wrapped `read` / `edit` / `write` / `bash` tools
- AUDIT runs as a single-pass pi-native flow with mechanic, policy scan, holdouts, reviewer sessions, and deterministic synthesis
- PACK writes `proofpack.json`, `anti_entropy_report.json`, and syncs artifacts into the per-contract directory
- iterative AUDIT parity is still deferred explicitly; it is not silently dropped

## Local development

From the repo root, use one of these flows.

### Quick smoke test

Use `--extension` for fast one-off loading:

```bash
pi --no-extensions -e ./platforms/pi/extensions/signum/index.ts
```

Then run one of:

```text
/signum explain
/signum init --harness
/signum archive sig-20260314-a1b2
/signum close sig-20260314-a1b2
```

Use this mode for quick validation. Because the extension is loaded directly from the CLI flag, restart pi after edits instead of relying on `/reload`.

### Package install from this repo

Install the current repo as a project-local pi package:

```bash
pi install . -l
```

Then start pi in this repo and run:

```text
/signum explain
```

If you want to exercise the native init flow, use interactive pi so the command can open review/accept dialogs:

```text
/signum init --harness
```

For non-interactive development smoke tests of `/signum <task>`, the pi runtime also supports a developer-only approval bypass:

```bash
SIGNUM_PI_AUTO_APPROVE=1 pi --no-extensions -e ./platforms/pi/extensions/signum/index.ts --mode json --no-session '/signum your task here'
```

Do not rely on `SIGNUM_PI_AUTO_APPROVE=1` for normal usage. It exists only to exercise CONTRACT/EXECUTE/AUDIT/PACK flows without a live TUI confirmation step.

This path exercises the root `package.json` + `pi` manifest, which is the intended install surface for the pi-native Signum package.

## Packaging and test checks

Verify package contents before shipping:

```bash
npm run pack:dry-run
npm run test:pi
```

Optional live full-pipeline smoke:

```bash
SIGNUM_PI_LIVE_SMOKE=1 npm run test:pi:live
```

The package manifest uses an explicit `files` allowlist so the pi extension, shared `lib/` scripts, and prompt assets can be shipped intentionally.
