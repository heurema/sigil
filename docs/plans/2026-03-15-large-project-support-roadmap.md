# Signum: Large-Project Support Roadmap

Date: 2026-03-15
Status: planning
Source: `/delve` research + 3 Codex sub-reports

> **2026-04-10 maintenance update**
>
> This roadmap originally captured missing capabilities. Phases 1-5 below are now **shipped in core Signum** and should no longer be read as "not started". Root `commands/signum.md` is the canonical source of pipeline behavior. This roadmap now tracks remaining follow-up work, remaining gaps, and unresolved architecture questions.

## Context

Research across 7 production SDD systems, 15+ papers, and internal Signum analysis
identified gaps preventing Signum from scaling to large multi-contract projects.
Current Signum excels at task-local contract quality but lacks project-wide coherence.

Full research: `docs/research/2026-03-15-contract-hierarchy-clarification-architecture-2026.md`
Supporting Codex reports: `docs/research/2026-03-15-signum-*.md`, `docs/research/2026-03-15-codex-*.md`

---

## MVP Phases

### Phase 1: Project Intent Layer
- **Effort:** LOW
- **Leverage:** HIGH
- **Status:** shipped in core

Tasks:
- [x] Define `project.intent.md` template (goal, non-goals, glossary, success criteria, personas)
- [x] Add `contextInheritance` block to contract schema v3.3+:
  - `projectRef: string` — path to project.intent.md
- [x] Update contractor agent to load `project.intent.md` before generating contract
- [x] Add `intent_diff_check` as WARN-level sub-check in spec quality gate
  - Compares contract goal against project intent, surfaces divergence
- [x] Document the new field in README / reference.md

Resolved:
- `project.intent.md` lives at repo root
- contractor loads it automatically when present

Remaining follow-up:
- Add harness-doc bootstrap beyond `project.intent.md` / `project.glossary.json`

### Phase 2: Glossary Enforcement
- **Effort:** MEDIUM
- **Leverage:** HIGH
- **Status:** shipped in core

Tasks:
- [x] Add glossary section to `project.intent.md` OR standalone `project.glossary.json`
  - Canonical terms + alias table (forbidden synonyms)
- [x] Add `glossaryVersion` field to contract schema
- [x] Implement `glossary_check` in spec quality gate:
  - Lexical match for forbidden synonyms in goal/inScope/ACs
  - WARN on undefined critical domain terms
- [x] Implement `terminology_consistency_check`:
  - Across active contracts in `.signum/contracts/index.json`
  - WARN on synonym proliferation

Resolved:
- standalone `project.glossary.json`
- WARN-only enforcement in core

Remaining follow-up:
- Decide whether bounded-context glossaries are needed later

### Phase 3: Cross-Contract Coherence
- **Effort:** MEDIUM
- **Leverage:** HIGH
- **Status:** shipped in core

Tasks:
- [x] Implement `cross_contract_overlap_check`:
  - Compare new contract inScope against active contracts
  - WARN on overlapping scope
- [x] Implement `assumption_contradiction_check`:
  - Compare assumptions[] across related contracts
  - WARN on conflicting assumptions
- [x] Implement `adr_relevance_check`:
  - Match touched paths against ADR file globs
  - WARN if adrRefs is empty but relevant ADRs exist
- [x] Extend contract schema with dependency semantics:
  - `dependsOnContractIds: string[]` — ordering dependency
  - `supersedesContractIds: string[]` — obsolescence tracking
  - `supersededByContractId: string` — reverse pointer
  - `interfacesTouched: string[]` — named interfaces this contract modifies
- [x] Enhance `.signum/contracts/index.json` for graph queries

Resolved:
- file/path-based ADR relevance is sufficient for core
- dependency semantics are user-declared, not inferred

Remaining follow-up:
- improve graph queries and cross-contract UX

### Phase 4: Upstream Staleness Detection
- **Effort:** HIGH
- **Leverage:** HIGH
- **Status:** shipped in core

Tasks:
- [x] Add `contextSnapshotHash` to contract schema:
  - SHA-256 hash over all inherited upstream artifacts at creation time
- [x] Add `staleIfChanged: string[]`:
  - Upstream artifact refs that trigger staleness when modified
- [x] Add `stalenessStatus: "fresh" | "warning" | "stale"`
- [x] Implement `upstream_staleness_check`:
  - Recompute hash, compare against stored contextSnapshotHash
  - BLOCK if stale (configurable: BLOCK vs WARN)
- [x] Contractor sets these fields automatically from contextInheritance refs

Resolved:
- byte-level hashing is the current core mechanism
- `warn` is the default policy; `block` is supported

Remaining follow-up:
- cascading staleness and semantic invalidation remain open

### Phase 5: Within-Task Refinement Loop
- **Effort:** MEDIUM
- **Leverage:** MEDIUM
- **Status:** shipped in core

Tasks:
- [x] Implement explicit multi-pass critique in CONTRACT stage:
  - Pass 1: `ambiguity review` — structural + LLM-based
  - Pass 2: `missing-input review` — required context gaps
  - Pass 3: `contradiction review` — internal consistency
  - Pass 4: `goal reconstruction / coverage review` — Clover extension
- [x] Typed findings (not freeform commentary):
  - `ambiguityCandidates: [{text, location, severity}]`
  - `contradictionsFound: [{claim_a, claim_b, type}]`
  - `clarificationDecisions: [{question, decision, rationale}]`
  - `assumptionProvenance: [{id, text, source, confidence}]`
- [x] Cap auto-revision at 1-2 rounds, then escalate to user
- [x] Add `readinessForPlanning` computed field (go/no-go summary)

Resolved:
- critique runs inline in contractor for medium/high risk

Remaining follow-up:
- tune latency and over-critique thresholds from real runs

---

## Current P0 Documentation / Parity Debt

- [ ] Add explicit doc/parity checks so roadmap/docs cannot silently drift from root `commands/signum.md`
- [ ] Resolve the `RECONCILE` root-vs-overlay divergence (`platforms/claude-code/commands/signum.md` has it; root `commands/signum.md` does not)
- [ ] Decide which docs should be generated/derived instead of maintained manually
- [ ] Add harness-doc bootstrap beyond `project.intent.md` / `project.glossary.json`

## Beyond MVP

### B1: ADR Integration (MEDIUM effort, HIGH impact)
- [ ] Add `docs/adr/` convention to Signum projects
- [ ] Add `contextInheritance.adrRefs: string[]` to contract schema
- [ ] Contractor retrieves ADRs matching touched paths before generating contract
- [ ] Optional: Archgate-style `.rules.ts` companion files for executable enforcement

### B2: Initiative Layer (MEDIUM effort, MEDIUM impact)
- [ ] Add `docs/initiatives/INIT-NNN.md` template
- [ ] Add `contextInheritance.initiativeRef` to contract schema
- [ ] Initiative template: scope, contracts list, dependencies, timeline, status
- [ ] Heuristic: create initiative when 3+ contracts expected

### B3: Project Constitution (LOW effort, MEDIUM impact)
- [ ] Add `project.constitution.md` — stable engineering rules, preferences
- [ ] Separate from `project.intent.md` (intent changes, constitution is stable)
- [ ] Add `contextInheritance.constitutionRef` to contract schema

### B4: Asymmetric Context in Review (LOW effort, HIGH impact)
- [ ] Reviewer agents don't see draft history or prior revision attempts
- [ ] Each review evaluates the artifact independently
- [ ] Prevents spontaneous reward hacking (arXiv 2407.04549)

### B5: Kiro-style fileMatch Inclusion (LOW effort, MEDIUM impact)
- [ ] Domain-specific context loaded only when contract touches matching file patterns
- [ ] Reduces noise for unrelated work
- [ ] Implement via trigger tables in constitution or project.intent.md

### B6: Cross-Run Prompt Optimization (HIGH effort, MEDIUM impact)
- [ ] After 20+ completed contracts: DSPy MIPROv2 batch optimization
- [ ] Mutable: contractor prompt, spec-review prompt, rubric weights
- [ ] Frozen: spec quality gate, contradiction checks, goal reconstruction score
- [ ] Teacher/student model split for cost efficiency

### B7: Frozen Evaluator Design (HIGH effort, HIGH impact)
- [ ] GEPA-style: train LM-as-judge on human-labeled contract examples
- [ ] Freeze before optimization loop
- [ ] Stratified evaluation across contract complexity tiers
- [ ] Quarterly human audit of 10 random evaluator judgments
- [ ] Different model family from contractor to prevent shared blind spots

---

## Execution Protocol

For each phase:
1. **Assess readiness** — are design questions resolved? If not → research first
2. **Write detailed plan** — files to create/modify, schema changes, acceptance criteria
3. **Build via Signum** — `/signum` with the plan as feature request
4. **Review** — code review + test the new checks on real contracts
5. **Ship** — bump version, update CHANGELOG

---

## Key Research Sources

- `docs/research/2026-03-15-contract-hierarchy-clarification-architecture-2026.md` — main synthesis
- `docs/research/2026-03-15-signum-project-intent-contract-architecture-codex.md` — Codex: architecture
- `docs/research/2026-03-15-signum-context-inheritance-codex.md` — Codex: inheritance model
- `docs/research/2026-03-15-signum-codex-semantic-drift-across-contracts.md` — Codex: semantic drift
- `docs/research/2026-03-15-codex-contract-clarification-self-improvement-loops.md` — Codex: self-improvement
