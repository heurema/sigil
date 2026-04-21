# Semantic Drift Across Many Contracts in One Project

Date: 2026-03-15  
Author: Codex  
Scope: research sub-question only

## 1. Short answer

Teams do not solve semantic drift with one mechanism. The effective pattern is a stack:

1. one shared domain vocabulary (`glossary` / `ubiquitous language`);
2. persistent project intent artifacts (`specs`, `constitution`, `ADRs`);
3. explicit lineage between intent, decisions, contracts, and code;
4. automated consistency checks for contradictions, missing context, and drift;
5. retrieval of relevant architectural context before each local spec/contract is written;
6. review gates that compare local artifacts against upstream intent, not just against code.

The strongest conclusion for `Signum`: current `draft contract + openQuestions + repo-contract + approval loop` is a good base, but it is not enough for large projects. To prevent semantic drift across many contracts, `Signum` needs a project-level intent layer, a glossary layer, ADR/context retrieval, and cross-contract consistency checks.

## 2. Concrete claims

1. Strong product convergence exists around keeping intent in durable spec artifacts instead of leaving it in chat history.
   Evidence: `Kiro`, `GitHub Spec-Kit`, `Tessl`, and `Augment Intent` all use persistent specs/steering/constitution-style artifacts rather than ephemeral prompts. Local synthesis in [2026-03-12-intent-preservation.md](/Users/vi/vicc/docs/research/2026-03-12-intent-preservation.md#L104) cites those systems and their workflows.

2. A shared domain glossary is the main practical defense against terminology drift, but enforcement is still mostly manual.
   Evidence: local review notes that DDD `ubiquitous language` remains largely manual and no dedicated open-source tool for glossary extraction plus drift detection was found; recommended pipeline is extraction + coreference + embedding clustering + cross-module comparison [2026-03-12-nl-consistency-checking.md](/Users/vi/vicc/docs/research/2026-03-12-nl-consistency-checking.md#L94), [2026-03-12-nl-consistency-checking.md](/Users/vi/vicc/docs/research/2026-03-12-nl-consistency-checking.md#L126). Related spec-first research explicitly recommends a glossary section in the spec and using only glossary terms in spec sentences [2026-03-12-spec-driven-development.md](/Users/vi/vicc/docs/research/2026-03-12-spec-driven-development.md#L152).

3. ADR retrieval is more effective than passive ADR storage.
   Evidence: `Archgate` is notable because it does not just store ADRs; it turns them into executable rules and feeds live ADR context to coding agents before code is written [2026-03-12-intent-preservation.md](/Users/vi/vicc/docs/research/2026-03-12-intent-preservation.md#L124). This is directly relevant to `Signum` because local contracts otherwise drift from prior decisions.

4. Preventing drift requires traceability from intent to code, not just approval at the contract step.
   Evidence: `Git AI` links code ranges to conversation threads and `SpecStory` preserves session histories as repo artifacts; both address prompt-to-code lineage loss, but each only covers part of the problem [2026-03-12-intent-preservation.md](/Users/vi/vicc/docs/research/2026-03-12-intent-preservation.md#L150), [2026-03-12-intent-preservation.md](/Users/vi/vicc/docs/research/2026-03-12-intent-preservation.md#L165).

5. Consistency checking is a viable proxy for correctness when direct ground truth is unavailable.
   Evidence: `Clover` reduces correctness checking to consistency checking across three artifacts and reports strong results on its benchmark; this supports using cross-artifact consistency checks in `Signum` between project intent, task contract, and code/test artifacts [2026-03-12-nl-consistency-checking.md](/Users/vi/vicc/docs/research/2026-03-12-nl-consistency-checking.md#L140).

6. Large-project agent workflows need persistent context infrastructure, not just bigger prompts.
   Evidence: context-engineering literature cited in local research describes hot memory, domain-specialist agents, and on-demand cold knowledge base; key finding is that persistent context infrastructure maintains intent consistency across sessions [2026-03-12-intent-preservation.md](/Users/vi/vicc/docs/research/2026-03-12-intent-preservation.md#L177).

7. Current `Signum` already contains a local anti-drift loop, but it is task-local.
   Evidence: contractor writes `assumptions` and `openQuestions`, pipeline blocks on unresolved ambiguity, schema has lineage fields, and `Clover reconstruction` checks whether ACs still represent the goal [contractor.md](/Users/vi/personal/skill7/devtools/signum/agents/contractor.md#L32), [contractor.md](/Users/vi/personal/skill7/devtools/signum/agents/contractor.md#L77), [contract.schema.json](/Users/vi/personal/skill7/devtools/signum/lib/schemas/contract.schema.json#L138), [contract.schema.json](/Users/vi/personal/skill7/devtools/signum/lib/schemas/contract.schema.json#L202), [signum.md](/Users/vi/personal/skill7/devtools/signum/commands/signum.md#L430), [signum.md](/Users/vi/personal/skill7/devtools/signum/commands/signum.md#L736).

8. `repo-contract.json` helps with invariant drift, but not with semantic/project-intent drift.
   Evidence: current README defines `repo-contract.json` as repo-wide invariants independent of task [README.md](/Users/vi/personal/skill7/devtools/signum/README.md#L74). That is useful for cross-cutting rules, but it does not encode project goals, glossary, or initiative intent.

## 3. Sources

### Primary local file refs

- [2026-03-12-intent-preservation.md](/Users/vi/vicc/docs/research/2026-03-12-intent-preservation.md#L104)
- [2026-03-12-nl-consistency-checking.md](/Users/vi/vicc/docs/research/2026-03-12-nl-consistency-checking.md#L94)
- [2026-03-12-spec-driven-development.md](/Users/vi/vicc/docs/research/2026-03-12-spec-driven-development.md#L146)
- [contractor.md](/Users/vi/personal/skill7/devtools/signum/agents/contractor.md#L32)
- [contract.schema.json](/Users/vi/personal/skill7/devtools/signum/lib/schemas/contract.schema.json#L138)
- [signum.md](/Users/vi/personal/skill7/devtools/signum/commands/signum.md#L430)
- [README.md](/Users/vi/personal/skill7/devtools/signum/README.md#L74)

### Referenced source URLs

- [Kiro](https://kiro.dev/)
- [GitHub Blog: Spec-driven development with AI](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/)
- [Tessl](https://tessl.io/)
- [Augment Intent](https://www.augmentcode.com/product/intent)
- [Martin Fowler: Understanding Spec-Driven Development](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
- [Archgate](https://archgate.dev/)
- [SpecStory](https://specstory.com/)
- [Git AI: Introducing Git AI](https://usegitai.com/blog/introducing-git-ai)
- [Clover paper](https://arxiv.org/abs/2310.17807)
- [Clover overview](https://ai.stanford.edu/blog/clover/)
- [Automotive requirements consistency toolchain](https://www.se-rwth.de/publications/Leveraging-Natural-Language-Processing-for-a-Consistency-Checking-Toolchain-of-Automotive-Requirements.pdf)
- [Coreference resolution for requirements](https://link.springer.com/article/10.1007/s00766-022-00374-8)
- [Cross-domain ambiguity detection](https://link.springer.com/article/10.1007/s10515-019-00261-7)
- [GLaMoR ontology consistency checking](https://arxiv.org/html/2504.19023v1)
- [Codified Context paper](https://arxiv.org/abs/2602.20478)

## 4. Practical mechanisms we can adopt in Signum

### 4.1 Artifact layer

Add a project-level layer above task contracts:

- `project.intent.md`
  - project goal
  - user/persona
  - capabilities
  - non-goals
  - glossary
  - key success criteria
- `project.constitution.md`
  - stable rules and preferences
  - cross-cutting engineering constraints
- `docs/adr/`
  - decision rationale
- existing `repo-contract.json`
  - executable repo-wide invariants
- existing task `.signum/contracts/<contractId>/contract.json`
  - narrow executable slice

### 4.2 Contract inheritance

Extend task contracts with inherited context references instead of copying the whole project:

- `projectRef`
- `initiativeRef`
- `epicRef`
- `adrRefs`
- `glossaryVersion`
- `globalConstraintsInherited`
- `dependsOn`
- `relatedContractIds`
- `contextSnapshotHash`

This prevents prompt bloat and still makes drift checkable.

### 4.3 Glossary enforcement

Add a `glossary` object at project level and a contract-time linter:

- fail on undefined critical domain terms;
- warn on synonym proliferation;
- warn when the same term has multiple definitions across active contracts;
- require every task contract to reference the glossary version it used.

MVP implementation can be simple:

- canonical term list in markdown or JSON;
- lexical match for forbidden synonyms;
- alias table;
- contract review step that flags new non-glossary nouns in `goal`, `inScope`, `ACs`.

### 4.4 Contradiction and consistency checks

Add a `cross-contract consistency` stage before approval:

- compare new contract against active related contracts;
- detect duplicate scope and conflicting assumptions;
- compare ACs with upstream project intent;
- compare local terms with glossary;
- run a `goal reconstruction` test not only from ACs, but also from inherited context.

Pragmatic rule set:

- `BLOCK` on explicit contradiction with project invariants or ADR rules;
- `WARN` on terminology drift or possible overlap;
- `BLOCK` on missing dependency or interface owner;
- `WARN` on low-confidence semantic conflict.

### 4.5 ADR/context retrieval

Before generating a contract, retrieve:

- relevant ADRs by touched paths, tags, or interfaces;
- related recent contracts;
- matching glossary terms;
- initiative-level intent.

This is the `Archgate` lesson: decisions must be retrievable at write time, not just stored.

### 4.6 Intent preservation and lineage

Adopt a lightweight lineage model:

- every contract records parent/related IDs;
- every merged contract links to code paths touched;
- every ADR links to contracts that implemented or superseded it;
- optionally store `decision summaries` in git notes or a `.signum/intent-log.jsonl`.

### 4.7 New Signum checks worth adding

Suggested new checks:

1. `glossary_check`
2. `cross_contract_overlap_check`
3. `adr_relevance_check`
4. `intent_diff_check`
   - does this contract still fit `project.intent.md`?
5. `upstream_change_invalidation_check`
   - did glossary or ADRs change since this contract draft was created?

## 5. Open questions

1. What should be canonical: markdown docs, JSON schema, or both?
2. Is glossary global for the whole repo, or scoped by bounded context?
3. How aggressive should blocking be for semantic conflicts with low confidence?
4. Should `Signum` keep one global project intent file or multiple initiative-level intent files?
5. How should upstream changes invalidate in-flight contracts without creating too much churn?
6. Do we need a separate `clarification summary` view for users, or is `draft contract` enough if rendered well?
7. How much of contradiction detection can be deterministic before LLM review is needed?

## 6. Confidence

Confidence: `0.84`

Reasoning:

- High confidence that durable specs, glossary discipline, ADR retrieval, and lineage reduce drift. This is supported by strong product convergence and by local synthesis across multiple sources.
- Medium confidence on the exact automation design for glossary drift and contradiction detection. The literature and tooling are fragmented; the best practical path today is a hybrid pipeline, not a single off-the-shelf solution.
- Medium-high confidence that `Signum` should add project-level intent and cross-contract checks. This follows directly from current task-local limitations in the repository and from the surveyed systems.
