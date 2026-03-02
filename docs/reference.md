# Sigil Reference

## Usage

```
/sigil <task description>
```

Sigil parses the task description and runs the full 4-phase pipeline automatically.

## Examples

### Simple feature (low risk)

```
/sigil add a health check endpoint that returns 200 OK
```

Pipeline: contractor → engineer (1 attempt) → mechanic + Claude review → proofpack.
Estimated cost: ~$0.10-0.20.

### Authentication (medium risk)

```
/sigil add user authentication with JWT tokens
```

Pipeline: contractor → engineer (up to 3 repair attempts) → mechanic + Claude + Codex + Gemini → synthesizer → proofpack.
Estimated cost: ~$0.30-0.60.

### Database migration (high risk)

```
/sigil migrate user table from MongoDB to PostgreSQL
```

Pipeline: same as medium but contractor flags high risk with risk signals. All 3 model reviews weighted equally in synthesis.
Estimated cost: ~$0.50-1.00.

### Resume interrupted pipeline

```
# Start a pipeline
/sigil refactor the payment module

# ...interrupt (Ctrl+C or close session)...

# Reopen and run the same command
/sigil refactor the payment module
# Sigil detects .sigil/contract.json and asks: resume from Phase 2, or restart?
```

## Pipeline Phases

```
CONTRACT → EXECUTE → AUDIT → PACK
```

### Phase 1: CONTRACT

Contractor agent (haiku) scans the codebase and produces `.sigil/contract.json` — a structured specification with goal, scope, acceptance criteria, and risk assessment.

Hard stop if `openQuestions` is non-empty — the user must answer before proceeding.

### Phase 2: EXECUTE

Engineer agent (sonnet) implements the contract. Repair loop: up to 3 attempts of implement → check acceptance criteria → fix failures.

Outputs: `.sigil/combined.patch`, `.sigil/execute_log.json`.

### Phase 3: AUDIT

Three independent verification layers:

1. **Mechanic** (bash, zero LLM) — runs linter, typechecker, tests. Auto-detects ruff/eslint, mypy/tsc, pytest/npm test/cargo test.
2. **Claude reviewer** (opus agent) — semantic review of contract + diff + mechanic results.
3. **External reviewers** (Codex CLI + Gemini CLI) — same review template, 3-level output parser, optional (continue if unavailable).

Synthesizer agent applies deterministic rules:
- **AUTO_OK**: all available reviews APPROVE + mechanic passes + 2+ reviews parsed
- **AUTO_BLOCK**: any REJECT or CRITICAL finding or mechanic fails
- **HUMAN_REVIEW**: everything else (mixed signals, only 1 review, CONDITIONAL verdicts)

### Phase 4: PACK

Assembles `.sigil/proofpack.json` — machine-readable evidence bundle with SHA-256 checksums for every artifact.

## Artifacts

All artifacts are stored in `.sigil/` (auto-added to `.gitignore`):

| File | Phase | Contents |
|------|-------|----------|
| `contract.json` | Contract | Goal, scope, acceptance criteria, risk level |
| `combined.patch` | Execute | Full git diff of all changes |
| `execute_log.json` | Execute | Attempt history, check results, status |
| `mechanic_report.json` | Audit | Lint, typecheck, test results with exit codes |
| `reviews/claude.json` | Audit | Claude opus semantic review |
| `reviews/codex.json` | Audit | Codex CLI review (or unavailable marker) |
| `reviews/gemini.json` | Audit | Gemini CLI review (or unavailable marker) |
| `audit_summary.json` | Audit | Synthesized decision with consensus reasoning |
| `proofpack.json` | Pack | Complete evidence bundle with checksums |

### contract.json fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `"2.0"` | Always "2.0" |
| `goal` | string | What to build (min 10 chars) |
| `inScope` | string[] | Items in scope (min 1) |
| `outOfScope` | string[] | Explicitly excluded items |
| `acceptanceCriteria` | object[] | AC-N items with verify commands |
| `riskLevel` | `low\|medium\|high` | Deterministic risk assessment |
| `riskSignals` | string[] | Why risk level was assigned |
| `openQuestions` | string[] | Must be empty to proceed |

### proofpack.json fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `"2.0"` | Always "2.0" |
| `runId` | string | `sigil-YYYY-MM-DD-XXXXXX` |
| `decision` | `AUTO_OK\|AUTO_BLOCK\|HUMAN_REVIEW` | Final verdict |
| `checksums` | object | SHA-256 of each artifact |
| `summary` | string | One-line human-readable summary |

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
| git | Yes | Diff generation |
| jq | Yes | JSON validation and assembly |
| sha256sum | Yes | Checksum computation |
| Codex CLI | No | External review in AUDIT phase |
| Gemini CLI | No | External review in AUDIT phase |

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

Sigil continues without the provider if auth fails.

### Provider timeout

External providers are killed after 180 seconds. The review continues with remaining providers. Check `.sigil/reviews/` for provider status.

### `.sigil/` exists from previous run

Normal behavior. Sigil detects existing `contract.json` and offers:
- **Resume**: continue from Phase 2
- **Restart**: clear artifacts, start fresh

### Plugin not loading

1. Verify installation: `claude plugin list | grep sigil`
2. Reinstall: `claude plugin install sigil@emporium`
3. Open a new Claude Code session (plugins load at session start)
