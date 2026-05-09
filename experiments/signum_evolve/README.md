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

## What v0.1 Adds

v0.1 adds optional historical replay drift reporting for reviewers.

When `--historical-root` is provided, `generate` discovers historical contract directories containing `combined.patch`, scans each patch with the baseline catalog and with each candidate catalog, and writes deterministic drift data to each candidate archive.

Historical replay is only a review signal. It is not treated as labeled ground truth and does not auto-apply or rewrite candidate catalogs. Missing historical roots are skipped gracefully.

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
- No required `.signum/` artifacts for tests.

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

To add optional historical replay:

```bash
python3 -m experiments.signum_evolve.cli generate \
  --repo-root . \
  --config experiments/signum_evolve/configs/evolve.v0.json \
  --run-id replay-smoke \
  --max-candidates 5 \
  --seed 42 \
  --historical-root .signum/contracts
```

If the historical root does not exist, the run still succeeds and records:

```json
{"historicalReplay": {"reason": "missing_root", "status": "skipped"}}
```

## Historical Replay Output

Each candidate with replay enabled gets:

```text
experiments/signum_evolve/out/<run_id>/candidates/<candidate_id>/historical_replay.json
```

The report includes:

- replay status
- item count
- new findings
- removed findings
- changed severity count
- changed rule count
- new or removed critical findings
- per-contract drift items

Finding identity is deterministic and compares:

- `ruleId`
- `file`
- `line`
- `severity`
- `snippet`

Changed severity and changed rule summaries use deterministic alternate identities to make drift easier to review. Paths are repo-relative when possible; external temporary roots are reported with `external:<root-name>/...` instead of absolute local paths.

## Read Leaderboard

```bash
python3 -m experiments.signum_evolve.cli leaderboard \
  --run experiments/signum_evolve/out/smoke
```

The leaderboard reports candidate decision, status, hard gate result, improvements, regressions, and mutation metadata. A candidate does not need to beat the current baseline to be useful; the current baseline is intentionally strong.

When replay is enabled, each leaderboard candidate also includes compact historical replay data:

```json
{
  "historicalReplay": {
    "itemCount": 12,
    "newFindingsCount": 1,
    "removedCriticalFindingsCount": 0,
    "removedFindingsCount": 0,
    "status": "ok"
  }
}
```

Replay does not penalize skipped candidates. If replay detects removed CRITICAL findings, the candidate decision is forced to `review` unless the comparison already rejected it.

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
- `historical_replay.json`, when replay was enabled
- `report.md`
- `adoption-checklist.md`

Candidate adoption requires a separate normal PR. The generated candidate catalog is never applied automatically.

Adoption reports include a historical replay section when replay data is available. Any non-zero drift requires maintainer review before a candidate is adopted.
