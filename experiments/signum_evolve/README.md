# signum-evolve v0

`signum-evolve v0` is a deterministic offline experiment harness for policy scanner rule catalogs.

It does not change scanner behavior, mutate source catalogs, call LLMs, or apply candidate rules. It generates candidate `policy-rules.json` catalogs under `experiments/signum_evolve/out/`, evaluates them with the existing policy scanner eval harness, compares them against the frozen baseline, and exports adoption bundles for human review.

## What v0 Does

- Loads the baseline catalog from `lib/policy-rules.json`.
- Generates candidate catalogs using safe non-critical scope-only mutations.
- Runs `evals/policy_scanner/run_policy_scanner_eval.py` with `SIGNUM_POLICY_RULE_CATALOG` pointing at each candidate catalog.
- Runs `evals/policy_scanner/compare_policy_scanner_eval.py` against the current frozen baseline.
- Archives candidate, eval, compare, and leaderboard artifacts under `out/<run_id>/`.
- Exports a review bundle for one candidate.

## What v0 Does Not Do

- No OpenEvolve.
- No ast-grep or Semgrep.
- No external dependencies.
- No regex mutation.
- No severity mutation.
- No CRITICAL rule mutation.
- No Codex prompt change.
- No source catalog edits.
- No auto-apply or PR creation.

## Mutation Policy

Allowed mutation operator:

- `add_excluded_path_prefix` on non-CRITICAL rules only.

Allowed prefixes:

- `docs/`
- `examples/`
- `fixtures/`
- `tests/`
- `test/`
- `generated/`

Immutable fields:

- `ruleId`
- `type`
- `severity`
- `pattern`
- `autoBlock`
- `engine`
- `regex`

## Generate Candidates

```bash
python3 -m experiments.signum_evolve.cli generate \
  --repo-root . \
  --config experiments/signum_evolve/configs/evolve.v0.json \
  --run-id smoke \
  --max-candidates 5 \
  --seed 42
```

Run output is written to:

```text
experiments/signum_evolve/out/<run_id>/
```

`out/` is ignored by git.

## Read Leaderboard

```bash
python3 -m experiments.signum_evolve.cli leaderboard \
  --run experiments/signum_evolve/out/smoke
```

The leaderboard reports candidate decision, status, hard gate result, improvements, regressions, and mutation metadata. A candidate does not need to beat the current baseline to be useful; the current baseline is intentionally strong.

## Export Adoption Bundle

```bash
python3 -m experiments.signum_evolve.cli export \
  --run experiments/signum_evolve/out/smoke \
  --candidate cand_000001 \
  --out ../signum-evolve-bundle
```

The bundle contains:

- `candidate.json`
- `policy-rules.candidate.json`
- `eval.json`
- `compare.json`
- `report.md`
- `adoption-checklist.md`

Candidate adoption requires a separate normal PR. The generated candidate catalog is never applied automatically.
