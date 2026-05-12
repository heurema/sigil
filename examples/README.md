# Signum examples

These examples are small, deterministic documentation fixtures. They are meant to show practical file shapes and validation commands without duplicating the full runtime reference.

Normal Signum run artifacts live under `.signum/contracts/<contractId>/`.

## Available examples

- [proofpack-validation](proofpack-validation/) - a minimal proofpack that validates with `scripts/validate_proofpack.py`.
- [ci-gate](ci-gate/) - notes for using the canonical Signum CI gate template and wrapper.
- [basic-contract](basic-contract/) - a minimal contract shape example.

## How to validate

Run the proofpack validation example from the repository root:

```bash
python3 scripts/validate_proofpack.py examples/proofpack-validation/valid-proofpack.json --repo-root .
```

Run the examples guard:

```bash
bash tests/test-examples.sh
```

## Source of truth

Current runtime behavior remains defined by:

- `commands/signum.md`
- `commands/init.md`
- `docs/reference.md`

Examples are not a replacement for the full runtime reference. Use `docs/reference.md` when exact behavior, schema details, or artifact semantics matter.
