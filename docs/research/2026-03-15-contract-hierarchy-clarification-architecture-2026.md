---
title: "Project-Wide Intent, Contract Hierarchy, and Clarification Architecture for Contract-First AI Development"
date: 2026-03-15
run_id: 20260315T112939Z-72620
depth: medium
verification_status: unverified
completion_status: complete
sources_count: 40+
agents: 4
---

# Project-Wide Intent, Contract Hierarchy, and Clarification Architecture

## 1. Executive Summary

This research synthesizes findings from 40+ sources across 7 production spec-driven development (SDD) systems, 15+ academic papers, and internal Signum analysis to answer how large AI-assisted projects should structure artifacts, inherit context, and maintain coherence across many contracts.

**Key conclusions:**

1. **Every system uses at minimum a two-layer hierarchy** (project-level + task-level). Large projects need a three-to-four layer stack: project intent/constitution → ADRs → initiative/epic → task contract.
2. **Clarification should remain inside CONTRACT** as a substage, not become a separate artifact. But clarification output must be structured (not prose) and machine-checkable.
3. **Context inheritance must be reference-by-ID, not copy-into-contract.** Copy-into-context causes explosion in multi-agent hierarchies.
4. **Cross-contract coherence requires four mechanisms**: shared glossary, lineage tracking, contradiction detection, and upstream-change invalidation.
5. **Self-improvement should optimize contractor/reviewer prompts against a frozen evaluator** using DSPy MIPROv2 or OPRO, with asymmetric context to prevent reward hacking.

---

## 2. What Sources Say

### 2.1 Artifact Hierarchy Across Systems

Every surveyed system separates persistent project-wide context from per-task specifications. No system collapses them into one artifact.

**Kiro (AWS):** Two layers. Steering files (`.kiro/steering/product.md`, `tech.md`, `structure.md`) loaded via configurable inclusion modes (always/fileMatch/manual/auto). Per-feature specs in `.kiro/specs/<feature>/` with three files: `requirements.md` (EARS notation), `design.md`, `tasks.md`.

**GitHub Spec-Kit:** Three layers. Constitution (`.specify/memory/constitution.md` — nine numbered Articles as immutable rules). Templates. Per-feature specs in `.specify/specs/NNN-feature-name/` with 8+ files including spec.md (FR-XXX/SC-XXX identifiers), plan.md (Phase -1: Pre-Implementation Gates), tasks.md (parallel-safe [P] markers), research.md, data-model.md.

**Google Conductor:** Three layers with first-class initiative layer. Project context (`conductor/product.md`, `tech-stack.md`, `workflow.md`, `code_styleguides/`). Per-track directories (`conductor/tracks/<shortname_YYYYMMDD>/`) with spec.md, plan.md, metadata.json (track_id, type, status, timestamps), index.md. `workflow.md` establishes plan.md as source of truth.

**Tessl:** Two layers. Project config (tessl.json, AGENTS.md, KNOWLEDGE.md, tiles). Per-module specs as `.spec.md` files with YAML frontmatter (name, description, targets[]) and [@test] inline links. Only system targeting spec-as-source (code marked `// GENERATED FROM SPEC - DO NOT EDIT`).

**Archgate:** One-and-a-half layers. ADRs as executable governance (`.archgate/adrs/ARCH-NNN-slug.md` + companion `.rules.ts`). No task-level spec — integrates with other tools via MCP.

**Codified Context (arXiv 2602.20478):** Three tiers. Constitution (~660 lines, hot, always loaded) with trigger tables routing tasks to agents. 19 specialized agents (~9,300 lines, domain experts). 34 knowledge base documents (~16,250 lines, cold, on-demand via MCP).

**Signum (current):** Two layers. `repo-contract.json` (global invariants). `contract.json` per task (most machine-executable format: typed DSL verification, holdout scenarios, lineage via parentContractId/relatedContractIds).

### 2.2 Clarification Architecture

Clarification placement varies across three patterns:

| Pattern | Systems | Where clarification happens | Output format |
|---------|---------|----------------------------|---------------|
| Pre-spec conversation | Kiro, Tessl | Before spec generation via chat | Prose (no residue) |
| Embedded in spec | Spec-Kit, Conductor | During spec creation, inline markers | `[NEEDS CLARIFICATION]` markers |
| Post-spec gate | Signum | After contract generation | Structured JSON (`openQuestions[]`, `requiredInputsProvided`) |

**Key research findings:**
- AMBIG-SWE (ICLR 2026): Interactive clarification boosts agent performance up to 74% over non-interactive. LLMs rarely self-initiate clarification without explicit prompting.
- SAGE-Agent: EVPI-based question selection achieves 7-39% higher coverage while reducing questions 1.5-2.7x.
- AgentAsk: Four error types trigger clarification — Data Gap, Signal Corruption, Referential Drift, Capability Gap. Structured JSON output: binary ask gate + addressee + schema-constrained question.
- LLMs cannot reliably detect ambiguity without structured forcing — every production system compensates by hard-coding a clarification phase.

**Gate taxonomy:**
- **Hard blocking**: Signum (openQuestions + spec quality score 0-115), Spec-Kit (constitution checkboxes)
- **Human approval**: Kiro, Tessl, Conductor (manual approval, no automated scoring)
- **Score-based**: Signum only production system with quantified multi-dimensional readiness gate

### 2.3 Context Inheritance

The dominant pattern across systems is **reference-by-ID, not copy-into-context:**

- Google ADK handle pattern: agents see lightweight references (name + summary), load full content on demand via LoadArtifactsTool, offload after task completion
- Kiro `#[[file:<path>]]` live references to workspace files
- Codified Context hot/cold separation via MCP retrieval
- Manus URL-preserving compression

**Critical failure mode: context explosion.** If each agent passes full context to sub-agents recursively, token count grows geometrically. Google ADK addresses with `include_contents` scoping (none = prompt only) and narrative casting.

**Brevity bias** (Codified Context): naive context optimization collapses prompts toward generic instructions, losing project-specific knowledge. Counter-measure: intentional overlap — redundantly embed important domain facts across tiers.

**Upstream-change invalidation** is the least solved problem. Proposed model (from Signum research):
- `contextSnapshotHash`: hash of all inherited artifacts at contract creation
- `staleIfChanged`: refs that trigger staleness when modified
- `stalenessStatus`: fresh | warning | stale

### 2.4 Cross-Contract Coherence

**Glossary/terminology drift:** A shared domain glossary is the highest-leverage intervention. No mature open-source tool exists for automated glossary extraction + drift detection. MVP: canonical term list → alias table → contract-time lexical linter.

**Contradiction detection:**
- Clover: consistency checking across three artifacts (code, docstrings, formal annotations) as proxy for correctness. 87% acceptance for correct code, 0 false positives.
- ALICE: formal logic + LLM for requirements contradiction detection.
- 3B RL-trained LLM: domain-specific contradiction detection in 5G specs.

**Lineage tracking:** Current Signum uses file-overlap heuristic. Recommended extensions: `dependsOnContractIds`, `supersedesContractIds`, `interfacesTouched`, `glossaryVersion`.

### 2.5 Self-Improvement Patterns

| Pattern | Scope | Applicability | Key Requirement |
|---------|-------|---------------|-----------------|
| Self-Refine | Within-task | Draft → critique → revise loop | Same-model critique; weak for substantive errors |
| Reflexion | Within-task | Memory-augmented multi-attempt | Episodic memory buffer |
| CRITIC | Within-task | External tool verification | External tools (DB, schema parser, tests) |
| DSPy Assertions | Within-task + compile | Structural enforcement | Declarative constraints (Assert/Suggest) |
| MIPROv2 | Cross-run | Rubric + instruction optimization | Labeled corpus; frozen metric |
| OPRO | Cross-run | Rubric improvement from batches | Historical prompt + score pairs |
| TextGrad | Cross-run | Joint prompt/rubric optimization | LLM evaluator; no labels needed |
| STaR | Cross-run | Bootstrap from validated reviews | Human-validated corpus |

**Critical finding:** LLMs cannot reliably self-correct through intrinsic prompting (Huang et al. 2023). All working patterns use external tools, human-labeled examples, or a separately frozen evaluator.

**Reward hacking risk:** When the same model drafts and judges contracts, scores inflate without quality improvement (arXiv 2407.04549). Mitigations: asymmetric context (judge never sees draft history), model separation (different model for evaluation), stratified evaluation sets.

**Frozen evaluator design:** DSPy's GEPA pattern — train LM-as-judge on human-labeled examples (98% alignment), freeze before optimization. Metric function is immutable during compilation.

---

## 3. Comparison Table

| System | Project Layer | Initiative Layer | Task Layer | Clarification | Gates | Executable Verification | ADR Integration |
|--------|---------------|------------------|------------|---------------|-------|------------------------|-----------------|
| **Kiro** | steering/ (product, tech, structure) | — | .kiro/specs/<feature>/ (req, design, tasks) | Pre-spec chat | Human review | — | — |
| **Spec-Kit** | constitution.md (9 Articles) | .specify/specs/NNN-name/ | spec.md + plan.md + tasks.md | [NEEDS CLARIFICATION] markers, /speckit.clarify | Constitution checkboxes (hard) | — | — |
| **Conductor** | product.md, tech-stack.md, workflow.md | conductor/tracks/<name_date>/ | spec.md + plan.md + metadata.json | AI-suggested answers, human approval | Human approval + post-impl review | — | — |
| **Tessl** | AGENTS.md, tiles, KNOWLEDGE.md | — | <module>.spec.md (targets[], [@test]) | One-question-at-a-time interview | Human approval | @generate, @test tags | — |
| **Archgate** | .archgate/adrs/ (ARCH-NNN + .rules.ts) | — | — (integrates with other tools) | — | CI rules + MCP agent context | TypeScript rule checks | Primary artifact |
| **Codified Context** | Constitution (~660 lines, hot) | Agents (19 domain experts) | Knowledge Base (34 docs, cold via MCP) | — | Trigger table routing | — | — |
| **Signum** | repo-contract.json | — (proposed: initiatives/) | contract.json (typed DSL verify) | openQuestions[] hard stop + 7-dim quality gate | Hard blocking (score + open questions) | http/exec/expect DSL + holdouts | — (proposed: adrRefs) |

---

## 4. Recommended Architecture

### 4.1 Artifact Hierarchy (Target)

```
Layer 0: Project Intent
├── project.intent.md          — goal, personas, non-goals, success criteria, glossary
├── project.constitution.md    — immutable engineering rules, preferences
│
Layer 1: Governance
├── docs/adr/                  — Architecture Decision Records
│   ├── ADR-NNN-slug.md
│   └── ADR-NNN-slug.rules.ts  (optional, Archgate-style)
├── repo-contract.json         — executable repo-wide invariants
│
Layer 2: Initiative / Epic
├── docs/initiatives/
│   ├── INIT-001-name.md       — decomposition, scope, dependencies, timeline
│   └── INIT-002-name.md
│
Layer 3: Task Contract
├── .signum/contracts/<contractId>/contract.json      — narrow executable slice
├── .signum/contracts/<contractId>/contract-engineer.json  (derived, holdouts removed)
├── .signum/contracts/<contractId>/contract-policy.json    (derived, tool constraints)
│
Layer 4: Audit
└── .signum/contracts/<contractId>/proofpack.json     — tamper-evident execution record
```

### 4.2 Contract Inheritance Model

Task contracts inherit project context via **reference + small explicit snapshot**, not full embedding:

```json
{
  "schemaVersion": "3.3",
  "contractId": "sig-20260315-a7f2",
  "goal": "...",

  "contextInheritance": {
    "projectRef": "project.intent.md",
    "constitutionRef": "project.constitution.md",
    "initiativeRef": "docs/initiatives/INIT-001-auth-refactor.md",
    "adrRefs": ["ADR-003-api-routes", "ADR-007-auth-tokens"],
    "glossaryVersion": "v2.1",
    "dependsOnContractIds": ["sig-20260314-b3c1"],
    "interfacesTouched": ["AuthService.verify()", "UserModel.permissions"],
    "contextSnapshotHash": "sha256:abc123...",
    "staleIfChanged": ["project.intent.md", "ADR-007-auth-tokens"],
    "stalenessStatus": "fresh"
  },

  "inScope": [...],
  "acceptanceCriteria": [...],
  "assumptions": [...],
  "openQuestions": []
}
```

**Loading strategy:**
- `projectRef`, `constitutionRef` → always loaded (hot)
- `adrRefs` → loaded when contract touches matching file patterns (warm)
- `initiativeRef` → loaded when creating/reviewing the contract (warm)
- Prior contracts in `dependsOnContractIds` → loaded on-demand for consistency checks (cold)

### 4.3 Clarification Architecture

**Recommendation:** Clarification remains a substage inside CONTRACT, not a separate artifact.

**Rationale:**
1. All production systems embed clarification in the spec creation flow, not as a standalone phase.
2. A separate "clarified brief" artifact creates a second source of truth that can drift from the contract.
3. The contract itself (with `openQuestions`, `assumptions`, and quality gate scores) already captures clarification output in machine-readable form.

**Enhancements to current Signum clarification:**

1. **Structured assumption types**: Instead of free text, use `{"id": "A1", "text": "...", "confidence": "high|medium|low", "derivedFrom": "pyproject.toml"}` — this makes assumptions auditable.
2. **Readiness gate enrichment**: Add EVPI-style priority to open questions — which question, if answered, would most reduce implementation uncertainty.
3. **User-facing clarification view**: A derived (not canonical) rendered summary of the draft contract showing: goal, non-goals, key assumptions, open questions, and readiness score. This is a view over contract.json, not a second artifact.
4. **Ask-vs-assume policy**: BLOCK when the contractor cannot make a reasonable inference from the codebase. ASSUME AND LOG when codebase evidence supports a default. Never silently assume.

### 4.4 Cross-Contract Coherence Checks

New checks to add to the Signum pipeline:

| Check | Type | Trigger |
|-------|------|---------|
| `glossary_check` | WARN/BLOCK | New non-glossary terms in goal/inScope/ACs |
| `cross_contract_overlap_check` | WARN | Active contracts with overlapping inScope |
| `adr_relevance_check` | WARN | Touched paths match ADR file globs but adrRefs is empty |
| `intent_diff_check` | WARN | Contract goal diverges from project.intent.md |
| `upstream_staleness_check` | BLOCK | contextSnapshotHash mismatch (upstream changed since draft) |
| `assumption_contradiction_check` | WARN | Assumptions contradict assumptions in related contracts |
| `terminology_consistency_check` | WARN | Synonym detection across active contracts |

### 4.5 Lineage and Traceability

Full chain: `project.intent.md → INIT-NNN.md → contract.json → combined.patch → proofpack.json`

Each link has a dedicated artifact. Add to `proofpack.json`:
- `initiativeRef` — which initiative this contract implements
- `adrRefsResolved` — which ADRs were loaded during CONTRACT
- `glossaryVersionUsed` — glossary state at contract time
- `contextSnapshotHash` — immutable hash for reproducibility

### 4.6 Readiness Gate

Before planning/execution begins, the contract must pass:

1. **Open questions resolved**: `openQuestions = [] AND requiredInputsProvided = true`
2. **Spec quality score ≥ 70/115**: existing 7-dimension gate
3. **Context freshness**: `stalenessStatus != "stale"`
4. **Glossary compliance**: no undefined critical domain terms
5. **ADR compliance**: no unlinked ADR matches for touched paths

### 4.7 Glossary, Non-Goals, ADRs, Invariants, Initiative Context

| Artifact | Location | Responsibility |
|----------|----------|----------------|
| Glossary | `project.intent.md` section or `project.glossary.json` | Canonical domain terms + aliases + forbidden synonyms |
| Non-goals | `project.intent.md` section + `contract.json.outOfScope` | Project-wide non-goals in intent, task-specific in contract |
| ADR links | `docs/adr/` + `contract.json.contextInheritance.adrRefs` | Decisions stored as ADRs, referenced by contract |
| Global invariants | `repo-contract.json` | Executable repo-wide checks |
| Initiative context | `docs/initiatives/INIT-NNN.md` + `contract.json.contextInheritance.initiativeRef` | Decomposition and scope, referenced by contract |

---

## 5. MVP Proposal

**Minimal viable additions to current Signum for large-project support:**

### Phase 1: Project Intent Layer (LOW effort)
1. Add `project.intent.md` template (goal, non-goals, glossary, success criteria)
2. Add `contextInheritance.projectRef` field to contract schema v3.3
3. Contractor loads `project.intent.md` before generating contract
4. Add `intent_diff_check` as a WARN-level quality sub-check

### Phase 2: Glossary Enforcement (MEDIUM effort)
1. Add glossary section to `project.intent.md` or standalone `project.glossary.json`
2. Add `glossaryVersion` field to contract schema
3. Add `glossary_check` — lexical match for forbidden synonyms in goal/ACs
4. Add `terminology_consistency_check` across active contracts

### Phase 3: Initiative Layer (MEDIUM effort)
1. Add `docs/initiatives/INIT-NNN.md` template
2. Add `contextInheritance.initiativeRef` field
3. Add `cross_contract_overlap_check` comparing active contracts

### Phase 4: Upstream Invalidation (HIGH effort)
1. Add `contextSnapshotHash` computed at contract creation
2. Add `staleIfChanged` refs
3. Add `upstream_staleness_check` as BLOCK-level gate
4. Add staleness detection when upstream artifacts change

### Phase 5: ADR Integration (MEDIUM effort)
1. Add `docs/adr/` convention
2. Add `contextInheritance.adrRefs` field
3. Contractor scans ADRs matching touched paths before generating contract
4. Optional: Archgate-style `.rules.ts` companion files

---

## 6. Risks / Failure Modes

| Failure Mode | What Happens | Prevention |
|---|---|---|
| **Local correctness, global drift** | Task contracts pass individually but diverge from project intent | `intent_diff_check`, `cross_contract_overlap_check` |
| **Terminology drift** | Same concept named differently across contracts | Shared glossary + `glossary_check` + `terminology_consistency_check` |
| **Stale context** | Contract built against outdated project intent or ADRs | `contextSnapshotHash` + `upstream_staleness_check` |
| **Context explosion** | Embedding full project context into every contract | Reference-by-ID + hot/cold loading strategy |
| **Brevity bias** | Over-optimization collapses project-specific knowledge | Intentional overlap in hot context + domain-specific agent priming |
| **Constitution ignored** | Constitutional rules documented but not enforced | Executable rules (Archgate-style .rules.ts) or spec quality gate checks |
| **Reward hacking in review** | Same model drafts and judges, scores inflate | Asymmetric context, model separation, stratified evaluation |
| **Evaluator gaming** | Contractor learns to produce contracts that score high on quality gate but miss real intent | Frozen evaluator + human-validated examples + periodic metric audit |
| **Over-interrogation** | Clarification loop asks too many low-value questions | EVPI-based question prioritization, ask-vs-assume policy |
| **Initiative layer bloat** | Initiative artifacts become stale or duplicative | Lightweight templates, initiative status lifecycle, archival policy |
| **Lineage link rot** | References to archived contracts or deleted ADRs | Hash-based verification, broken-link detection |
| **Contradiction between contracts** | Two active contracts make conflicting assumptions | `assumption_contradiction_check`, explicit `dependsOnContractIds` |

---

## 7. Open Questions

1. **Glossary scope**: Should the glossary be global for the entire repo, or scoped per bounded context? DDD suggests bounded context scoping, but this adds complexity.

2. **Staleness threshold**: How aggressive should upstream-change invalidation be? Too strict → churn (every project.intent.md typo fix invalidates all contracts). Too lenient → silent drift. Proposed: advisory (WARN) for non-semantic changes, BLOCK for glossary/ADR changes.

3. **Initiative granularity**: When does a task warrant an initiative artifact? Proposed heuristic: if the task is expected to produce 3+ contracts, create an initiative.

4. **Canonical format for project intent**: Markdown (human-readable, version-controlled, easily edited) vs. JSON (machine-parseable, schema-enforced). Recommendation: Markdown for intent, JSON for glossary/invariants.

5. **Contradiction detection automation**: How much can be deterministic (lexical, structural) before LLM review is needed? Evidence suggests lexical catches 60-70% of terminology issues; semantic contradictions require LLM.

6. **ADR retrieval granularity**: Should ADRs be retrieved by file-path matching (Archgate approach) or by semantic relevance? File-path is deterministic and fast; semantic is broader but slower and noisier.

7. **Cross-run optimization cadence**: How often should contractor/reviewer prompts be re-optimized? Proposed: after every 20 completed contracts, run a DSPy MIPROv2 batch with human-validated examples.

8. **Evaluator audit cycle**: The frozen evaluator should itself be audited periodically. Who audits it? Proposed: quarterly human review of 10 random evaluator judgments.

9. **Multi-model review and evaluator independence**: Signum already uses multi-model review. Should the frozen evaluator be a different model family from the contractor? Evidence from spontaneous reward hacking research says yes.

10. **Incremental adoption**: What is the minimum viable addition that makes the biggest difference for a team starting with single-contract Signum? Likely: `project.intent.md` + `glossary_check` — these are low-effort, high-leverage.

---

## Sources

### Production Systems
- [Kiro](https://kiro.dev/) — AWS spec-driven IDE
- [GitHub Spec-Kit](https://github.com/github/spec-kit) — Open-source SDD toolkit
- [Tessl](https://tessl.io/) — Agent enablement platform
- [Google Conductor](https://github.com/gemini-cli-extensions/conductor) — Gemini CLI extension
- [Archgate](https://archgate.dev/) — Executable ADRs
- [CodeRabbit](https://www.coderabbit.ai/) — AI code review with pattern drift detection
- [SpecStory](https://specstory.com/) — Session history preservation

### Papers
- [Spec-Driven Development: From Code to Contract](https://arxiv.org/html/2602.00180v1) — SDD maturity spectrum
- [Codified Context: Infrastructure for AI Agents](https://arxiv.org/html/2602.20478v1) — Three-tier context architecture
- [Constitutional SDD: Enforcing Security by Construction](https://arxiv.org/html/2602.02584) — Constitutional principles with enforcement
- [AMBIG-SWE: Interactive Agents to Overcome Underspecificity](https://arxiv.org/abs/2502.13069) — ICLR 2026, clarification benchmarks
- [SAGE-Agent: Structured Uncertainty Guided Clarification](https://openreview.net/forum?id=dc8ebScygC) — EVPI-based question selection
- [AgentAsk: Multi-Agent Systems Need to Ask](https://arxiv.org/html/2510.07593v1) — Error taxonomy for clarification
- [Clover: Cross-Artifact Consistency Checking](https://arxiv.org/abs/2310.17807) — Consistency as correctness proxy
- [ALICE: Automated Contradiction Detection in Requirements](https://link.springer.com/article/10.1007/s10515-024-00452-x)
- [Git Context Controller](https://arxiv.org/html/2508.00031v2) — Version-controlled agent memory
- [Google ADK: Multi-Agent Context Architecture](https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/)
- [Manus: Context Engineering for AI Agents](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)
- [Self-Refine](https://arxiv.org/abs/2303.17651) — NeurIPS 2023
- [Reflexion](https://arxiv.org/abs/2303.11366) — NeurIPS 2023
- [CRITIC](https://arxiv.org/abs/2305.11738) — ICLR 2024
- [LLMs Cannot Self-Correct Reasoning](https://arxiv.org/abs/2310.01798) — Huang et al. 2023
- [Spontaneous Reward Hacking in Self-Refinement](https://arxiv.org/html/2407.04549v1)
- [OPRO: LLMs as Optimizers](https://arxiv.org/abs/2309.03409) — Google DeepMind
- [TextGrad: Automatic Differentiation via Text](https://arxiv.org/abs/2406.07496) — Nature 2024
- [STaR: Bootstrapping Reasoning](https://arxiv.org/abs/2203.14465) — NeurIPS 2022
- [DSPy Assertions](https://arxiv.org/abs/2312.13382) — Computational constraints for LM pipelines
- [Goodhart's Law in RL](https://arxiv.org/html/2310.09144v1) — ICLR 2024

### Analysis
- [Martin Fowler: Understanding SDD — Kiro, Spec-Kit, Tessl](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
- [Addy Osmani: How to Write a Good Spec for AI Agents](https://addyosmani.com/blog/good-spec/)
- [Joe Vest: Designing Work Units as Enforceable Artifacts](https://medium.com/@joe-vest/designing-work-units-29d3c8a05d74)
