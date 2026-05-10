# Codebase Awareness Dogfood/Eval

## Current baseline

Codebase Awareness now has the MVP pipeline, ABI-hardened project caches, reuse candidates, reuse decision validation, duplicate audit, verdict mapping, PACK reuse summary evidence, and shallow lexical adapters for Go, Rust, C#/.NET, TypeScript/JavaScript, Python, and Bash/Shell.

The adapter-hardening phase is frozen for dogfood. More scanner breadth would tune against guesses instead of observed failures. Dogfood should measure whether the current shallow scanner and matcher help real implementation work before changing scanner behavior, matcher scoring, adapter behavior, audit thresholds, or PACK behavior.

The baseline remains intentionally bounded: no Tree-sitter, semantic reranking, language-server calls, dependency graph execution, network calls, or target-repo tool execution.

## What to measure

Measure the usefulness and cost of the existing artifacts:

- Whether the top reuse candidates point to code an engineer should inspect or reuse.
- Whether important helpers, shared modules, tests, or boundaries are missing.
- Whether duplicate audit findings identify real duplicate risk without over-blocking.
- Whether warm runs reuse unchanged cache entries.
- Whether prompt context stays compact enough to be useful.
- Whether project-level cache payloads stay out of proofpacks.
- Whether `reuse_decision.json` is complete, valid, and actionable in `warn` and `gate` runs.

## Dogfood task categories

A. Existing helper reuse: the task asks for validation/helper logic where a helper already exists.

B. Shared module reuse: the task should reuse a shared package, module, crate, or project reference.

C. Test convention following: the task should find and follow local test style, file placement, and framework conventions.

D. Boundary-sensitive implementation: the task should avoid internal, private, test-only, CLI, or orchestrator boundaries.

E. Duplicate-risk detection: the task would create a duplicate helper or fourth copy without reuse pressure.

F. Multi-language repo: the task touches one area in a repo with multiple active adapters.

G. No good reuse candidate: the scanner should not force a premature abstraction when local reuse is not useful.

## Metrics

Collect these per task. Prefer `warn` mode for early dogfood so false positives are visible without creating avoidable blocks.

| Metric | How to collect |
| --- | --- |
| `candidate_top1_useful` | Manually mark true when the first item in `reuse_candidates.json.candidates` should be inspected or reused for the task. |
| `candidate_top3_useful` | Manually mark true when any of the first three candidates is useful. |
| `candidate_top5_useful` | Manually mark true when any of the first five candidates is useful. |
| `false_positive_count` | Count candidates, duplicate findings, or boundary hints that pushed the engineer toward irrelevant or unsafe work. |
| `false_negative_count` | Count missed helpers, shared modules, test conventions, boundaries, or duplicate risks discovered during review. |
| `duplicate_audit_true_positive` | Mark true when `duplicate_scan.json` finds a real duplicate/reuse issue the engineer should address. |
| `duplicate_audit_false_positive` | Mark true when a major/critical duplicate finding is not actionable for the task. |
| `warm_scan_files_reused` | Read `scanStats.filesReused` from the warm `codebase-index-v1.json` or dogfood summary output. |
| `warm_scan_files_extracted` | Read `scanStats.filesExtracted` from the warm `codebase-index-v1.json` or dogfood summary output. |
| `cold_scan_duration_seconds` | Measure the first scan/run with `/usr/bin/time -p` or shell `time`; record wall-clock `real`. |
| `warm_scan_duration_seconds` | Measure the same scan/run after caches exist; record wall-clock `real`. |
| `reuse_decision_quality` | Manually classify as `good`, `partial`, or `poor` based on whether top/strong candidates were addressed with clear dispositions and actions where required. |
| `prompt_context_size_estimate` | Count bytes or lines in `implementation_context.json` plus `reuse_candidates.json`; record the method used. |
| `proofpack_cache_exclusion_confirmed` | Inspect `proofpack.json` and confirm `.signum/cache/*` payloads are not embedded. Existing PACK tests cover this mechanically. |

## False positive / false negative taxonomy

Use consistent classifications so later tuning proposals can be compared:

- `false positive`: a candidate or finding is present but not useful for the task.
- `false negative`: an expected helper, module, test convention, boundary, or duplicate risk is missing.
- `ranking issue`: the useful candidate exists but is below the top five or buried under weaker items.
- `boundary issue`: a candidate crosses an internal/private/test/CLI/orchestrator boundary without enough warning, or a valid public reuse path is over-warned.
- `cache issue`: warm reuse is unexpectedly low, stale data appears, or incompatible cache data is reused.
- `audit threshold issue`: duplicate audit severity or `warn`/`gate` outcome pressure does not match reviewer judgment.
- `docs/protocol issue`: the artifacts are correct but the engineer did not know how to act on them.

## How to run locally

1. Pick one dogfood task category and write down the expected useful helper/module/test/boundary, if known.
2. Run Signum with Codebase Awareness in `warn` mode first.
3. Save the run artifacts from `.signum/contracts/<contractId>/` and cache stats from `.signum/cache/`.
4. Repeat the scan or run after caches exist to collect warm cache metrics.
5. Inspect `implementation_context.json`, `reuse_candidates.json`, `reuse_decision.json`, `duplicate_scan.json`, `reuse_summary.json`, and `proofpack.json`.
6. Fill out `docs/templates/codebase-awareness-dogfood-result.md`.
7. If useful, generate a compact reporting-only summary:

```bash
python3 scripts/codebase_awareness/summarize_dogfood_run.py \
  --contract-root .signum/contracts/example \
  --cache-root .signum/cache \
  --output .signum/contracts/example/codebase_awareness_dogfood_summary.json
```

The summary script is reporting-only. It reads existing artifacts, writes only the requested summary file, is not required for Signum runs, and is not wired into EXECUTE, AUDIT, or PACK.

## Acceptance thresholds

These are dogfood targets, not CI gates:

- `candidate_top3_useful` rate >= 70%.
- Duplicate audit false-positive rate <= 10% in `warn` mode.
- `gate` `AUTO_BLOCK` false-positive rate == 0 in sampled dogfood tasks.
- Warm scans reuse > 70% of unchanged indexed files.
- No proofpack cache payload leaks.
- `reuse_decision.json` coverage is valid in `warn` and `gate` runs.

Do not tune behavior from one task. Consider scanner, matcher, audit, or protocol changes only after repeated failures in the same taxonomy category and after preserving representative artifacts.

Tree-sitter or semantic mode should be considered only when dogfood shows repeated false negatives or ranking failures that cannot be fixed with the current shallow lexical/index artifacts, and only with a separate design that covers determinism, dependency footprint, cache ABI, performance, and proofpack impact.

## Backlog template

```text
Title:
[Codebase Awareness] False positive/negative: <short>

Repo/task:
Mode:
Top candidates:
Expected:
Actual:
Artifacts:
- reuse_candidates.json:
- reuse_decision.json:
- duplicate_scan.json:
- reuse_summary.json:

Classification:
- false positive
- false negative
- ranking issue
- boundary issue
- cache issue
- audit threshold issue
- docs/protocol issue

Suggested fix:
```

## What not to change during dogfood

Do not change scanner behavior, adapter behavior, matcher scoring, reuse candidate ranking, reuse decision validation, duplicate audit behavior, verdict mapping, PACK/proofpack behavior, language adapter coverage, or external tooling during baseline collection.

Dogfood PRs may add reports, templates, fixture summaries, and issue writeups. Behavior changes should be follow-up PRs with evidence from multiple dogfood results.
