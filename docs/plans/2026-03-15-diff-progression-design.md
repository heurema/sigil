# Diff Progression for Iterative AUDIT

**Date:** 2026-03-15
**Status:** Draft
**Inspiration:** ralphex (umputun/ralphex) — first iteration shows full branch diff, subsequent iterations show only uncommitted delta

## Problem

In iterative AUDIT, reviewers see the full `combined.patch` (entire feature diff from base) on every iteration. On iteration 5 of a 500-line feature, the reviewer re-reads all 500 lines to find whether a 12-line fix resolved the previous finding. This causes:

1. **Reviewer noise** — re-discovering old issues that were already accepted or are outside the fix scope
2. **Wasted tokens** — Opus/GPT-5.4/Gemini process the full diff every time (~$0.10-0.30 per review)
3. **Slow convergence** — findings that aren't about the fix delay resolution
4. **Context dilution** — the actual fix is buried in hundreds of unchanged lines

## Solution

Provide reviewers with **two artifacts** starting from iteration 2:

1. `combined.patch` — full feature diff from base (unchanged, for full context)
2. `iteration_delta.patch` — only what changed since the previous best candidate

The reviewer prompt instructs: "Focus your review on the delta. Use the full patch for context only."

## Design

### Delta Computation

#### Ownership

The **orchestrator** owns delta generation — not the engineer. After the repair success gate (Step 3.6.2) passes, the orchestrator runs both capture commands from a single place:

```bash
ARTIFACT_ROOT=".signum/contracts/<contractId>"

# After engineer completes repair and repair success gate passes (Step 3.6.2):
# git diff (unstaged) = iteration delta; engineer started from best candidate state
git diff > "$ARTIFACT_ROOT/iteration_delta.patch"
# git diff $BASE = full combined patch from base commit
git diff "$BASE" > "$ARTIFACT_ROOT/combined.patch"
```

The engineer always starts from the best candidate state (after rollback), so `git diff` (unstaged changes) equals exactly what the fix changed. `git diff $BASE` then gives the full feature diff. Both are computed by the orchestrator immediately after the repair gate, before launching reviews.

#### Artifact Lifecycle

**Before repair** — clear stale artifacts alongside execute_log and combined.patch:

```bash
rm -f "$ARTIFACT_ROOT/iteration_delta.patch" \
      "$ARTIFACT_ROOT/execute_log.json" \
      "$ARTIFACT_ROOT/combined.patch"
```

**Post-repair guard** — if delta is absent or zero-length after repair, mark iteration as non-improving and skip Steps 3.1.5–3.5 (delta-focused review path):

```bash
DELTA_SIZE=$(wc -c < "$ARTIFACT_ROOT/iteration_delta.patch" 2>/dev/null || echo 0)
if [ "$DELTA_SIZE" -eq 0 ]; then
  echo "Delta absent or empty — non-improving iteration, skipping delta review path"
  # falls through to existing REPAIR_SKIP / no-op handling
fi
```

**Store in iteration directory** — copy delta alongside combined.patch:

```bash
cp "$ARTIFACT_ROOT/iteration_delta.patch" "$ITER_DIR/iteration_delta.patch"
```

**Rollback sync** — when rolling back to a best iteration, copy its delta:

```bash
cp "$ARTIFACT_ROOT/iterations/$(printf '%02d' "$BEST_ITERATION")/iteration_delta.patch" \
   "$ARTIFACT_ROOT/iteration_delta.patch" 2>/dev/null || rm -f "$ARTIFACT_ROOT/iteration_delta.patch"
```

**Restart/archive cleanup** — add `iteration_delta.patch` to cleanup lists alongside combined.patch and execute_log in both restart and archive routines.

### Reviewer Prompt Changes

**Pass 1** (no delta available):
```
Review the full diff against the contract requirements.
[existing prompt unchanged]
```

**Pass 2+** (delta available):
```
Review this code change. Two diffs are provided:

1. FULL DIFF (complete feature from base):
{combined_patch}

2. DELTA (what changed in this fix iteration):
{iteration_delta}

FOCUS your review on the DELTA — these are the changes made to fix previous findings.
- Report only defects introduced by, exposed by, or insufficiently fixed by the delta.
- Cite changed delta lines as primary evidence when possible.
- Use the full diff only for understanding context (how the delta fits into the larger change), not for re-reporting untouched pre-existing issues.
```

### Storage

```
.signum/contracts/<contractId>/
  iteration_delta.patch          # current delta (canonical working copy)
  iterations/
    01/
      combined.patch             # full diff (no delta for pass 1)
    02/
      combined.patch             # full diff
      iteration_delta.patch      # what changed from iteration 01
    03/
      combined.patch
      iteration_delta.patch      # what changed from best candidate
```

### Review Template Changes

Add `{iteration_delta}` template variable to all review templates. Templates already have `{diff}` for the full patch.

For `review-template.md` (Claude):
- Pass `iteration_delta` alongside `contract_json`, `diff`, `mechanic_report`
- If delta is empty or absent, reviewer falls back to full-diff-only behavior

For `review-template-security.md` and `review-template-performance.md` (Codex/Gemini):
- Add delta to the prompt with the "FOCUS on delta" instruction
- External CLIs get both in a single prompt

### Impact on Convergence

Expected improvements:
- **Fewer false re-discoveries** — reviewer won't flag the same line 42 issue on iteration 5 if it wasn't changed
- **Faster token processing** — delta is typically 10-50 lines vs 200-500 full patch
- **More targeted findings** — findings directly related to the fix, not the whole feature
- **Better fix quality signal** — clear whether the fix actually addressed the previous finding

### Edge Cases

1. **Rollback changes the base** — delta is always computed from the ACTIVE best candidate, not the previous iteration. If rollback happened, delta reflects "what's different from the best candidate."
2. **First iteration** — no delta, full diff only. Business as usual.
3. **Engineer creates entirely new files** — `git diff` only shows unstaged changes to tracked files. To ensure new files appear in the delta, the orchestrator runs `git add -A` before computing diffs. This already happens in the current flow.
4. **Delta is empty** — engineer made no changes (repair failed or no-op). This triggers the existing "REPAIR_SKIP" path (see Artifact Lifecycle post-repair guard above).
5. **Delta unexpectedly large** — if delta size exceeds 80% of full patch size, fall back to full-diff-only review for that iteration (delta is not providing meaningful focus).

**Explicit diff commands:**
- `git diff` (unstaged) — captures the iteration delta (what engineer changed from best candidate)
- `git diff $BASE` — captures combined.patch (full feature diff from base commit)

## Files to Modify

| File | Change |
|------|--------|
| `commands/signum.md` | Delta capture after repair (orchestrator), stale clear before repair, cleanup lists (restart + archive) |
| `agents/reviewer-claude.md` | Add delta-aware review instructions |
| `lib/prompts/review-template.md` | Add `{iteration_delta}` variable and focus instructions |
| `lib/prompts/review-template-security.md` | Same |
| `lib/prompts/review-template-performance.md` | Same |
| `agents/synthesizer.md` | No changes needed (reads findings, not diffs) |
| `platforms/claude-code/` | Mirror sync after implementation in commands/signum.md |

Note: `agents/engineer.md` requires no changes — the orchestrator owns delta generation, not the engineer.

## What Does NOT Change

- Scoring formula
- Best-of-N logic
- Rollback mechanism
- Proofpack assembly (embeds full combined.patch, not delta)
- Holdout validation (tests behavior, not diff)
- Mechanic (runs checks, not diff-dependent)
