# Signum Reference

## Usage

```
/signum <task description>
```

Signum parses the task description and runs the full 4-phase pipeline automatically.

## Examples

### Simple feature (low risk)

```
/signum add a health check endpoint that returns 200 OK
```

Pipeline: contractor → baseline → engineer (1 attempt) → scope gate → mechanic + Claude review → proofpack.
Estimated cost: ~$0.10-0.20.

### Authentication (medium risk)

```
/signum add user authentication with JWT tokens
```

Pipeline: contractor → baseline → engineer (up to 3 repair attempts) → scope gate → mechanic + holdouts + Claude + Codex (security) + Gemini (performance) → synthesizer → proofpack.
Estimated cost: ~$0.30-0.60.

### Database migration (high risk)

```
/signum migrate user table from MongoDB to PostgreSQL
```

Pipeline: same as medium but contractor flags high risk with risk signals and holdout scenarios. All 3 model reviews weighted equally in synthesis.
Estimated cost: ~$0.50-1.00.

### Resume interrupted pipeline

```
# Start a pipeline
/signum refactor the payment module

# ...interrupt (Ctrl+C or close session)...

# Reopen and run the same command
/signum refactor the payment module
# Signum detects .signum/contract.json and asks: resume from Phase 2, or restart?
```

## Pipeline Phases

```
CONTRACT → EXECUTE → AUDIT → PACK
```

### Phase 1: CONTRACT

Contractor agent (haiku) scans the codebase and produces `.signum/contract.json` — a structured specification with goal, scope, acceptance criteria, holdout scenarios, and risk assessment.

Hard stop if `openQuestions` is non-empty — the user must answer before proceeding.

### Phase 2: EXECUTE

1. **Baseline capture** — orchestrator runs lint/typecheck/tests BEFORE any changes, saves to `.signum/baseline.json`.
2. **Engineer agent** (sonnet) implements the contract. Repair loop: up to 3 attempts of implement → check acceptance criteria → fix failures.
3. **Scope gate** — deterministic check that all modified files are within `inScope` or `allowNewFilesUnder`. Pipeline stops on scope violation.

Outputs: `.signum/baseline.json`, `.signum/combined.patch`, `.signum/execute_log.json`.

### Phase 3: AUDIT

Five independent verification layers:

1. **Mechanic** (bash, zero LLM) — runs linter, typechecker, tests. Compares with baseline to detect regressions vs pre-existing failures.
2. **Holdout validation** — runs hidden acceptance criteria the Engineer never saw (edge cases, negative tests from contract).
3. **Claude reviewer** (opus agent) — semantic review of contract + diff + mechanic results.
4. **Codex reviewer** (CLI, security-focused) — analyzes diff for security defects using `review-template-security.md`.
5. **Gemini reviewer** (CLI, performance-focused) — analyzes diff for performance defects using `review-template-performance.md`.

Synthesizer agent applies deterministic rules:
- **AUTO_OK**: no regressions + all reviews APPROVE + 2+ reviews parsed + holdouts pass
- **AUTO_BLOCK**: any regression (NEW failure vs baseline) OR any REJECT OR any CRITICAL finding
- **HUMAN_REVIEW**: everything else (mixed signals, only 1 review, CONDITIONAL verdicts, holdout failures)

Pre-existing failures (checks that failed in baseline AND still fail) no longer auto-block.

### Phase 4: PACK

Assembles `.signum/proofpack.json` — self-contained evidence bundle with embedded artifact contents, SHA-256 checksums, and confidence score.

## Artifacts

Live working-set artifacts are written to `.signum/` (auto-added to `.gitignore`). Durable per-contract snapshots are mirrored under `.signum/contracts/<contractId>/` for history/archive flows. The per-contract directory is not the active workspace for an in-flight run.

| File | Phase | Contents |
|------|-------|----------|
| `contract.json` | Contract | Goal, scope, acceptance criteria, holdout scenarios, risk level |
| `baseline.json` | Execute | Pre-change lint/typecheck/test exit codes |
| `combined.patch` | Execute | Full git diff of all changes |
| `execute_log.json` | Execute | Attempt history, check results, status |
| `mechanic_report.json` | Audit | Lint, typecheck, test results with baseline comparison and regression flags |
| `holdout_report.json` | Audit | Holdout scenario pass/fail counts |
| `reviews/claude.json` | Audit | Claude opus semantic review |
| `reviews/codex.json` | Audit | Codex CLI security review (or unavailable marker) |
| `reviews/gemini.json` | Audit | Gemini CLI performance review (or unavailable marker) |
| `audit_summary.json` | Audit | Synthesized decision with consensus reasoning and confidence scores |
| `proofpack.json` | Pack | Self-contained evidence bundle with embedded artifacts, checksums, and confidence |

Durable per-contract snapshots typically mirror:
- `contract.json`
- `proofpack.json`
- `audit_summary.json`
- `approval.json`
- `receipts/execute.json`

### contract.json fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `"3.0"`–`"3.7"` | Schema version |
| `glossaryVersion` | string | Version from `project.glossary.json` at contract creation time (optional, omitted when file absent) |
| `goal` | string | What to build (min 10 chars) |
| `inScope` | string[] | Items in scope (min 1) |
| `allowNewFilesUnder` | string[] | Directories where new files may be created (optional) |
| `outOfScope` | string[] | Explicitly excluded items |
| `acceptanceCriteria` | object[] | AC-N items with verify commands |
| `holdoutScenarios` | object[] | Hidden ACs not shown to Engineer (optional) |
| `riskLevel` | `low\|medium\|high` | Deterministic risk assessment |
| `riskSignals` | string[] | Why risk level was assigned |
| `openQuestions` | string[] | Must be empty to proceed |
| `contextInheritance` | object | Project context references (optional) |
| `contextInheritance.projectRef` | string\|null | Path to project.intent.md, "not_found", null (waiver), or absent (legacy) |
| `contextInheritance.projectIntentSha256` | string | SHA-256 of project.intent.md at contract creation |
| `contextInheritance.contextSnapshotHash` | string | SHA-256 hex digest over concatenated byte contents of all `staleIfChanged` files in array order, computed at contract creation time |
| `contextInheritance.staleIfChanged` | string[] | Upstream artifact paths tracked for staleness; at minimum includes `project.intent.md` when loaded |
| `contextInheritance.stalenessStatus` | `"fresh"\|"warning"\|"stale"` | Current staleness state: fresh=hash matches, warning=soft mismatch, stale=hash differs and policy=block |
| `contextInheritance.stalenessPolicy` | `"block"\|"warn"` | Action when upstream hash differs: block=halt pipeline (BLOCK), warn=continue with warning (default: `"warn"`) |
| `dependsOnContractIds` | string[] | ContractIds that must complete before this contract executes (user-declared, optional) |
| `supersedesContractIds` | string[] | ContractIds this contract replaces (user-declared, optional) |
| `supersededByContractId` | string | ContractId of the contract that replaces this one (optional) |
| `interfacesTouched` | string[] | Named interfaces, APIs, or module boundaries this contract modifies (optional) |
| `ambiguityCandidates` | object[] | Typed findings from ambiguity review pass: `{text, location, severity}` (optional, v3.7+) |
| `contradictionsFound` | object[] | Typed findings from contradiction review: `{claim_a, claim_b, type}` (optional, v3.7+) |
| `clarificationDecisions` | object[] | Decisions made during critique: `{question, decision, rationale}` (optional, v3.7+) |
| `assumptionProvenance` | object[] | Source tracking for assumptions: `{id, text, source, confidence}` (optional, v3.7+) |
| `readinessForPlanning` | object | Go/no-go gate: `{verdict: "go"\|"no-go", summary: string}` (optional, v3.7+) |

### project.glossary.json schema

Optional file at `PROJECT_ROOT/project.glossary.json`. When present, contractor reads it and sets `glossaryVersion` in the contract.

```json
{
  "version": "1.0.0",
  "canonicalTerms": ["term1", "term2", "..."],
  "aliases": {
    "forbidden-synonym": "canonical-term",
    "another-synonym": "another-canonical"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Glossary version string (mirrors `glossaryVersion` in contract) |
| `canonicalTerms` | string[] | Approved terminology for this project |
| `aliases` | object | Map of forbidden synonyms to their canonical replacements |

### Quality check scripts (lib/)

All Phase 1 quality checks are standalone shell scripts in `lib/`. Each follows the same interface:

```
lib/<check>.sh <contract.json> [--flag value ...]
  stdout: {"check":"<name>","status":"ok|warn|block|skip|error","summary":"...","findings":[...]}
  exit 0: check completed (any status)
  exit 1+: infra error (bad args, missing jq, corrupt input)
```

| Script | Purpose | Extra args |
|--------|---------|-----------|
| `lib/glossary-check.sh` | Forbidden synonym scan | `--glossary <path>` |
| `lib/terminology-check.sh` | Cross-contract synonym proliferation | `--index <path>` `--glossary <path>` |
| `lib/overlap-check.sh` | inScope overlap between active contracts | `--index <path>` |
| `lib/assumption-check.sh` | Assumption contradiction detection | `--index <path>` |
| `lib/adr-check.sh` | ADR relevance for inScope paths | `--project-root <dir>` |
| `lib/staleness-check.sh` | Upstream artifact staleness (pure, no mutation) | `--project-root <dir>` |
| `lib/prose-check.sh` | Prose quality gate (banned phrases, quantifiers, passive voice) | — |

The orchestrator (`commands/signum.md`) calls each script, reads JSON output, merges findings into `spec_quality.json`, and applies mutations/blocking decisions. Scripts never modify `contract.json` or `spec_quality.json` directly.

#### upstream_staleness_check

Runs during Phase 1 spec quality gate (after the `adr_relevance_check`). Skipped when `contextInheritance.staleIfChanged` is absent or empty.

When `staleIfChanged` is a non-empty array, the check always executes:

1. Concatenates the byte contents of all files listed in `staleIfChanged` (in array order)
2. Computes SHA-256 of the concatenated bytes
3. Compares the result to `contextInheritance.contextSnapshotHash`

Outcome depends on `contextInheritance.stalenessPolicy` (default `"warn"`):

| Hash result | Policy | Outcome |
|-------------|--------|---------|
| Matches | any | `fresh` — pipeline continues |
| Differs | `"warn"` | `warning` — WARN emitted, pipeline continues |
| Differs | `"block"` | `stale` — BLOCK emitted, pipeline stops; re-run Contractor to refresh |

`contextInheritance.stalenessStatus` is updated in-place in `contract.json` after the check.

#### glossary_check

Runs during Phase 1 spec quality gate (Step 1.3.5). Scans the contract's `goal`, `inScope` items, and AC `description` fields for any term appearing in the `aliases` map (case-insensitive whole-word match). Emits a `WARN` line for each match with the forbidden term and its canonical replacement. Results are written to `glossary_warnings` in `spec_quality.json`. This check is **non-blocking** — it never fails the pipeline or reduces the numeric spec quality score.

#### terminology_consistency_check

Runs during Phase 1 spec quality gate (Step 1.3.5) after `glossary_check`. Reads `.signum/contracts/index.json`, extracts goal text from active contracts, and scans for synonym proliferation (same concept appearing under two different terms across contracts). Emits `WARN` lines on synonym proliferation. When `.signum/contracts/index.json` is absent or contains no contracts with active status, the check outputs a skip message and does not block or fail. This check is **non-blocking**.

#### cross_contract_overlap_check

Runs during Phase 1 spec quality gate. Reads `.signum/contracts/index.json`, compares the new contract's `inScope` against active contracts' `inScope` arrays. Emits `WARN` when files overlap with another active contract, listing the overlapping files and the conflicting contract ID. Skips gracefully when index is absent or has no active contracts. **Non-blocking.**

#### assumption_contradiction_check

Runs during Phase 1 spec quality gate after `cross_contract_overlap_check`. Reads assumptions from the new contract and compares against assumptions of active contracts in `index.json`. Emits `WARN` when assumption text contains contradictory terms (e.g., one contract assumes "X is true" while another assumes "X is false"). **Non-blocking.**

#### adr_relevance_check

Runs during Phase 1 spec quality gate. Scans for `docs/adr/` or `docs/decisions/` directories. If ADR files exist and the contract's `inScope` touches paths that match ADR file globs, emits `WARN` suggesting the contract reference relevant ADRs. Skips when no ADR directories exist. **Non-blocking.**

### Iterative AUDIT (v4.6+)

When AUDIT finds MAJOR or CRITICAL issues, it enters an iterative repair loop:

1. Engineer fixes findings (fresh agent, clean context)
2. Full review cycle re-runs from scratch
3. Repeats until convergence or max iterations

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `SIGNUM_AUDIT_MAX_ITERATIONS` | `20` | Maximum audit fix iterations before terminal decision |
| `SIGNUM_CI_RELAXED` | `false` | If `"true"`, HUMAN_REVIEW maps to exit 0 instead of 78 |

Iteration artifacts are stored in `.signum/iterations/01/`, `.signum/iterations/02/`, etc. Each contains the full set of audit artifacts for that pass.

The proofpack includes an `iterativeAudit` section when >1 iteration was used, with per-iteration summaries, resolved/remaining findings, and the best iteration number.

### proofpack.json fields (v4.6)

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `"4.6"` | Schema version (v4.6 adds iterativeAudit, ciContext, baselineComparison, contractSource) |
| `signumVersion` | string | Signum version that generated this proofpack |
| `createdAt` | string | ISO 8601 timestamp of proofpack creation |
| `runId` | string | `signum-YYYY-MM-DD-XXXXXX` |
| `decision` | `AUTO_OK\|AUTO_BLOCK\|HUMAN_REVIEW` | Final verdict |
| `summary` | string | One-line human-readable summary |
| `confidence` | object | `{ overall: 0-100 }` — weighted confidence score |
| `auditChain` | object | `{ contractSha256, approvedAt, baseCommit }` — immutable audit anchors |
| `contract` | envelope | Redacted contract (holdouts stripped), `fullSha256` for original |
| `diff` | envelope | Patch content (omitted if >100KB) |
| `baseline` | envelope | Pre-change lint/typecheck/test results |
| `executeLog` | envelope | Attempt history and check results |
| `checks.mechanic` | envelope | Lint, typecheck, test with regression flags |
| `checks.holdout` | envelope | Holdout scenario pass/fail (if applicable) |
| `checks.reviews.*` | envelope | Per-provider review (dynamic keys) |
| `checks.auditSummary` | envelope | Synthesized decision with confidence |
| `iterativeAudit` | object | Iteration metadata (v4.6+, present only when >1 iteration) |
| `iterativeAudit.iterationsUsed` | integer | Total iterations run |
| `iterativeAudit.bestIteration` | integer | Iteration with best score |
| `iterativeAudit.auditIterations` | array | Per-iteration summaries (score, findings count, decision) |
| `iterativeAudit.resolvedFindings` | array | Findings fixed during iterations |
| `iterativeAudit.remainingFindings` | array | Findings still present after all iterations |

Each artifact uses the **envelope format**: `{ content, sha256, sizeBytes, status, omitReason? }`.
- `status: present` — content embedded
- `status: omitted` — content null, validate by sha256
- `status: error` — generation failed, see omitReason

### Confidence scoring

The synthesizer computes a weighted confidence score (0-100):

| Component | Weight | Source |
|-----------|--------|--------|
| `execution_health` | 40% | ACs passed ratio minus repair attempt penalty |
| `baseline_stability` | 30% | Proportion of checks with no regressions |
| `review_alignment` | 30% | Reviewer agreement level (100=unanimous approve, 0=no approvals) |

### Review JSON format

Each reviewer produces:

```json
{
  "verdict": "APPROVE|REJECT|CONDITIONAL",
  "findings": [
    {
      "severity": "CRITICAL|MAJOR|MINOR",
      "category": "bug|security|performance|spec-gap|missing-test",
      "file": "src/auth.ts",
      "line": 42,
      "description": "...",
      "suggestion": "..."
    }
  ],
  "summary": "..."
}
```

## Requirements

| Dependency | Required | Purpose |
|-----------|----------|---------|
| Claude Code | Yes | Runtime environment |
| git | Yes | Diff generation, scope gate |
| jq | Yes | JSON validation and assembly |
| python3 | Yes | Review prompt template substitution |
| sha256sum or shasum | Yes | Checksum computation (auto-detected) |
| Codex CLI | No | Security-focused review in AUDIT phase |
| Gemini CLI | No | Performance-focused review in AUDIT phase |

## Troubleshooting

### `jq: command not found`

Install jq:
- macOS: `brew install jq`
- Ubuntu/Debian: `apt install jq`
- Other: [jq downloads](https://jqlang.github.io/jq/download/)

### External provider auth errors

```
codex: auth expired → run: codex auth
gemini: auth expired → run: gemini login
```

Signum continues without the provider if auth fails.

### Provider timeout

External providers are killed after 180 seconds. The review continues with remaining providers. Check `.signum/reviews/` for provider status.

### `.signum/` exists from previous run

Normal behavior. Signum detects existing `contract.json` and offers:
- **Resume**: continue from Phase 2
- **Restart**: clear artifacts, start fresh

### Plugin not loading

1. Verify installation: `claude plugin list | grep signum`
2. Reinstall: `claude plugin install signum@emporium`
3. Open a new Claude Code session (plugins load at session start)
