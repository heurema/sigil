# Proofpack validation example

This directory contains a minimal proofpack documentation fixture derived from the current valid proofpack test fixtures. It is intentionally small, but it includes the fields required by `scripts/validate_proofpack.py`.

Validate it from the repository root:

```bash
python3 scripts/validate_proofpack.py examples/proofpack-validation/valid-proofpack.json --repo-root .
```

This example does not include artifact path references, so no companion contract artifact directory is needed. Normal Signum runs write proofpacks under `.signum/contracts/<contractId>/`.
