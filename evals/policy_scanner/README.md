# Policy scanner eval harness

## Why this exists

This directory contains the first deterministic offline evaluation layer for `lib/policy-scanner.sh`.

The scanner is intentionally unchanged by this harness. The goal is to measure current and future rule behavior against labeled unified-diff fixtures before changing scanner logic. It gives baseline-vs-candidate evidence without adding OpenEvolve, ast-grep, Semgrep, LLM judges, or CI gate behavior changes.

## Layout

- `run_policy_scanner_eval.py` runs the existing scanner against fixture patches and emits a canonical JSON scorecard.
- `compare_policy_scanner_eval.py` compares a candidate scorecard against a frozen baseline snapshot.
- `baselines/current.json` stores the current frozen baseline metrics.
- `fixtures/positive/*.json` covers expected active findings.
- `fixtures/negative/*.json` covers cases that should not produce active findings.
- `fixtures/suppression/*.json` covers suppression acceptance and rejection behavior.
- `fixtures/adversarial/*.json` covers brittle formatting and close-call cases.

The expanded corpus v1 contains 75 fixtures:

- `positive`: 34
- `negative`: 14
- `suppression`: 15
- `adversarial`: 12

The harness is read-only with respect to scanner behavior. It creates temporary directories, writes each fixture patch to `combined.patch`, invokes:

```bash
bash lib/policy-scanner.sh <temp_combined_patch>
```

Then it reads `<temp>/policy_scan.json` and compares the scanner output to fixture expectations.

## Run

```bash
python3 evals/policy_scanner/run_policy_scanner_eval.py \
  --repo-root . \
  --fixtures-dir evals/policy_scanner/fixtures
```

Optional output file:

```bash
python3 evals/policy_scanner/run_policy_scanner_eval.py \
  --repo-root . \
  --json-output /tmp/policy-scanner-scorecard.json
```

Useful flags:

- `--repeat 2` runs each fixture twice by default to detect nondeterministic scanner output.
- `--fail-on-known-baseline-failures true` turns documented known baseline failures into hard failures.
- `--include-timestamp` adds `generatedAt`; timestamps are omitted by default.

## Compare Against Baseline

Generate a candidate report:

```bash
python3 evals/policy_scanner/run_policy_scanner_eval.py \
  --repo-root . \
  --json-output /tmp/policy-candidate.json
```

Compare it to the frozen baseline:

```bash
python3 evals/policy_scanner/compare_policy_scanner_eval.py \
  --baseline evals/policy_scanner/baselines/current.json \
  --candidate /tmp/policy-candidate.json
```

The comparison report is deterministic JSON with:

- `status`: `better`, `worse`, `equivalent`, or `mixed`
- `decision`: `accept`, `review`, or `reject`
- `regressions` and `improvements` with metric-level reasons
- `deltas` for precision, recall, f1, critical false negatives, false positives, known baseline failures, p95 runtime, and determinism

Decision meaning:

- `accept`: at least one target metric improved and no major metric regressed.
- `review`: no hard gate failed, but the candidate is equivalent or has a trade-off that needs maintainer judgment.
- `reject`: a comparison hard gate failed.

Comparison hard gates:

- candidate `criticalFalseNegatives` must be `0`
- candidate `determinismScore` must be `1.0`
- candidate `hardGatePassed` must be `true`
- candidate `unexpectedCriticalFindings` must be `0` when present
- candidate JSON must have a readable scorecard shape

Regression thresholds:

- precision must not drop by more than `0.02` unless recall improves by at least `0.05` and false positives stay within budget
- recall must not drop
- critical recall must not drop
- false positives must not increase without material recall improvement
- known baseline failures must not increase

`runtimeMsP95` remains in `deltas` as an informational signal, but it is not a
regression gate because scanner subprocess runtime is host-dependent.

## Fixture schema

Required fields:

```json
{
  "caseId": "string",
  "kind": "positive|negative|suppression|adversarial",
  "description": "string",
  "patch": "unified diff string",
  "expectedFindings": [
    {
      "ruleId": "POLICY_SUBPROCESS_SHELL_INJECTION",
      "severity": "CRITICAL",
      "file": "app.py",
      "line": 2,
      "mustBlock": true
    }
  ],
  "allowedExtraFindings": [],
  "tags": ["python", "security", "critical"]
}
```

For negative fixtures, `expectedFindings` must be `[]`.

Optional fields used by suppression and baseline documentation:

- `expectedSuppressedFindings`: same matching fields as `expectedFindings`, checked against `suppressedFindings`.
- `expectedRejectedSuppressions`: `ruleId`, `file`, optional `line`, optional `severity`, and `rejectedReason`.
- `knownBaselineFailure`: object with `date`, `source`, and `reason` explaining a current scanner gap that this PR does not fix. Once the behavior is intentionally fixed, keep the fixture as a regression guard and remove the stale known-failure annotation.

Expected active findings match by `ruleId`, `severity`, `file`, and `line`. If line matching is too brittle for a fixture, set `"line": null` to match by `ruleId`, `severity`, and `file` only.

## Metrics

The scorecard summary includes:

- `fixtureCount`, `passed`, `failed`
- `truePositives`, `falsePositives`, `falseNegatives`
- `precision`, `recall`, `f1`
- `criticalRecall`, `criticalFalseNegatives`
- `severityMismatches`
- `unexpectedCriticalFindings`
- `runtimeMsP50`, `runtimeMsP95`
- `determinismScore`

Runtime metrics are measured from local scanner subprocess runs and can vary by machine. The JSON serialization is canonical: sorted keys, stable result ordering, no absolute temp paths, and no timestamps unless `--include-timestamp` is used.

## Hard gates

The harness exits `0` when hard gates pass and `1` when any hard gate fails.

Hard gates:

- scanner output must be readable valid JSON with the expected top-level shape.
- `determinismScore` must be `1.0`.
- `criticalFalseNegatives` must be `0`, unless the fixture is explicitly documented as a known baseline failure and `--fail-on-known-baseline-failures` is `false`.
- negative fixtures must not produce unexpected `CRITICAL` findings.
- fixtures with expected findings must match `ruleId`, `severity`, `file`, and `line` when possible.
- suppression fixtures with explicit suppression/rejection expectations must match those records.

Non-critical false positives are still counted and shown in `failed` fixture results, but they are not automatically hard-gate failures unless configured as known baseline failures with `--fail-on-known-baseline-failures true`.

## Baseline-vs-candidate protocol

1. Run the harness on the baseline branch and save the report.
2. Run the harness on the candidate branch with the same fixture set and repeat count.
3. Run `compare_policy_scanner_eval.py` against `baselines/current.json`.
4. Treat improved recall with increased false positives as a review decision, not an automatic win.
5. Do not update expected fixtures to match new scanner behavior unless the scanner behavior change is intentional and reviewed.
6. Do not use this harness to evolve rules automatically; it is measurement only.

Example:

```bash
python3 evals/policy_scanner/run_policy_scanner_eval.py \
  --repo-root . \
  --json-output /tmp/policy-scanner-baseline.json

python3 evals/policy_scanner/run_policy_scanner_eval.py \
  --repo-root . \
  --json-output /tmp/policy-scanner-candidate.json
```

## Baseline Update Protocol

`evals/policy_scanner/baselines/current.json` may be updated only when:

- scanner behavior intentionally changed
- hard gates pass
- comparison report is included in review evidence
- maintainer accepts the precision, recall, false-positive, and runtime trade-off

Do not update the baseline only to hide a regression. Baseline changes should be reviewed like scanner behavior changes because they redefine what future candidates are measured against.

## Current baseline sample

Local expanded-corpus baseline run on 2026-05-09:

```json
{
  "criticalFalseNegatives": 0,
  "criticalRecall": 1.0,
  "determinismScore": 1.0,
  "f1": 1.0,
  "failed": 0,
  "falseNegatives": 0,
  "falsePositives": 0,
  "fixtureCount": 75,
  "hardGatePassed": true,
  "knownBaselineFailures": 0,
  "passed": 75,
  "precision": 1.0,
  "recall": 1.0,
  "severityMismatches": 0,
  "truePositives": 55,
  "unexpectedCriticalFindings": 0
}
```

`runtimeMsP50` and `runtimeMsP95` are omitted from this README sample because they are environment-dependent.

## Resolved baseline failures

- `negative-examples-console-log-current-baseline`: resolved on 2026-05-09 by adding catalog-driven `excludedPathPrefixes` for `POLICY_DEBUG_PRINT`. Old-baseline comparison showed `falsePositives` decreasing from `1` to `0`, `knownBaselineFailures` decreasing from `1` to `0`, `precision` improving from `0.923077` to `1.0`, and no regressions.

## Current behavior notes

- `adversarial-generated-package-json-current-behavior`: generated-like `generated/package.json` paths are still treated as manifest dependency findings by current scanner behavior. This corpus records that behavior without changing scanner scope.
