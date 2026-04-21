# Contract/Clarification Self-Improvement Loops for Signum-Like Systems

Date: 2026-03-15
Author: Codex
Status: source-backed synthesis
Question: Which self-improvement loops can strengthen the `CONTRACT` / clarification layer of a Signum-like system, especially for large projects?

## 1. Short Answer

Two loop families are useful, but for different scopes.

- `Within-task refinement` is immediately applicable to `draft contract` quality. The right shape is `draft -> critique -> revise -> gate`, with critique focused on `ambiguities`, `missing inputs`, `contradictions`, `assumptions`, and `goal coverage`.
- `Cross-run optimization` is useful only after enough historical contracts exist. The right shape is `mutable contractor/reviewer prompts -> frozen evaluator -> keep/discard`, not free-form self-editing.

For Signum specifically:

- Use `Self-Refine` / `Reflexion` style loops inside a single task to improve one `contract.json`.
- Use `autoresearch` / `DSPy GEPA` / `MIPROv2` / `OPRO` style loops only to improve the prompts and rubrics that generate and review contracts across many tasks.
- Do not optimize the evaluator and the contractor together. Freeze the contract-quality gate, or the system will game the metric.

## 2. Concrete Claims

1. The best immediate gain is not autonomous prompt evolution, but a stricter `within-task` repair loop around the existing Signum `draft contract`.
Evidence:
- Signum already has the raw scaffolding: `assumptions`, `openQuestions`, `requiredInputsProvided`, a spec review for ambiguities/assumptions/missing inputs, a Clover reconstruction check, and a human approval checklist.
- This means Signum already supports `draft -> review -> revise -> approval`; the missing part is making that loop explicit and better structured.

2. `Within-task refinement` should target artifact quality, not chain-of-thought quality.
Evidence:
- `Self-Refine` and `Reflexion` patterns improve outputs by externalizing critique and revision, but Signum needs this applied to a concrete artifact: `contract.json`.
- The critique must operate over typed issues: ambiguity class, contradiction class, missing-input class, assumption provenance, coverage gaps.

3. `Cross-run optimization` is applicable only if Signum can score contracts with a stable external gate.
Evidence:
- `autoresearch` works because `train.py` is mutable and `prepare.py` / `evaluate_bpb` are fixed; keep/discard depends on a frozen metric.
- The same pattern transfers only if Signum freezes a contract-quality evaluator and treats `contractor` / `spec-review` prompts as the mutable object.

4. Large projects raise the value of `cross-run` optimization, but also increase the risk of metric gaming.
Evidence:
- Large projects create repeated contract patterns: dependency edges, inherited assumptions, glossary drift, initiative scope leakage, cross-contract contradictions.
- If optimization rewards only short-term approval or low open-question counts, the system may under-ask and silently over-assume.

5. `DSPy`-style optimizers are plausible later-stage tools, not day-one machinery for Signum.
Evidence:
- Local prior research shows `MIPROv2` and `GEPA` are effective when enough examples exist, but the guidance consistently assumes many runs and a stable evaluator.
- For a contract system with sparse, heterogeneous tasks, manual or semi-manual ratcheting is more defensible initially than full optimizer-driven evolution.

6. The best `within-task` loop for Signum is multi-pass critique with narrow roles, not one generic “improve this contract” pass.
Recommended passes:
- `ambiguity review`
- `missing-input review`
- `contradiction / consistency review`
- `goal reconstruction / coverage review`
- `user confirmation`

7. The best `cross-run` loop is a ratchet over prompts and rubrics, not over the contract schema first.
Reason:
- Prompt/rubric evolution is cheap and reversible.
- Schema changes affect compatibility, tooling, archival proof chains, and downstream execution.

## 3. Sources

### Primary local Signum refs

- Signum contract schema: [contract.schema.json](/Users/vi/personal/skill7/devtools/signum/lib/schemas/contract.schema.json)
- Signum workflow and CONTRACT gates: [signum.md](/Users/vi/personal/skill7/devtools/signum/commands/signum.md)
- Signum README and `repo-contract.json` concept: [README.md](/Users/vi/personal/skill7/devtools/signum/README.md)

Relevant local lines / sections:
- `assumptions`, `openQuestions`, `requiredInputsProvided`, `parentContractId`, `relatedContractIds` in [contract.schema.json](/Users/vi/personal/skill7/devtools/signum/lib/schemas/contract.schema.json)
- hard stop on unresolved inputs and questions in [signum.md](/Users/vi/personal/skill7/devtools/signum/commands/signum.md)
- spec review, Clover reconstruction, approval checklist in [signum.md](/Users/vi/personal/skill7/devtools/signum/commands/signum.md)

### Local research refs

- `autoresearch` transfer patterns: [2026-03-14-autoresearch-delve-synthesis-2026.md](/Users/vi/vicc/docs/research/2026-03-14-autoresearch-delve-synthesis-2026.md)
- `autoresearch` landscape: [2026-03-10-autoresearch-landscape.md](/Users/vi/vicc/docs/research/2026-03-10-autoresearch-landscape.md)
- prompt optimization for multi-agent systems: [2026-03-14-prompt-optimization-multi-agent-2026.md](/Users/vi/vicc/docs/research/2026-03-14-prompt-optimization-multi-agent-2026.md)
- intent preservation / living specs / constitutions: [2026-03-12-intent-preservation.md](/Users/vi/vicc/docs/research/2026-03-12-intent-preservation.md)
- ambiguity and consistency checking: [2026-03-12-nl-consistency-checking.md](/Users/vi/vicc/docs/research/2026-03-12-nl-consistency-checking.md)
- spec-first vs contract-first framing: [2026-03-03-codex-research.md](/Users/vi/vicc/docs/research/2026-03-03-codex-research.md)

### External URLs

- `autoresearch`: [https://github.com/karpathy/autoresearch](https://github.com/karpathy/autoresearch)
- `Self-Refine`: [https://arxiv.org/abs/2303.17651](https://arxiv.org/abs/2303.17651)
- `Reflexion`: [https://arxiv.org/abs/2303.11366](https://arxiv.org/abs/2303.11366)
- `STaR`: [https://arxiv.org/abs/2203.14465](https://arxiv.org/abs/2203.14465)
- `OPRO`: [https://arxiv.org/abs/2309.03409](https://arxiv.org/abs/2309.03409)
- `DSPy MIPROv2`: [https://arxiv.org/abs/2406.11695](https://arxiv.org/abs/2406.11695)
- `DSPy optimizers`: [https://dspy.ai/learn/optimization/optimizers/](https://dspy.ai/learn/optimization/optimizers/)
- `GEPA`: [https://arxiv.org/abs/2507.19457](https://arxiv.org/abs/2507.19457)

## 4. Recommended Loops and Guardrails

### A. Within-task loop: recommended now

Artifact under improvement:
- `.signum/contracts/<contractId>/contract.json` in `draft`

Loop:
1. Generate initial `draft contract`
2. Run `ambiguity review`
3. Run `missing-input review`
4. Run `contradiction / consistency review`
5. Run `goal reconstruction / coverage review`
6. Revise contract
7. If unresolved user input remains: stop and ask
8. If gate passes: present user-facing clarification summary and approval checklist

Guardrails:
- No silent closure of `openQuestions`
- Every inferred assumption must be explicit
- `requiredInputsProvided=false` must remain a hard stop
- Critique passes should produce typed findings, not free-form commentary
- Cap auto-revision to `1-2` rounds; after that, escalate to user

What to add to Signum:
- `ambiguityCandidates`
- `contradictionsFound`
- `clarificationDecisions`
- `assumptionProvenance`
- `readinessForPlanning`

### B. Cross-run loop: recommended later

Mutable objects:
- contractor prompt
- spec-review prompt
- clarification-question policy
- contract quality rubric weights

Frozen evaluator:
- contradiction / consistency checks
- unresolved question policy
- goal reconstruction score
- downstream failure rate: how often EXECUTE or AUDIT found underspecification
- user approval quality, not just approval occurrence

Loop:
1. Collect historical contracts and downstream outcomes
2. Propose a prompt/rubric variant
3. Evaluate on held-out tasks with the frozen evaluator
4. Keep only if quality improves without increased drift
5. Track plateau and force strategy diversification

Guardrails:
- Never optimize the evaluator and the contractor in the same cycle
- Use held-out tasks, not the contracts used to invent the prompt
- Penalize `fewer questions` if it causes higher downstream underspecification
- Track complexity cost; small gains from much more brittle prompts are not worth keeping
- Maintain experiment memory of failed prompt variants

### C. What is actually applicable vs not

Applicable now:
- `Self-Refine` style critique/revise over `contract.json`
- `Reflexion` style memory of why prior contracts failed downstream
- `autoresearch` style `keep/discard` prompt evolution against a frozen gate

Applicable later:
- `DSPy GEPA`, `MIPROv2`, `OPRO` for prompt optimization after enough runs and labels exist

Low priority / weak fit:
- `STaR` as a primary mechanism; it is more useful for reasoning trace bootstrapping than contract governance
- open-ended “self-improve until better” loops without a stable evaluator

## 5. Open Questions

1. What exact frozen evaluator should score contract quality?
2. How should Signum weight `ask more` versus `assume more` for large projects with rich context?
3. What is the minimum dataset size before automated prompt optimization is more signal than noise?
4. Should downstream execution/audit failures feed back into prompt evolution automatically or only through human review?
5. How do we measure `intent preservation` across parent and child contracts in large projects?
6. What is the right penalty for verbosity or over-constrained contracts?

## 6. Confidence

Overall confidence: `0.83`

Why not higher:
- The transfer from `autoresearch` and `DSPy` to contract drafting is architectural, not direct benchmark evidence.
- Evidence is strong for the loop patterns, weaker for exact thresholds such as run counts, metric weighting, and optimizer choice in this domain.

Practical confidence by recommendation:
- `within-task critique/revise loop over draft contract`: high
- `frozen evaluator for cross-run optimization`: high
- `manual ratchet before full DSPy optimization`: medium-high
- `full automated prompt evolution for contract drafting today`: medium-low
