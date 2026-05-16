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
- Agent review coverage before medium/high-risk `AUTO_OK`.
- Proofpack consistency.
- Scope and policy-sensitive gating.
- Adversarial test planning for tooling, eval harness, archive writer, prompt orchestration, and scanner policy changes.

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
- `fixtures/agent_review_coverage/` covers agent review evidence required before medium/high-risk `AUTO_OK`.
- `fixtures/scope_policy/` covers policy-sensitive and scope-boundary behavior.
- `fixtures/test_plan/` covers adversarial test planning gates.

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
  "category": "agent_review_coverage|contract_discipline|artifact_discipline|audit_decision|external_review_degradation|scope_policy|test_plan",
  "description": "string",
  "riskLevel": "low|medium|high",
  "changeType": "cli_tooling|eval_harness|file_archive_writer|prompt_orchestration|scanner_policy",
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
    "proofpack": {},
    "testPlan": {}
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

`changeType` and `artifacts.testPlan` are optional for older invariant categories. When present on medium/high-risk fixtures, missing required adversarial coverage must prevent `AUTO_OK`.

`artifacts.auditSummary.agentReviewCoverage` and `artifacts.auditSummary.agentReviewArtifacts` model review evidence produced inside the Signum AUDIT phase. Final human PR review is not treated as a substitute for these artifacts.

For medium/high-risk `AUTO_OK`, the checker expects:

- at least one ready agent reviewer in `agentReviewCoverage`
- at least one non-empty reviewer ID with `ready` state
- at least one concrete review artifact under the active contract `reviews/` root and recorded in `artifactLayout.artifactRefs`
- no materially reduced audit coverage, including degraded `agentReviewCoverage` provider states

Missing review evidence is reported as:

```text
agent_review.missing_for_auto_ok
```

Reduced review coverage with `AUTO_OK` is reported as:

```text
agent_review.reduced_coverage_auto_ok
```

## Adversarial Test Planning

Tooling, eval, CLI, archive-writer, prompt, and scanner-policy changes need negative and edge-case test planning before they can be considered mechanically clean.

`scripts/check_test_plan.py` validates standalone `test_plan.json` files:

```bash
python3 scripts/check_test_plan.py path/to/test_plan.json
```

This is offline check support only. The checker is not wired into the canonical Signum runtime pipeline yet.

It emits deterministic JSON with:

- `requiredCoverageClasses`
- `coveredCoverageClasses`
- `missingCoverageClasses`
- `hardGatePassed`
- `violations`

Coverage is computed from actual `adversarialChecks[].class` entries. Declared `coveredCoverageClasses` and `missingCoverageClasses` are consistency-checked, but they are not trusted as the source of truth.

Required coverage classes by change type:

| changeType | required adversarial classes |
| --- | --- |
| `cli_tooling` | `boundary_value`, `idempotency`, `path_handling`, `config_source_of_truth`, `generated_output_isolation` |
| `eval_harness` | `malformed_fixture`, `expected_violation_logic`, `baseline_mismatch`, `fixture_count_change`, `deterministic_output` |
| `file_archive_writer` | `overwrite_behavior`, `stale_output`, `cleanup`, `relative_absolute_paths`, `generated_output_isolation` |
| `prompt_orchestration` | `false_auto_ok`, `missing_approval`, `reduced_coverage`, `artifact_root_drift`, `hidden_holdout_leak` |
| `scanner_policy` | `critical_false_negative`, `false_positive_budget`, `suppression_semantics`, `severity_accuracy`, `runtime_budget` |

Low-risk changes may warn on missing adversarial coverage. Medium and high-risk changes fail the standalone checker when required coverage is missing.

The Codex prompt eval also checks the decision invariant: a medium/high-risk fixture with missing required adversarial coverage must not land on `AUTO_OK`. The violation ID is:

```text
test_plan.missing_adversarial_coverage
```

This specifically guards misses seen in early `signum-evolve v0` work: configured baseline source of truth, absolute config paths, repeated run-id stale output, and `--max-candidates 0` boundary behavior.

Future medium/high-risk Signum contracts for tooling, eval harness, CLI, archive writer, prompt orchestration, or scanner policy changes should include a `test_plan.json` artifact and run `scripts/check_test_plan.py` before final audit.

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
- no medium/high-risk `AUTO_OK` without agent review coverage and review artifacts
- no missing approval for non-trivial approved execution
- no root contract, proofpack, or policy-scan compatibility view paths as normal runtime artifacts
- no proofpack final verdict mismatch with audit summary
- no external reviewer degradation state outside `ready`, `missing`, `auth_error`, `network_error`, `timeout`, `server_error`, `runtime_error`
- no policy-sensitive `AUTO_OK` unless explicitly allowed by the fixture
- no medium/high-risk tooling or eval `AUTO_OK` when required adversarial test coverage is missing

Comparison hard gates:

- candidate `hardGatePassed` must be `true`
- candidate `unexpectedFalseAutoOkCount` must be `0`
- `invariantPassRate` must not drop
- no new unexpected agent review coverage failure
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

Local baseline after agent review coverage review-fix fixtures:

```json
{
  "agentReviewCoverageFailures": 15,
  "approvalGateFailures": 1,
  "artifactRootFailures": 3,
  "auditDecisionFailures": 10,
  "contractDisciplineFailures": 2,
  "detectedFalseAutoOkCount": 27,
  "detectedViolationCount": 39,
  "expectedAgentReviewCoverageFailures": 15,
  "externalReviewDegradationFailures": 1,
  "expectedFalseAutoOkCount": 27,
  "expectedTestPlanFailures": 4,
  "expectedViolationCount": 39,
  "failed": 0,
  "falseAutoOkCount": 27,
  "fixtureCount": 41,
  "hardGatePassed": true,
  "invariantPassRate": 1.0,
  "missingExpectedViolationCount": 0,
  "passed": 41,
  "proofpackConsistencyFailures": 1,
  "scopePolicyFailures": 2,
  "testPlanFailures": 4,
  "unexpectedAgentReviewCoverageFailures": 0,
  "unexpectedFalseAutoOkCount": 0,
  "unexpectedTestPlanFailures": 0,
  "unexpectedViolationCount": 0
}
```

The category failure counters are counts of detected expected invariant violations across fixtures, not runner failures. `failed: 0`, `unexpectedViolationCount: 0`, and `missingExpectedViolationCount: 0` mean every fixture matched its expected violation set.
