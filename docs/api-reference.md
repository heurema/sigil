# Signum API reference

This page summarizes stable integration surfaces for schemas and deterministic scripts.

Current runtime behavior is still defined by:

- `commands/signum.md`
- `commands/init.md`
- `docs/reference.md`

This page is an integration index, not the full runtime specification. For compatibility notes, examples, and CI wiring, see `docs/migration-notes.md`, `examples/README.md`, and `lib/templates/signum-gate.yml`.

## Schemas

| Surface | Source of truth | Notes |
| --- | --- | --- |
| Contract schema | `lib/schemas/contract.schema.json` | Contract JSON shape used by the CONTRACT phase. |
| Proofpack schema | `lib/schemas/proofpack.schema.json` | Public proofpack JSON Schema surface. |
| Proofpack validator | `scripts/validate_proofpack.py` | Deterministic validator for the proofpack shape Signum currently emits. |

## Deterministic scripts

| Script | Purpose | Inputs | Outputs / exit semantics |
| --- | --- | --- | --- |
| `scripts/validate_proofpack.py` | Validate proofpack artifacts. | proofpack path; optional `--repo-root`; optional `--contract-root` | exits `0` on valid proofpack and `1` on validation errors; emits warnings/errors to stderr. |
| `lib/signum-ci.sh` | CI wrapper for file-backed Signum runs. | required `SIGNUM_CONTRACT_PATH`; optional `SIGNUM_PROJECT_ROOT`, `SIGNUM_MAX_TURNS`, `SIGNUM_ALLOWED_TOOLS`, `SIGNUM_AUDIT_MAX_ITERATIONS`, `SIGNUM_CI_RELAXED`, `SIGNUM_PROOFPACK_VALIDATOR` | maps decisions to exit codes: `0=AUTO_OK`, `1=AUTO_BLOCK`, `78=HUMAN_REVIEW`; `SIGNUM_CI_RELAXED=true` maps `HUMAN_REVIEW` to exit `0`. |
| `lib/policy-scanner.sh` | Deterministic policy scan over added patch lines. | patch file path; optional `SIGNUM_POLICY_RULE_CATALOG` or `SIGNUM_POLICY_PATTERN_CATALOG` override | writes `<patch_dir>/policy_scan.json`; exits `0` when the scan completes and `1` on fatal input/tooling errors. |
| `lib/init-scanner.sh` / `scripts/init_scanner.py` | Deterministic project-context scan for `/signum:init`. | optional `--project-root <path>`; defaults to `.` | writes JSON scan signals to stdout; exits non-zero on invalid arguments, missing wrapper dependencies, or project-root access errors. |
| `scripts/run-deterministic-tests.sh` | Local deterministic test runner. | no required arguments; runs from the repository root | runs shell tests and offline evals when present; exits non-zero if any invoked check fails. |

## Usage snippets

Validate a proofpack from a canonical contract artifact root:

```bash
python3 scripts/validate_proofpack.py .signum/contracts/<contractId>/proofpack.json --repo-root .
```

Run the CI wrapper with a file-backed contract:

```bash
SIGNUM_CONTRACT_PATH=contract.json bash lib/signum-ci.sh
```

Run the init scanner against the current project:

```bash
bash lib/init-scanner.sh --project-root .
```

## Related references

- `docs/reference.md` - full current runtime reference.
- `docs/migration-notes.md` - compatibility notes for historical artifact roots, proofpack schema versions, and init command naming.
- `examples/README.md` - small validator-backed examples.
- `lib/templates/signum-gate.yml` - GitHub Actions gate template using `lib/signum-ci.sh`.
