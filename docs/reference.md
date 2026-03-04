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

All artifacts are stored in `.signum/` (auto-added to `.gitignore`):

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

### contract.json fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `"3.0"` | Always "3.0" |
| `goal` | string | What to build (min 10 chars) |
| `inScope` | string[] | Items in scope (min 1) |
| `allowNewFilesUnder` | string[] | Directories where new files may be created (optional) |
| `outOfScope` | string[] | Explicitly excluded items |
| `acceptanceCriteria` | object[] | AC-N items with verify commands |
| `holdoutScenarios` | object[] | Hidden ACs not shown to Engineer (optional) |
| `riskLevel` | `low\|medium\|high` | Deterministic risk assessment |
| `riskSignals` | string[] | Why risk level was assigned |
| `openQuestions` | string[] | Must be empty to proceed |

### proofpack.json fields (v4.0)

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `"4.0"` | Always "4.0" |
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
