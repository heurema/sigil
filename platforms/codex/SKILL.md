---
name: signum
description: Use when the user wants a contract-first implementation workflow, asks to define correctness before coding, wants multi-stage execution with verification and audit, or needs a proof-style artifact for a code change. Codex should run a CONTRACT -> EXECUTE -> AUDIT -> PACK pipeline.
---

# Signum for Codex

Use this skill when the task should be executed as an evidence-driven development pipeline instead of ad hoc coding.

Codex is the orchestrator.

The core rule is simple: define correctness before code is written, then verify against that definition.

## Pipeline

```
CONTRACT -> EXECUTE -> AUDIT -> PACK
```

## External Audit Providers

When AUDIT uses external reviewers such as `claude` or `gemini`, treat them as optional evidence sources, not as required trust anchors.

Before invoking any external reviewer in the current execution context:

1. Check binary presence with `command -v`
2. Run a cheap network/DNS preflight
3. Only then run the provider command with a timeout

When Signum is run through a nested `codex exec` and the AUDIT phase needs external reviewers, prefer a profile that preserves network access. In this environment, the recommended profile is `research`.

Example:

```bash
./scripts/codex-exec-last.sh -p research -C /path/to/repo '...'
```

Do not assume the outer Codex session sandbox is inherited by nested `codex exec` calls.

After nested test or diagnostic runs, explicitly clean up lingering nested `codex exec` processes if the run was interrupted or allowed to continue past the intended check:

```bash
./scripts/kill-codex-exec.sh --pattern 'codex exec -p research'
```

Use a narrower `--pattern` for targeted cleanup. Use `--dry-run` first if you need to inspect matches.

Example network preflight:

```bash
python3 - <<'PY'
import socket
try:
    socket.getaddrinfo('example.com', 443)
    print('NETWORK_OK')
except Exception as e:
    print(f'NETWORK_ERR: {e}')
PY
```

Classify provider state into:

- `ready`
- `missing`
- `auth_error`
- `network_error`
- `timeout`
- `server_error`
- `runtime_error`

Treat `network_error`, `timeout`, and `server_error` as degraded audit coverage, not as fatal pipeline crashes.

## Core Rules

1. Do not start implementation before a contract exists.
2. If the contract is vague, stop and improve it before coding.
3. The implementation should be checked against deterministic criteria, not just model opinion.
4. Separate implementation context from audit context when possible.
5. Keep pipeline artifacts under the active contract artifact root `.signum/contracts/<contractId>/`. Treat root `.signum/` as registry/state plus compatibility views.
6. If the pipeline cannot verify a claim, say so explicitly.
7. If the task is too small for the full pipeline, reduce scope but keep the contract-first principle.

## Artifact Layout

Create and use the active contract artifact root:

- `.signum/contracts/<contractId>/`
- `.signum/contracts/index.json.activeContractId`

Within that active contract root, create and use:

- `contract.json`
- `contract-engineer.json`
- `contract-policy.json`
- `baseline.json`
- `execute_log.json`
- `combined.patch`
- `iteration_delta.patch`
- `mechanic_report.json`
- `audit_summary.json`
- `audit_iteration_log.json`
- `repair_brief.json`
- `proofpack.json`
- `reviews/`
- `iterations/`

Also ensure root `.signum/` is ignored by git when appropriate.

## Phase 1: CONTRACT

Goal: turn the user request into a verifiable contract.

The contract should contain at least:

- `schemaVersion`
- `goal`
- `riskLevel`
- `inScope`
- `outOfScope`
- `assumptions`
- `acceptanceCriteria`
- `openQuestions`
- `requiredInputsProvided`

Each acceptance criterion should be concrete and, when possible, include a `verify` block.

Suggested verify fields:

- `type`
- `value`

Example verify types:

- `exec`
- `manual`
- `test`

### Contract Quality Gate

Before EXECUTE, score the contract on:

- testability
- clarity
- scope boundedness
- completeness
- negative coverage
- boundary definition

If the contract is too weak for autonomous execution, stop and ask for clarification or refine the contract first.

Hard-stop conditions:

- missing required inputs
- unresolved open questions
- no meaningful acceptance criteria
- no verification path for critical behavior

### Holdouts

When appropriate, add hidden holdout scenarios for blind validation.

Rules:

- holdouts should test edge cases or negative cases
- do not expose them to the implementation context if you are preserving blinding
- if the task is tiny, holdouts may be omitted

## Phase 2: EXECUTE

Goal: implement against the contract, not against a vague prompt.

Before coding:

1. Capture baseline checks into `baseline.json` under the active contract artifact root
2. Derive a reduced implementation contract in `contract-engineer.json` under the active contract artifact root
3. Derive an execution policy in `contract-policy.json` under the active contract artifact root

The policy should restrict:

- files or directories allowed to change
- disallowed tool usage
- denied shell patterns
- whether network use is allowed

Implementation rules:

1. Change only files within scope.
2. Keep the diff minimal.
3. Run verification commands after implementation.
4. If verification fails, attempt targeted repair.
5. Stop after bounded repair attempts instead of thrashing.

Record attempts and outcomes in `execute_log.json` under the active contract artifact root.

## Phase 3: AUDIT

Goal: determine whether the implementation actually satisfies the contract and whether new risks were introduced.

Audit has 3 layers:

### `mechanic`

Deterministic checks first:

- lint
- typecheck
- tests
- baseline comparison
- scope compliance

If new failures appear versus baseline, treat them as regressions.

### `review`

Optional multi-model review if external providers are available.

Recommended roles:

- Codex: orchestrator synthesis and local review
- Claude CLI: semantic review
- Gemini CLI: alternative review focused on performance or edge cases

External reviewers should get only the minimum context needed.

If provider CLIs are unavailable, continue with deterministic audit and Codex-only analysis.
If the current execution context has no usable outbound network or DNS, classify external reviewers as `network_error` and skip them immediately instead of waiting for long timeouts.
If a provider returns a transient upstream failure, retry once with a short backoff, then mark reduced coverage.
If a provider returns `auth_error`, do not retry automatically.

### `holdout verification`

Run hidden or extra scenarios if they exist.

If holdouts fail, the pipeline should not claim success even if visible acceptance criteria pass.

### `iterative repair`

If synthesis finds MAJOR or CRITICAL review findings, mechanic regressions, or holdout failures, enter iterative AUDIT instead of stopping after the first audit pass.

Use `SIGNUM_AUDIT_MAX_ITERATIONS` as the maximum repair count; default to `20` when it is unset.

For each iteration:

1. Build a sanitized `repair_brief.json` under the active contract artifact root.
2. Include only actionable findings, mechanic regression summaries, and holdout categories; never reveal hidden holdout details.
3. Start a fresh repair context that fixes only the listed findings.
4. Re-run the full safety chain: scope gate, policy checks, mechanic checks, holdouts, available reviewers, and synthesis.
5. Store the full pass snapshot under `iterations/NN/`, including `combined.patch`, `iteration_delta.patch` when present, mechanic and holdout reports, reviewer outputs, and `audit_summary.json`.
6. Append per-pass metadata to `audit_iteration_log.json`.

Score each pass with the same severity weighting used by canonical Signum: CRITICAL findings dominate MAJOR findings, mechanic regressions, holdout failures, and MINOR findings. Keep the best-scoring candidate, not necessarily the last candidate.

Stop early after two consecutive non-improving iterations. Before PACK, restore the best candidate and make its `audit_summary.json`, `combined.patch`, `reviews/`, and verification artifacts the active artifacts.

When more than one audit iteration was used, include an `iterativeAudit` section in `proofpack.json` with `iterationsUsed`, `iterationsMax`, `bestIteration`, `auditIterations`, `resolvedFindings`, and `remainingFindings`.

## Phase 4: PACK

Goal: package the run into a self-contained proof artifact.

`proofpack.json` should contain:

- run metadata
- contract summary
- contract hash if available
- baseline summary
- implementation summary
- audit summary
- review summaries
- external audit coverage summary
- final verdict
- confidence level
- artifact references or embedded content

Possible verdicts:

- `AUTO_OK`
- `HUMAN_REVIEW`
- `AUTO_BLOCK`

Guidance:

- regressions or critical audit findings => `AUTO_BLOCK`
- weak evidence or mixed findings => `HUMAN_REVIEW`
- deterministic checks pass and no serious findings => `AUTO_OK`

Do not upgrade to `AUTO_OK` if the audit coverage was materially reduced by external-review failures and the task risk is medium or high. In that case prefer `HUMAN_REVIEW`.

## Resume Behavior

If `contracts/index.json.activeContractId` or other pipeline artifacts already exist:

1. Inspect what phases are complete.
2. Resume from the first incomplete phase when safe.
3. If artifacts are inconsistent, prefer a clean restart and explain why.

Do not silently overwrite an existing pipeline run without making that decision explicit.

## Minimal JSON Shapes

### Contract

```json
{
  "schemaVersion": "1.0",
  "goal": "What must be achieved",
  "riskLevel": "low",
  "inScope": ["src/example.py"],
  "outOfScope": ["tests/integration/"],
  "assumptions": ["existing CLI remains unchanged"],
  "acceptanceCriteria": [
    {
      "id": "AC-1",
      "description": "Command returns structured JSON",
      "verify": { "type": "exec", "value": "pytest -q" }
    }
  ],
  "openQuestions": [],
  "requiredInputsProvided": true
}
```

### Audit Summary

```json
{
  "verdict": "HUMAN_REVIEW",
  "confidence": 78,
  "regressions": [],
  "criticalFindings": [],
  "notes": ["Holdouts were skipped"],
  "externalAuditCoverage": {
    "claude": "auth_error",
    "gemini": "network_error"
  }
}
```

## Failure Handling

- If the contract is invalid, stop before coding.
- If baseline cannot be captured, record the limitation and lower confidence.
- If implementation cannot satisfy verifies after bounded attempts, stop and report failure.
- If external reviewers are unavailable, degrade gracefully and mark reduced audit coverage.
- If the current sandbox or execution context cannot resolve or reach the provider network, classify external review as `network_error` and skip provider calls immediately.
- If an external provider returns a transient server-side failure, retry once, then mark reduced coverage.
- If an external provider returns an auth failure, record `auth_error` and continue without it.
- If reduced audit coverage affects a medium- or high-risk task, prefer `HUMAN_REVIEW` over `AUTO_OK`.
- If proofpack assembly fails, preserve intermediate artifacts and report the failure.

## Boundaries

- Do not skip CONTRACT just because the task seems obvious.
- Do not confuse a passing implementation with a passing audit.
- Do not claim blind validation if holdouts were not actually hidden.
- Do not let external review replace deterministic checks.
- Do not modify unrelated files under the cover of “pipeline work”.
