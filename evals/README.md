# Signum eval harness v1

This directory contains the first offline eval harness for Signum prompt/orchestration work.

## Purpose
- Catch regression in contract/audit/proofpack semantics without making live provider calls.
- Keep representative cases in git as reviewed snapshots.
- Give prompt/orchestration changes one cheap deterministic check before runtime complexity grows.

## Scope
- 6 curated fixture cases.
- Deterministic grading only.
- Snapshot comparison only.

## Non-goals
- No live provider evals.
- No LLM judge.
- No prompt auto-optimization.
- No trajectory or agent-loop evaluation.
- No root-vs-overlay parity coverage in v1.

## Layout
- `fixtures/*.json` — representative pseudo-run artifacts.
- `snapshots/*.json` — committed expected summaries from the deterministic grader.
- `checks.py` — invariant checks for contract/audit/proofpack semantics.
- `run.py` — runner that compares current outputs to committed snapshots.

## Run
```bash
python3 evals/run.py
```

Expected v1 success shape:
- `.status == "ok"`
- `.fixtureCount == 6`
- `.failed == 0`

## Update snapshots intentionally
```bash
python3 evals/run.py --update-snapshots
```

Only update snapshots when the change is intentional and reviewed as a behavior change.
