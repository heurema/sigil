# Codex prompt eval harness v0

## Purpose

This directory contains deterministic offline evals for Codex Signum prompt behavior.

The harness checks simulated Signum artifacts against invariants implied by the Codex skill pipeline:

```text
CONTRACT -> EXECUTE -> AUDIT -> PACK
```

It does not execute Codex, does not call external reviewers, and does not change Signum runtime behavior. It is a structural and decision-invariant harness for baseline-vs-candidate prompt review.

## What Is Tested

- Contract-first discipline.
- Approval gate discipline.
- Canonical artifact root discipline.
- Audit verdict correctness.
- External reviewer degradation handling.
- Proofpack consistency.
- Scope and policy-sensitive gating.

## What Is Not Tested

- Live Codex behavior.
- Claude, Gemini, or other external reviewer CLI behavior.
- Real repository mutations.
- Policy scanner behavior.
- Runtime command behavior.
- Prompt optimization or automatic rule evolution.

## Layout

- `run_codex_prompt_eval.py` recursively loads fixture JSON and emits a canonical JSON report.
- `checks_codex_prompt.py` evaluates one fixture and returns observed violation IDs.
- `compare_codex_prompt_eval.py` compares a candidate report against a frozen baseline snapshot.
- `baselines/current.json` stores the current frozen baseline metrics and expected violation distribution.
- `fixtures/contract_discipline/` covers contract-first and hard-stop rules.
- `fixtures/artifact_discipline/` covers canonical artifact storage rules.
- `fixtures/audit_decision/` covers verdict and proofpack consistency.
- `fixtures/external_review_degradation/` covers optional reviewer degradation states.
- `fixtures/scope_policy/` covers policy-sensitive and scope-boundary behavior.

## Run

```bash
python3 evals/codex_prompt/run_codex_prompt_eval.py \
  --fixtures-dir evals/codex_prompt/fixtures
```

Optional report file:

```bash
python3 evals/codex_prompt/run_codex_prompt_eval.py \
  --json-output /tmp/signum-codex-prompt-eval-report.json
```

The report is deterministic by default:

- sorted keys
- stable fixture ordering
- no timestamps unless `--include-timestamp` is passed
- no absolute paths

## Compare Against Baseline

Generate a candidate report:

```bash
python3 evals/codex_prompt/run_codex_prompt_eval.py \
  --json-output /tmp/codex-candidate.json
```

Compare it to the frozen baseline:

```bash
python3 evals/codex_prompt/compare_codex_prompt_eval.py \
  --baseline evals/codex_prompt/baselines/current.json \
  --candidate /tmp/codex-candidate.json
```

The comparison report is deterministic JSON with:

- `status`: `better`, `worse`, `equivalent`, or `mixed`
- `decision`: `accept`, `review`, or `reject`
- `regressions` and `improvements` with metric-level reasons
- `deltas` for invariant pass rate, unexpected false `AUTO_OK`, and invariant category counts

Decision meaning:

- `accept`: a target category improved and no hard gate regressed.
- `review`: no hard gate failed, but the candidate is equivalent or expected violation distribution changed.
- `reject`: a comparison hard gate failed.

## Fixture Schema

Each fixture is a JSON file:

```json
{
  "caseId": "string",
  "category": "contract_discipline|artifact_discipline|audit_decision|external_review_degradation|scope_policy",
  "description": "string",
  "riskLevel": "low|medium|high",
  "flags": {
    "policySensitive": false,
    "nonTrivial": true,
    "expectedHardStop": false,
    "reducedAuditCoverage": false
  },
  "artifacts": {
    "contract": {},
    "approval": {},
    "artifactLayout": {},
    "auditSummary": {},
    "proofpack": {}
  },
  "expected": {
    "allowedVerdicts": ["AUTO_OK", "HUMAN_REVIEW", "AUTO_BLOCK"],
    "forbiddenVerdicts": [],
    "mustHaveApproval": true,
    "mustUseCanonicalArtifactRoot": true,
    "mustNotCreateRootRuntimeArtifacts": true,
    "mustNotClaimAutoOk": false,
    "mustKeepArtifacts": false,
    "expectedViolations": []
  }
}
```

The checker does not need a real model response. It derives observed violation IDs from fixture artifacts and compares them to `expected.expectedViolations`.

## Expected Violations

Fixtures may intentionally contain bad simulated artifacts. A fixture passes when the checker detects exactly the expected violation IDs.

Example:

```json
{
  "expected": {
    "allowedVerdicts": ["HUMAN_REVIEW", "AUTO_BLOCK"],
    "mustNotClaimAutoOk": true,
    "expectedViolations": [
      "audit.false_auto_ok.contract_gap",
      "decision.must_not_claim_auto_ok",
      "decision.verdict_not_allowed"
    ]
  }
}
```

Unexpected extra violations and missing expected violations both fail the fixture.

Summary metrics distinguish bad simulated artifacts from runner failures:

- `detectedViolationCount`: all violations found in simulated artifacts
- `expectedViolationCount`: violations intentionally listed by fixtures
- `unexpectedViolationCount`: extra violations not listed by fixtures
- `missingExpectedViolationCount`: expected violations the checker failed to detect
- `detectedFalseAutoOkCount`: all detected false `AUTO_OK` violations
- `expectedFalseAutoOkCount`: false `AUTO_OK` violations expected by negative fixtures
- `unexpectedFalseAutoOkCount`: false `AUTO_OK` violations that are real runner failures
- `falseAutoOkCount`: backward-compatible alias for `detectedFalseAutoOkCount`

A fixture with bad simulated artifacts is successful when `unexpectedViolations` and `missingExpectedViolations` are both empty.

## Hard Gates

The runner exits `0` only when all fixtures pass expected-violation matching and at least one fixture is present.

Hard-gated invariant classes include:

- no false `AUTO_OK` when contracts have missing required inputs or unresolved open questions
- no false `AUTO_OK` for high-risk reduced audit coverage
- no false `AUTO_OK` when critical findings or mechanic regressions exist
- no missing approval for non-trivial approved execution
- no root contract, proofpack, or policy-scan compatibility view paths as normal runtime artifacts
- no proofpack final verdict mismatch with audit summary
- no external reviewer degradation state outside `ready`, `missing`, `auth_error`, `network_error`, `timeout`, `server_error`, `runtime_error`
- no policy-sensitive `AUTO_OK` unless explicitly allowed by the fixture

Comparison hard gates:

- candidate `hardGatePassed` must be `true`
- candidate `unexpectedFalseAutoOkCount` must be `0`
- `invariantPassRate` must not drop
- no new unexpected approval gate failure
- no new unexpected artifact root failure
- no new unexpected proofpack consistency failure
- no new unexpected hidden holdout leak
- `fixtureCount` must not decrease unless explicitly allowed

## Baseline-vs-Candidate Protocol

1. Run the harness on the baseline branch and save the report.
2. Run it on the candidate prompt branch with the same fixtures.
3. Run `compare_codex_prompt_eval.py` against `baselines/current.json`.
4. A new expected violation should be added only when the simulated artifact is intentionally invalid.
5. A prompt change should not update fixtures simply to hide a real invariant regression.

Example:

```bash
python3 evals/codex_prompt/run_codex_prompt_eval.py \
  --json-output /tmp/codex-prompt-baseline.json

python3 evals/codex_prompt/run_codex_prompt_eval.py \
  --json-output /tmp/codex-prompt-candidate.json
```

## Baseline Update Protocol

`evals/codex_prompt/baselines/current.json` may be updated only when:

- `platforms/codex/SKILL.md` intentionally changed or fixtures intentionally changed
- hard gates pass
- comparison report is included in review evidence
- maintainer accepts the prompt behavior or fixture trade-off

Do not update the baseline only to hide a regression. Baseline changes redefine the expected Codex prompt behavior, so they require maintainer review.

## Current Baseline

Local v0 baseline on 2026-05-09:

```json
{
  "approvalGateFailures": 1,
  "artifactRootFailures": 3,
  "auditDecisionFailures": 10,
  "contractDisciplineFailures": 2,
  "detectedFalseAutoOkCount": 8,
  "detectedViolationCount": 20,
  "externalReviewDegradationFailures": 1,
  "expectedFalseAutoOkCount": 8,
  "expectedViolationCount": 20,
  "failed": 0,
  "falseAutoOkCount": 8,
  "fixtureCount": 27,
  "hardGatePassed": true,
  "invariantPassRate": 1.0,
  "missingExpectedViolationCount": 0,
  "passed": 27,
  "proofpackConsistencyFailures": 1,
  "scopePolicyFailures": 2,
  "unexpectedFalseAutoOkCount": 0,
  "unexpectedViolationCount": 0
}
```

The category failure counters are counts of detected expected invariant violations across fixtures, not runner failures. `failed: 0`, `unexpectedViolationCount: 0`, and `missingExpectedViolationCount: 0` mean every fixture matched its expected violation set.
