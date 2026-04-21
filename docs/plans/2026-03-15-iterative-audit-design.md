# Iterative AUDIT — Design Plan for Signum v4.2

**Date:** 2026-03-15
**Status:** Draft
**Authors:** Claude + Codex (GPT-5.4) review

## Problem

AUDIT is single-pass. If reviewers find MAJOR/CRITICAL bugs, pipeline stops and human must intervene. Code quality depends on engineer getting it right on first try after EXECUTE.

## Solution

Make AUDIT iterative: review → fix → re-review → repeat until convergence or max iterations. No human in the loop.

## Architecture Decision

Iterative AUDIT is a **loop within Phase 3**, not a new phase. Pipeline stays `CONTRACT → EXECUTE → AUDIT → PACK`. AUDIT internally runs multiple passes, each pass being a full repair subpipeline.

## Flow

```
EXECUTE → engineer produces code → combined.patch
  ↓
AUDIT pass 1:
  scope gate → policy check → mechanic → holdouts →
  AI reviews (risk-proportional) → synthesizer
  → ALL APPROVE, no regressions? → AUTO_OK → PACK ✓
  → MAJOR/CRITICAL findings OR mechanic regression OR holdout failure? ↓

AUDIT-FIX iteration N:
  fresh engineer agent (clean context) → gets repair brief →
  fixes → regenerate combined.patch →
  scope gate → policy check → mechanic → holdouts →
  AI reviews (full, from scratch) → synthesizer
  → ALL APPROVE? → AUTO_OK → PACK ✓
  → worse than best-so-far? → rollback to best candidate → next iteration
  → no improvement 2 iterations in a row? → early stop
  → max iterations reached? → terminal decision

Terminal decision (based on best-of-N candidate):
  → clean                    → AUTO_OK
  → only MINOR remaining     → AUTO_OK + remainingFindings
  → MAJOR remaining          → HUMAN_REVIEW + terminalReason + remainingSeverity
  → CRITICAL remaining       → AUTO_BLOCK
```

## Conventions

- **Numbering**: pass 1 = iteration 1 (the initial EXECUTE candidate). Iteration 2 = first fix attempt. `iterations/01/` stores pass 1 artifacts, `iterations/02/` stores pass 2, etc.
- **Branch point**: iteration loop begins immediately after Step 3.5 (synthesizer). If synthesizer decision is AUTO_OK or only MINOR findings remain → go to PACK. Otherwise → enter repair loop.
- **Tie-break**: if two iterations have equal score, the **earlier** one wins (prefer less churn).

## Detailed Design

### 1. Iteration Config

```
SIGNUM_AUDIT_MAX_ITERATIONS=20  (default, configurable)
```

Early stop: if severity-weighted score doesn't improve for 2 consecutive iterations, stop. Best-of-N: pipeline always keeps the best candidate, not the last.

### 2. Repair Subpipeline (per iteration)

Each iteration runs the FULL safety chain, not just engineer + reviews:

1. **Engineer agent** (Sonnet, fresh spawn, clean context)
2. **Regenerate combined.patch** (git diff)
3. **Scope gate** (changed files within inScope)
4. **Policy compliance** (bash_deny_patterns, tool restrictions)
5. **Repo-contract invariants** (Step 3.0.5 — if regression, AUTO_BLOCK immediately)
6. **Mechanic** (lint, typecheck, tests vs baseline)
7. **Holdout validation** (if medium/high risk)
8. **AI reviews** (risk-proportional: low=Claude, medium/high=full panel)
9. **Synthesizer** (deterministic verdict)

### 3. Risk-Proportional Review (preserved)

Iterations follow the same risk-proportional ceremony as pass 1:

| Risk | Reviews per iteration |
|------|----------------------|
| Low | Claude (Opus) only |
| Medium | Claude + available externals |
| High | Claude + Codex + Gemini (full panel) |

NOT escalated to full panel on iteration — stays consistent with contract riskLevel.

### 4. Models

| Role | Model | Notes |
|------|-------|-------|
| Engineer (fixer) | Sonnet | Fresh spawn each iteration |
| Claude reviewer | Opus | Always, from agent definition |
| Codex reviewer | GPT-5.4 | From emporium-providers.local.md |
| Gemini reviewer | Config/CLI default | From emporium-providers.local.md |
| Synthesizer | Sonnet | Deterministic rules |

Fresh-reviewer rule (Opus→Sonnet after repair) is **removed**. Review always uses best model.

### 5. What Triggers Next Iteration

Any of:
- MAJOR or CRITICAL reviewer findings
- Mechanic regressions (NEW failures vs baseline)
- Holdout failures or errors

Does NOT trigger:
- MINOR-only findings
- Parse failures alone (treated as unavailable reviewer)

### 6. Engineer Repair Brief

Order matters — deterministic signals first:

```
## Repair Brief (iteration N)

### Deterministic Failures
- Mechanic: lint regression on src/api.ts (was passing, now fails)
- Holdout: 1 failed (category: error handling)
  [NO details, NO scripts, NO expected values]

### Review Findings
- [f1a2b3c4] MAJOR bug src/handler.ts:42 — null dereference when input is empty array
  Evidence: `const first = items[0].name`
- [d5e6f7g8] CRITICAL security src/auth.ts:15 — SQL injection in query builder
  Evidence: `db.query("SELECT * FROM users WHERE id=" + userId)`

### Constraints
- Fix ONLY the listed findings
- Minimal diff — no unrelated refactors
- Do not break already-passing acceptance criteria
- Re-run visible AC verifies after fix
```

### 6.1. Repair Brief — Engineer Invocation

Repair-mode engineer reads the SAME canonical files as normal mode plus the brief, all under the active contract artifact root (`$ARTIFACT_ROOT`):
- `$ARTIFACT_ROOT/contract-engineer.json` (original contract, holdouts redacted)
- `$ARTIFACT_ROOT/baseline.json` (pre-change check state)
- `$ARTIFACT_ROOT/repair_brief.json` (new — the repair brief)

Orchestrator prompt to engineer agent:

```
Read $ARTIFACT_ROOT/contract-engineer.json for scope and acceptance criteria.
Read $ARTIFACT_ROOT/baseline.json for pre-existing check state.
Read $ARTIFACT_ROOT/repair_brief.json for the specific issues to fix.
Fix ONLY the issues listed in the repair brief. Do not refactor, do not add features.
After fixing, run the visible AC verifies to confirm you didn't break them.
Write $ARTIFACT_ROOT/combined.patch and $ARTIFACT_ROOT/execute_log.json.
```

The brief is a delta — engineer still works within the original contract boundaries.

### 7. Holdout Sanitization

Engineer NEVER sees holdout details. Sanitized message format:

```
N holdout(s) failed (categories: <list>)
```

Categories derived from holdout description via simple keyword extraction:
- "boundary" / "edge case" / "limit" → boundary input
- "error" / "exception" / "fail" → error handling
- "concurrent" / "race" / "parallel" → concurrency
- "empty" / "null" / "missing" → null/empty input
- fallback → "unspecified"

### 8. Per-Iteration Storage

```
.signum/contracts/<contractId>/
  iterations/
    01/
      combined.patch
      mechanic_report.json
      holdout_report.json
      reviews/
        claude.json
        codex.json
        gemini.json
      audit_summary.json
      repair_brief.json      # what was sent to engineer
    02/
      ...
  audit_iteration_log.json   # summary of all iterations
```

Each iteration's artifacts stored separately. No overwrites. Canonical working copies in the active contract artifact root are always overwritten to match the active candidate; `iterations/*` remain immutable snapshots. Root `.signum/` compatibility views may exist during the migration, but they are not the source of truth.

**Iteration 01** = initial EXECUTE candidate (pass 1 artifacts, before any fix).

**Cleanup rules:**
- On pipeline restart (user chooses "restart from Phase 1"), delete `iterations/`, `audit_iteration_log.json`, `flaky_tests.json` alongside existing cleanup list
- On archive mode, purge `iterations/` (only contract + proofpack + audit_summary kept)
- On resume mid-audit: discard partial iteration artifacts, continue from last complete iteration number

### 9. Best-of-N with Rollback

Score each iteration deterministically:

```
score = -(criticals * 1000) - (mechanic_regressions * 500)
        - (holdout_failures * 200) - (majors * 50) - (minors * 1)
```

Higher = better (0 = perfect).

Rules:
- Track `best_score` and `best_iteration`
- If iteration N score < best_score: rollback working tree to best candidate's patch before next iteration
- Final proofpack packages the **best candidate**, not the last attempt
- `audit_iteration_log.json` records all iterations including rollbacks

### 10. Finding Fingerprints

Stable ID for cross-iteration tracking:

```
fingerprint = sha256(category + file + normalized_comment)[:8]
```

- Severity NOT in hash (drifts between models/iterations)
- `normalized_comment` = lowercase, strip whitespace, remove line numbers
- Synthesizer tracks: resolved (was in N-1, not in N), persisting (in both), new (only in N)

### 11. Terminal Verdicts (NO new verdict type)

Keep existing 3 verdicts. Add metadata fields to audit_summary:

```json
{
  "decision": "HUMAN_REVIEW",
  "iterationsUsed": 4,
  "iterationsMax": 20,
  "earlyStop": true,
  "earlyStopReason": "no improvement for 2 consecutive iterations",
  "bestIteration": 3,
  "terminalReason": "1 MAJOR finding persists after 4 iterations",
  "remainingSeverity": "MAJOR",
  "remainingFindings": [...],
  "resolvedFindings": [...],
  "ciRecommendation": "review remaining MAJOR finding manually"
}
```

Terminal mapping:
| Best candidate state | Decision |
|---------------------|----------|
| Clean (all APPROVE, no regressions) | AUTO_OK |
| Only MINOR remaining | AUTO_OK + remainingFindings |
| MAJOR remaining | HUMAN_REVIEW + metadata |
| CRITICAL remaining | AUTO_BLOCK |

CI strict/relaxed mode decides how to handle HUMAN_REVIEW:
- strict: exit 78 (block)
- relaxed: exit 0 (pass with warning)

### 12. Proofpack Extension

Add to proofpack schema:

```json
{
  "auditIterations": [
    {
      "pass": 1,
      "score": -50,
      "findingsCount": { "critical": 0, "major": 1, "minor": 2 },
      "mechanicRegressions": false,
      "holdoutFailures": 0,
      "decision": "HUMAN_REVIEW"
    },
    {
      "pass": 2,
      "score": -1,
      "findingsCount": { "critical": 0, "major": 0, "minor": 1 },
      "mechanicRegressions": false,
      "holdoutFailures": 0,
      "decision": "AUTO_OK"
    }
  ],
  "bestIteration": 2,
  "resolvedFindings": ["f1a2b3c4"],
  "remainingFindings": []
}
```

Full per-iteration artifacts are stored under the active contract artifact root in `iterations/` but NOT embedded in proofpack (too large). Proofpack embeds summaries only.

### 13. Synthesizer Changes

Synthesizer needs iteration-awareness:

- Read `audit_iteration_log.json` to know iteration number
- Apply same deterministic rules per iteration
- Additional output: `iterationScore`, `resolvedSinceLastPass`, `newSinceLastPass`
- Early stop recommendation: if score didn't improve → set `recommendEarlyStop: true`

### 14. signum-ci.sh Changes

No new exit codes needed:

```
0  — AUTO_OK
1  — AUTO_BLOCK
78 — HUMAN_REVIEW
```

New env vars:
```
SIGNUM_AUDIT_MAX_ITERATIONS — default 20
SIGNUM_CI_RELAXED — if "true", HUMAN_REVIEW maps to exit 0 instead of 78
```

## Files to Modify

| File | Change |
|------|--------|
| `commands/signum.md` | Add iteration loop in Phase 3, repair subpipeline, per-iteration storage |
| `agents/synthesizer.md` | Iteration-aware scoring, early stop, cross-iteration tracking |
| `agents/reviewer-claude.md` | Remove fresh-reviewer rule, always Opus |
| `agents/engineer.md` | Document repair brief format (engineer itself unchanged) |
| `lib/schemas/proofpack.schema.json` | Add auditIterations, resolvedFindings, remainingFindings, metadata fields |
| `lib/signum-ci.sh` | Add SIGNUM_AUDIT_MAX_ITERATIONS, SIGNUM_CI_RELAXED |
| `lib/templates/signum-gate.yml` | Add iteration config vars |
| `docs/how-it-works.md` | Update AUDIT section for iterative flow |
| `docs/reference.md` | Document new env vars, iteration behavior |
| `CHANGELOG.md` | v4.2.0 entry |
| `commands/signum.md` (restart/archive) | Add `iterations/`, `audit_iteration_log.json`, `flaky_tests.json` to cleanup lists |
| `tests/test-signum-ci.sh` | Add tests for SIGNUM_CI_RELAXED strict vs relaxed mapping |

### 15. Flaky Test Handling in Mechanic

Add retry logic to mechanic's test runner (Step 3.1):

**Scope: v4.2 flaky test retry is pytest-only.** Other runners (jest, cargo, go test) only record suite-level exit codes today — for those, suite-level instability (exit code flip-flops between iterations without code change) is capped at `HUMAN_REVIEW`.

**pytest retry:**
```bash
# On NEW test failure (not in baseline):
for failing_test in $NEW_FAILURES; do
  PASS_COUNT=0
  for attempt in 1 2; do
    pytest "$failing_test" --tb=no -q > /dev/null 2>&1 && PASS_COUNT=$((PASS_COUNT + 1))
  done
  if [ $PASS_COUNT -ge 1 ]; then
    # Mixed results (1 or 2 of 3 passed) → flaky
    mark_flaky "$failing_test"
  fi
done
```

**Non-pytest runners:** no per-test retry. If suite exit code differs from baseline without code changes between iterations, treat as suite-level flaky.

**Non-rerunnable failures** (build errors, panics before test discovery, infra timeouts): always counted as real regressions, no retry.

Flaky state persisted in `flaky_tests.json` under the active contract artifact root:
```json
{
  "tests": [
    { "name": "test_concurrent_write", "firstSeen": 1, "flipFlops": 2, "status": "knownFlaky" }
  ]
}
```

## Risks

1. **Cost explosion** — mitigated by early stop + best-of-N (won't burn 20 iterations on oscillation)
2. **Holdout leakage** — mitigated by sanitization (category only, no details)
3. **Scope creep in fixes** — mitigated by scope gate + policy check every iteration
4. **Artifact bloat** — mitigated by proofpack embeds summaries, not full iteration artifacts

## Resolved Questions

### Q1: Wall-clock budget

**Deferred.** Early stop + max iterations are sufficient for now. Wall-clock budget (`SIGNUM_AUDIT_TIMEOUT`) can be added later when we have real data on iteration durations. Outer CI job timeout serves as crash protection in the meantime.

### Q2: Rollback mechanism

**Restore immutable baseline + re-apply best iteration's `combined.patch`.**

Procedure:
1. `git clean -fd` (remove untracked files from failed candidate — they survive `git checkout`)
2. `git checkout $BASE_COMMIT -- .` (BASE_COMMIT from `execution_context.json`, captured in Step 2.0)
3. `git apply "$ARTIFACT_ROOT/iterations/<best>/combined.patch"`
4. Copy `$ARTIFACT_ROOT/iterations/<best>/{mechanic_report,holdout_report,audit_summary}.json` → canonical working copies in `$ARTIFACT_ROOT/`
5. Copy `$ARTIFACT_ROOT/iterations/<best>/reviews/*` → `$ARTIFACT_ROOT/reviews/`
6. Regenerate canonical `$ARTIFACT_ROOT/combined.patch`
7. If apply fails → stop, return `HUMAN_REVIEW` with `terminalReason: "rollback_patch_apply_failed"`

Each iteration's `combined.patch` already persisted in `iterations/N/`. No git stash, no worktrees, no temporary commits.

**Note:** `git clean -fd` excludes `.signum/` (already in `.gitignore`). Only project files are cleaned.

Rejected alternatives:
- git checkout to commits — too dependent on git state, clobbers working tree
- git stash — opaque, operationally brittle
- worktrees — overkill for rollback; save for broader "ephemeral Signum" design

Constraint: iterative AUDIT assumes clean CI checkout or stable baseline.

### Q3: Flaky tests

**Retry + track. No default baseline double-run.**

When mechanic detects a NEW test failure:
1. Retry the failing test(s) **2 more times** (3 total observations)
2. **2 of 3 fail** → real regression, counted in `hasRegressions` and score
3. **Mixed results** (1 of 3 or 2 of 3 pass) → `flaky candidate`, excluded from `hasRegressions` and score
4. Persist in `$ARTIFACT_ROOT/flaky_tests.json` (run-local, not committed)
5. If same test flip-flops across iterations → promote to `knownFlaky`
6. If instability is suite-level (not attributable to specific tests) → cap at `HUMAN_REVIEW`

Rationale: current mechanic is single-shot and synthesizer treats any regression as blocking. Without flaky handling, one flaky test can force 20 useless fix iterations. Targeted retry only costs extra time when there's actual instability, unlike mandatory double-run baseline which doubles test cost on every pipeline run.
