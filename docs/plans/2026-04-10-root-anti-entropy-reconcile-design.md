---
title: "Root Anti-Entropy / RECONCILE Design"
date: 2026-04-10
status: draft
owner: "@vi"
---

# Root Anti-Entropy / RECONCILE Design

## Decision Summary

Do **not** promote the current Claude-only `Phase 5: RECONCILE` into root `commands/signum.md` as-is.

Instead:

1. Keep the root canonical pipeline at:
   - `CONTRACT -> EXECUTE -> AUDIT -> PACK`
2. Treat current overlay `RECONCILE` as an **experimental overlay-only behavior**.
3. Design the root follow-up as a separate **anti-entropy workflow**, not as a post-PACK mutation phase.
4. Any post-proofpack repo mutation should happen only via:
   - an explicit follow-up contract, or
   - a future dedicated `/signum reconcile` command/mode
   - never as a silent side effect after `AUTO_OK`.

This preserves proofpack immutability and avoids hidden repo edits after the audited diff is already considered complete.

---

## Why the Current Overlay RECONCILE Is Not Safe Enough to Promote

Current `platforms/claude-code/commands/signum.md` `Phase 5: RECONCILE`:
- runs after `AUTO_OK`
- may update docs / roadmap / manifests
- may remove code
- mutates canonical `contract.json` metadata after audit (under the active contract artifact root, with a root compatibility view during the migration)

This is too broad for canonical promotion because it blurs three different concerns:

1. **Task correctness**
   - already handled by `EXECUTE` + `AUDIT`
2. **Repo hygiene / anti-entropy**
   - docs sync, module lifecycle cleanup, stale references
3. **Project-state maintenance**
   - roadmap status, manifests, follow-up debt, metric/risk ratchets

If these run after proofpack creation as implicit side effects, then:
- the audited artifact no longer cleanly matches the final repo state
- “what exactly was reviewed?” becomes ambiguous
- PACK stops being the stable end of the canonical chain
- docs-only chores and real code mutations get mixed together

For root Signum, that tradeoff is not worth it.

---

## Problem to Solve

Signum already has the raw pieces of anti-entropy:
- `modules.yaml`
- `removals`
- `cleanupObligations`
- `proofpack` history
- `metric-ratchet.sh`
- doc parity checks
- roadmap / plan drift controls

What it does **not** have in root is a coherent answer to:

- what happens **after** a successful contract when repo hygiene still needs work?
- which obligations are part of the same proof-bearing task vs which should become follow-up work?
- how to keep docs/manifests/metrics in sync without post-hoc silent edits?

---

## Design Goals

- Preserve root pipeline immutability after PACK
- Make anti-entropy explicit, inspectable, and bounded
- Separate:
  - blocking task obligations
  - non-blocking maintenance recommendations
  - project-state bookkeeping
- Reuse existing primitives instead of inventing a second orchestration system
- Keep downstream behavior testable and deterministic where possible

## Non-Goals

- Do not make root Signum auto-edit roadmap/docs/manifests after `AUTO_OK`
- Do not add another always-on LLM-heavy phase to every task
- Do not redefine proofpack as a mutable artifact
- Do not merge anti-entropy with release orchestration or observability

---

## Proposed Root Model

### 1. Core rule: PACK stays terminal for canonical task execution

`proofpack.json` remains the terminal artifact for the specific contract that was implemented and audited.

Root Signum should not mutate project state after that point in a way that changes the meaning of the audited diff.

### 2. Split obligations into two classes

#### A. In-contract obligations
These belong inside the same task and must be handled before `AUTO_OK`.

Examples:
- remove all imports of deleted module
- ensure removed path stays absent
- update `modules.yaml` lifecycle status when the task explicitly removes a module

These already fit `cleanupObligations` and `removals`.

Rule:
- if it affects the correctness/completeness of the task’s claimed outcome, it stays inside the main contract
- if unfulfilled, it should block `AUTO_OK`

#### B. Post-contract anti-entropy findings
These are follow-up recommendations, not part of the audited implementation claim.

Examples:
- roadmap status should be updated
- docs mention outdated module name
- metrics trend degraded and needs separate investigation
- old deprecated module passed deadline but was out of scope for the current task

Rule:
- these become **follow-up items**, not silent edits

### 3. Add a separate anti-entropy report layer

After or alongside PACK, root Signum can generate a **report artifact** only:

- `anti_entropy_report.json` under the active contract artifact root (`.signum/contracts/<contractId>/anti_entropy_report.json`)

This artifact is advisory and does not mutate the repo.

Suggested contents:

```json
{
  "status": "ok|warn",
  "sources": [
    "cleanupObligations",
    "modules.yaml",
    "doc_parity",
    "metric_ratchet"
  ],
  "findings": [
    {
      "id": "AE01",
      "category": "docs_sync",
      "severity": "medium",
      "target": "docs/plans/2026-03-15-large-project-support-roadmap.md",
      "summary": "Roadmap status likely stale after shipped feature",
      "recommendedAction": "follow_up_contract"
    }
  ]
}
```

### 4. For actual repo mutation, require an explicit second step

If anti-entropy findings require changes, root Signum should create either:

- a suggested follow-up contract draft, or
- a dedicated `/signum reconcile` workflow later

But this must be explicit and user-visible.

The clean rule:

> **No new repo mutations after PACK unless they happen in a new, separately scoped unit of work.**

---

## Source Mapping for Anti-Entropy Findings

| Source | What it can produce | Mutation in same run? |
| --- | --- | --- |
| `cleanupObligations` | blocking task-level cleanup | yes, before `AUTO_OK` |
| `removals` | deletion evidence and no-reference checks | yes, before `AUTO_OK` |
| `modules.yaml` | deprecated/removed lifecycle drift | report by default |
| `lib/doc-parity-check.sh` | canonical-vs-derived drift | report by default |
| `lib/metric-ratchet.sh` | trend regressions / ratchet drift | report by default |
| roadmap / plans docs | status drift or stale planning debt | report by default |

This gives a principled split:
- **task truth** stays in the main pipeline
- **repo hygiene** becomes anti-entropy reporting

---

## Proposed Rollout

### Stage 1 — Report only

Add a deterministic anti-entropy report generator that:
- reads canonical `contract.json`, `proofpack.json`, `modules.yaml`
- optionally consumes doc parity output and metric-ratchet output
- emits `anti_entropy_report.json` under the active contract artifact root
- never edits repo files

This is the safest first canonical step.

### Stage 2 — Follow-up contract generation

If the report contains actionable items, offer:
- “generate follow-up maintenance contract”

That contract can cover:
- docs sync
- module lifecycle cleanup
- roadmap / manifest maintenance

Now every mutation still flows through normal Signum guarantees.

### Stage 3 — Optional dedicated reconcile command

Only after Stage 1-2 prove useful:
- consider `/signum reconcile`
- explicit command, explicit scope, explicit artifacts
- still not an implicit Phase 5 in the canonical root pipeline

---

## Why This Is Better Than Root Phase 5

### Keeps proofpack semantics clean
The proofpack continues to describe exactly the work that was implemented and audited.

### Avoids silent post-audit edits
No hidden docs/config cleanup sneaks in after the task is already considered done.

### Reuses the main contract system
If anti-entropy needs changes, those changes can be made through another contract instead of bespoke logic.

### Lets overlays experiment safely
Claude overlay can keep its current `RECONCILE` behavior while root Signum converges on a safer canonical model.

---

## Acceptance Criteria for the Future Implementation

### Stage 1 implementation should:
- leave root pipeline phases unchanged
- emit a structured anti-entropy report artifact only
- make zero repo mutations
- be testable with shell fixtures

### Stage 2 implementation should:
- turn anti-entropy findings into a suggested contract or explicit prompt
- preserve user approval before any new repo mutation
- avoid duplicating contractor logic for scope / AC / risk

---

## Open Questions

1. Should `anti_entropy_report.json` be part of proofpack or a sibling artifact?
   - current leaning: sibling artifact, to keep proofpack scoped to the task itself

2. Should doc parity findings be imported automatically, or should anti-entropy read only precomputed outputs?
   - current leaning: consume existing outputs when present; avoid re-running everything implicitly

3. Should `modules.yaml` deadline violations become warnings in normal CONTRACT or only anti-entropy findings?
   - current leaning: warning in CONTRACT, richer follow-up recommendation in anti-entropy

4. Is a root `/signum reconcile` command worth adding, or is “generate follow-up contract” enough?
   - current leaning: follow-up contract first, dedicated command later only if repeated friction appears

---

## Immediate Next Step

Implement **Stage 1 only**:
- report-only anti-entropy artifact
- no root Phase 5
- no post-PACK repo mutation

That is the safest path from current overlay experimentation to canonical root behavior.
