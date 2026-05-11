---
name: signum
description: Use when the user wants contract-first development — define correctness before coding, implement against a contract, audit with multiple models, and package proof artifacts.
---

# Signum — Evidence-Driven Development Pipeline

Run a CONTRACT → EXECUTE → AUDIT → PACK pipeline for any implementation task.

## When to Use

- User asks to "implement X" and you want verifiable correctness
- Task requires multi-model code review
- Changes need proof artifacts for CI/CD gates
- Risk is medium-high and ad hoc coding is insufficient

## Pipeline

1. **CONTRACT** — Turn the request into a verifiable contract with acceptance criteria
2. **EXECUTE** — Implement against the contract, not a vague prompt
3. **AUDIT** — Deterministic checks (lint, test, scope) + optional multi-model review
4. **PACK** — Package into a proofpack artifact with verdict (AUTO_OK / HUMAN_REVIEW / AUTO_BLOCK)

## Core Rules

- Do not start implementation before a contract exists
- If the contract is vague, stop and improve it
- Check against deterministic criteria, not just model opinion
- Keep active run/pipeline artifacts under `.signum/contracts/<contractId>/`
- Treat root `.signum/` as the registry/state/archive/compatibility namespace, not the canonical per-run artifact root
- If reduced audit coverage on medium/high-risk task → HUMAN_REVIEW, not AUTO_OK
