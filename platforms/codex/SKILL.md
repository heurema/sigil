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
8. Present the contract before EXECUTE and record approval before implementation for non-trivial changes.
9. Preserve deterministic guardrails even when external model reviewers are unavailable.

## Artifact Layout

Create and use the active contract artifact root:

- `.signum/contracts/<contractId>/`
- `.signum/contracts/index.json.activeContractId`

Within that active contract root, create and use:

- `contract.json`
- `spec_quality.json`
- `spec_validation.json`
- `clover_report.json`
- `intent_check.json`
- `approval.json`
- `contract-hash.txt`
- `contract-engineer.json`
- `contract-policy.json`
- `execution_context.json`
- `baseline.json`
- `implementation_context.json`
- `reuse_candidates.json`
- `reuse_decision.json`
- `execute_log.json`
- `combined.patch`
- `iteration_delta.patch`
- `mechanic_report.json`
- `holdout_report.json`
- `policy_violations.json`
- `policy_scan.json`
- `duplicate_scan.json`
- `audit_summary.json`
- `audit_iteration_log.json`
- `repair_brief.json`
- `flaky_tests.json`
- `reuse_summary.json`
- `proofpack.json`
- `anti_entropy_report.json`
- `reviews/`
- `iterations/`
- `receipts/`
- `runs/<runId>/`
- `snapshots/`

Also ensure root `.signum/` is ignored by git when appropriate.

Project-level Codebase Awareness caches under `.signum/cache/`, including `file-digests-v1.json`, are rebuildable scanner cache, not active contract root evidence and not proofpack payloads. The digest cache supports bounded/incremental lexical scanning only; it does not add AST or semantic scanning. Scanner defaults are bounded at `--max-files 10000`, `--max-bytes 50000000`, and `--max-file-size 1048576`.

Codebase Awareness has shallow Go, Rust, and C# lexical/symbol support. For Go, it detects `go.mod`, `go.work`, `.go` files, Go package names/imports, exported symbols, `internal/`, `cmd/`, `pkg/`, `testdata/`, and `*_test.go` conventions. Go import resolution is local and module-path based when possible. For Rust, it detects `Cargo.toml` manifests and workspaces, Cargo package/dependency hints, Rust modules/imports, `pub` symbols, crate and module boundary hints, integration tests under `tests/`, and inline `#[cfg(test)]` tests. For C#, it detects `.sln`, `.csproj`, `Directory.Build.props`, `Directory.Build.targets`, `.cs` files, project references, package references, namespaces, `using` imports, public/internal symbols, project and assembly boundary hints, and common .NET test frameworks such as xUnit, NUnit, MSTest, and `Microsoft.NET.Test.Sdk`. It does not run `go list`, Cargo, `rustc`, `cargo metadata`, `dotnet`, MSBuild, or NuGet; it does not perform Roslyn, AST parsing, type checking, semantic analysis, or semantic resolution.

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

For medium/high risk work, also run or emulate these canonical quality checks when the needed local files exist:

- prose and glossary checks into `spec_quality.json`
- intent alignment into `intent_check.json`
- optional multi-model spec validation into `spec_validation.json`
- Clover reconstruction into `clover_report.json`

Treat quality warnings as evidence. Treat missing required inputs, unresolved open questions, and blocking staleness as hard stops.

### Holdouts

When appropriate, add hidden holdout scenarios for blind validation.

Rules:

- holdouts should test edge cases or negative cases
- do not expose them to the implementation context if you are preserving blinding
- if the task is tiny, holdouts may be omitted

### Approval Gate

Before EXECUTE, show the contract summary to the user and record the decision in `approval.json`.

For an approved contract, record `contract-hash.txt`, activate the contract in `.signum/contracts/index.json`, and derive:

- `contract-engineer.json`: visible implementation contract with hidden holdouts removed
- `contract-policy.json`: deterministic execution policy

If the user does not approve, revise CONTRACT or stop. Do not implement against an unapproved non-trivial contract.

## Phase 2: EXECUTE

Goal: implement against the contract, not against a vague prompt.

Before coding:

1. Capture baseline checks into `baseline.json` under the active contract artifact root
2. Derive a reduced implementation contract in `contract-engineer.json` under the active contract artifact root
3. Derive an execution policy in `contract-policy.json` under the active contract artifact root
4. Record `execution_context.json` with run id, base commit, risk level, and policy metadata
5. Capture a pre-execute workspace snapshot under `snapshots/`
6. When Codebase Awareness is enabled, use `implementation_context.json` and `reuse_candidates.json`; in `warn` or `gate` mode the Engineer must write `reuse_decision.json` before code changes.

When Codebase Awareness is enabled, AUDIT may produce `duplicate_scan.json` as reuse/duplicate evidence. In `warn`, unresolved major/critical duplicate findings cap AUDIT at `HUMAN_REVIEW`; in `gate`, critical and narrow high-confidence unresolved major findings can force `AUTO_BLOCK`. PACK writes `reuse_summary.json` as compact run-scoped Codebase Awareness evidence and proofpack includes or references that summary. Do not pack project-level `.signum/cache/` scanner cache files by default.

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

After implementation:

1. Write `combined.patch` from the final worktree diff.
2. Run the scope gate against `inScope` and `allowNewFilesUnder`.
3. Run the execution policy compliance check and write `policy_violations.json` when violations exist.
4. Run the scope existence gate for declared in-scope files.
5. Run boundary verification and transition verification.
6. Store execute receipts under `receipts/` and run records under `runs/<runId>/`.

Policy violations, scope violations, or failed boundary/transition verification block the pipeline before AUDIT unless the contract explicitly allows the exception.

## Phase 3: AUDIT

Goal: determine whether the implementation actually satisfies the contract and whether new risks were introduced.

Audit has these layers:

### `mechanic`

Deterministic checks first:

- lint
- typecheck
- tests
- baseline comparison
- scope compliance

If new failures appear versus baseline, treat them as regressions.

### `policy scanner`

Run the zero-LLM policy scanner on `combined.patch` and write `policy_scan.json`.

Critical policy findings are deterministic block signals. Continue through synthesis so the final `audit_summary.json` records the reason instead of silently stopping without evidence.

### `review`

Optional multi-model review if external providers are available.

Recommended roles:

- Codex: orchestrator synthesis and local review
- Claude CLI: semantic review
- Gemini CLI: alternative review focused on performance or edge cases

External reviewers should get only the minimum context needed.

For risk-proportional review:

- low risk: deterministic audit plus one available semantic/local review is enough
- medium risk: use available external reviewers when ready, but degrade gracefully
- high risk: reduced external coverage should normally produce `HUMAN_REVIEW`, not `AUTO_OK`

Build `review_context.json` from changed-file history and issue references when available. Keep external Codex/Gemini-style prompts diff-focused; do not send hidden holdout details.

If provider CLIs are unavailable, continue with deterministic audit and Codex-only analysis.
If the current execution context has no usable outbound network or DNS, classify external reviewers as `network_error` and skip them immediately instead of waiting for long timeouts.
If a provider returns a transient upstream failure, retry once with a short backoff, then mark reduced coverage.
If a provider returns `auth_error`, do not retry automatically.

### `holdout verification`

Run hidden or extra scenarios if they exist.

If holdouts fail, the pipeline should not claim success even if visible acceptance criteria pass.

### `synthesis`

Write `audit_summary.json` from deterministic evidence plus available reviewer outputs.

At minimum include:

- `decision`: `AUTO_OK`, `AUTO_BLOCK`, or `HUMAN_REVIEW`
- `releaseVerdict`: release gate verdict such as `PASS` or `HOLD`
- `confidence`
- `availableReviews`
- `reviewCoverage`
- mechanic, policy, holdout, and review summaries
- reduced-coverage notes when external reviewers were skipped or failed

Synthesis rules:

- new mechanic regressions, failed boundary checks, critical policy findings, or CRITICAL review findings => `AUTO_BLOCK`
- MAJOR remaining findings, failed holdouts, mixed evidence, or materially reduced coverage on medium/high risk => `HUMAN_REVIEW`
- all deterministic checks pass, holdouts pass or were legitimately omitted, and no serious findings remain => `AUTO_OK`

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
- policy scanner summary
- review summaries
- external audit coverage summary
- final verdict
- `releaseVerdict`
- `reviewCoverage`
- `baselineComparison` when a previous proofpack exists
- confidence level
- artifact references or embedded content with SHA-256 checksums and size metadata
- Codebase Awareness `reuse_summary.json` evidence when Codebase Awareness was enabled
- `iterativeAudit` when more than one AUDIT pass was used
- approval and execution context envelopes when available
- receipt and snapshot references when available

Possible verdicts:

- `AUTO_OK`
- `HUMAN_REVIEW`
- `AUTO_BLOCK`

Guidance:

- regressions or critical audit findings => `AUTO_BLOCK`
- weak evidence or mixed findings => `HUMAN_REVIEW`
- deterministic checks pass and no serious findings => `AUTO_OK`

Do not upgrade to `AUTO_OK` if the audit coverage was materially reduced by external-review failures and the task risk is medium or high. In that case prefer `HUMAN_REVIEW`.

After proofpack assembly, write `anti_entropy_report.json` as a report-only follow-up artifact when the local helper is available. It must not change the pipeline decision.

### Finalization

After displaying the decision:

- `AUTO_OK`: archive the completed contract artifacts and clean the active working set automatically.
- `HUMAN_REVIEW`: keep artifacts by default and let the user choose archive, keep, or delete.
- `AUTO_BLOCK`: keep artifacts by default for debugging; archive or delete only after the user chooses.

Never delete the only copy of `contract.json` or `proofpack.json` unless the user explicitly chooses delete.

## Resume Behavior

If `contracts/index.json.activeContractId` or other pipeline artifacts already exist:

1. Inspect what phases are complete.
2. Resume from the first incomplete phase when safe.
3. If artifacts are inconsistent, prefer a clean restart and explain why.
4. Treat root-level legacy contract/artifact files as import signals only.
5. If a previous run is completed, prefer archive/close behavior over mutating it in place.

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
- If scope, policy, boundary, or transition verification fails, block before AUDIT and preserve evidence.
- If external reviewers are unavailable, degrade gracefully and mark reduced audit coverage.
- If the current sandbox or execution context cannot resolve or reach the provider network, classify external review as `network_error` and skip provider calls immediately.
- If an external provider returns a transient server-side failure, retry once, then mark reduced coverage.
- If an external provider returns an auth failure, record `auth_error` and continue without it.
- If reduced audit coverage affects a medium- or high-risk task, prefer `HUMAN_REVIEW` over `AUTO_OK`.
- If proofpack assembly fails, preserve intermediate artifacts and report the failure.
- If final restoration of the best iterative candidate fails, force `HUMAN_REVIEW` and preserve iteration artifacts.
- If finalization or archive is incomplete, keep the working set intact.

## Boundaries

- Do not skip CONTRACT just because the task seems obvious.
- Do not confuse a passing implementation with a passing audit.
- Do not claim blind validation if holdouts were not actually hidden.
- Do not let external review replace deterministic checks.
- Do not modify unrelated files under the cover of “pipeline work”.
- Do not materialize root `.signum/` runtime artifact files during normal runs.
- Do not send hidden holdout details to implementation or external review contexts.
