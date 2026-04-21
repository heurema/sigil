# Changelog

## [4.20.0] - 2026-04-21

### Changed
- Canonical contract-dir artifact root cleanup and parity hardening for the Claude overlay
  - overlay command/docs/prompts now consistently describe `.signum/contracts/<contractId>/` as the active artifact root
  - overlay CI/template surfaces prefer canonical artifact paths before legacy root fallback
  - overlay changelog/docs/quickstart wording now matches the canonical storage model used by the runtime

## [4.9.0] - 2026-03-17

### Added
- **Policy scanner** (Step 3.1.3) — deterministic bash/grep scan on combined.patch for security sinks, unsafe patterns, and dependency changes. Zero LLM cost. CRITICAL findings trigger AUTO_BLOCK.
  - `lib/policy-scanner.sh` — 12 curated patterns (eval, subprocess, XSS, SQL injection, weak crypto, TODO/FIXME, debug statements, npm/cargo/pyproject/go.mod deps)
  - Manifest-only dependency filtering (3/3 arbiter consensus)
  - Fail-closed on missing patch (exit 1 + JSON error)
  - `checks.policy_scan` envelope in proofpack.json
- **Dynamic strategy injection** — Contractor classifies task type (bugfix/feature/refactor/security) via keyword scan, generates `implementationStrategy` in contract.json. Engineer reads as process guide.
  - Priority: security > bugfix > refactor > feature
  - `lib/schemas/contract.schema.json` updated with optional `implementationStrategy` field
- **Context retrieval** (Step 3.2.0) — pre-review step gathers git history (last commit per file), issue refs (ID + title), and project.intent.md. Injected into Claude reviewer only — Codex/Gemini remain adversarially isolated.
  - `{review_context}` variable in `lib/prompts/review-template.md`
- **Parallel repair lanes** (Step 3.6.2) — 2 parallel Engineers in git worktrees with different strategies (minimal fix vs root-cause). Mechanic+holdout on both, full review on winner only. Runner-up reviewed if winner gets MAJOR+.
  - Lane artifacts in `iterations/NN/lanes/A|B/` under the active contract artifact root
  - `selected_lane.json` for audit trail
  - Trap-based worktree cleanup, fallback to single-lane on failure
- **Typed diagnostics** — extracted mechanic logic into `lib/mechanic-parser.sh` with hybrid output format: summary per check always + per-file findings when runner supports structured output.
  - 8 runners: pytest, npm test, cargo test, go test, ruff, eslint, mypy, tsc
  - `origin` field: "structured", "stable_text", "none"
  - `mechanicFindings` array in repair_brief.json for Engineer

### Changed
- **Contract approval UX** — replaced fragmented bash echo blocks with markdown-first display. Goal never truncated, compact table, grouped warnings.
- Policy scanner archive cleanup: `policy_scan.json` included in archive purge list

## [4.8.0] - 2026-03-16

### Added
- `/signum init` command — bootstrap project context (project.intent.md + project.glossary.json) from existing codebase
  - 4-phase pipeline: SCAN (deterministic) → SYNTHESIZE (LLM) → PRESENT (interactive) → VERIFY
  - Source precedence hierarchy: docs/ > CLAUDE.md > README.md > package.json
  - Non-Goals only from explicit negative signals (ADRs, README limitations), never from absence
  - Per-section evidence comments (`<!-- evidence: ... -->`) and confidence annotations
  - Glossary merge semantics: never remove existing terms, only add
  - Git log with 6-month dirstat horizon for sustained activity patterns
  - Deep docs scan: docs/research/, docs/plans/, docs/adr/
  - Ignore set: .git, .signum/, node_modules/, dist/, build/, .venv/, __pycache__/, coverage/, tests/fixtures/
  - `--force` flag to overwrite existing files
  - Symlink protection on file write
- `commands/init.md` — command orchestrator
- `agents/init-synthesizer.md` — LLM synthesis agent (read-only, no Write/Bash tools)
- `lib/init-scanner.sh` — deterministic signal extraction script
- `tests/test-init.sh` — 42-test scanner validation suite
- `docs/how-it-works.md` — init pipeline documentation

## [4.6.1] - 2026-03-15

### Changed
- Extracted 6 inline quality checks from `commands/signum.md` into standalone testable scripts:
  - `lib/glossary-check.sh` — forbidden synonym scan from glossary aliases
  - `lib/terminology-check.sh` — cross-contract synonym proliferation detection
  - `lib/overlap-check.sh` — inScope overlap between active contracts
  - `lib/assumption-check.sh` — assumption contradiction detection
  - `lib/adr-check.sh` — ADR relevance check for inScope paths
  - `lib/staleness-check.sh` — upstream artifact staleness detection (pure, no mutation)
- All scripts: JSON stdout, stderr diagnostics, exit 0 for check results, non-zero for infra errors
- Orchestrator (`commands/signum.md`) now calls scripts and owns mutation/blocking decisions
- Removed glossary scan from `lib/prose-check.sh` (ownership moved to `lib/glossary-check.sh`)

### Added
- `lib/sync-cache.sh` — sync plugin to emporium cache for subagent freshness
- `project.intent.md` and `project.glossary.json` for Signum's own project context

### Fixed
- Spec quality gate now recognizes DSL `{steps}` verify format (was only counting `{type, value}`)

## [4.6.0] - 2026-03-15

### Added
- **Iterative AUDIT**: review-fix loop in Phase 3 — engineer fixes MAJOR/CRITICAL findings, full re-review each iteration until convergence or max iterations (default 20)
- `SIGNUM_AUDIT_MAX_ITERATIONS` env var for configurable iteration cap
- `SIGNUM_CI_RELAXED` env var — HUMAN_REVIEW maps to exit 0 in relaxed mode
- Engineer repair mode: reads `repair_brief.json` to fix specific findings
- Per-iteration artifact storage in `iterations/NN/` under the active contract artifact root
- `audit_iteration_log.json` for cross-iteration tracking
- Best-of-N with rollback: pipeline keeps best candidate, not last attempt
- Early stop: halts if no improvement for 2 consecutive iterations
- Finding fingerprints for cross-iteration resolved/persisting/new tracking
- Holdout sanitization: engineer sees category only, never hidden test details
- Flaky test retry (pytest-only): retry 2x before counting as regression
- `flaky_tests.json` for run-local flaky test tracking
- `iterativeAudit` section in proofpack schema (v4.6)
- Contract schema v3.7: five new optional top-level fields for Phase 5 Within-Task Refinement Loop:
  - `ambiguityCandidates` (array of `{text, location, severity}`) — ambiguous phrases flagged during ambiguity review pass
  - `contradictionsFound` (array of `{claim_a, claim_b, type}`) — contradictions flagged during contradiction review pass
  - `clarificationDecisions` (array of `{question, decision, rationale}`) — inline clarifications resolved during missing-input review pass
  - `assumptionProvenance` (array of `{id, text, source, confidence}`) — typed provenance records for assumptions from goal reconstruction pass
  - `readinessForPlanning` (object with `verdict: "go"|"no-go"` and `summary`) — computed gate after all critique passes
- Contractor agent step 3.6: 4-pass self-critique loop (medium/high risk only):
  - Pass 1 — ambiguity review: flags ambiguous phrases in goal, ACs, scope
  - Pass 2 — missing-input review: checks for missing preconditions; records clarification decisions
  - Pass 3 — contradiction review: detects goal/scope/risk contradictions
  - Pass 4 — goal reconstruction / coverage review: reconstructs goal from ACs; records assumption provenance
  - Auto-revision capped at maximum of 2 rounds; escalates to user when verdict remains `"no-go"` after 2 rounds
  - Low-risk contracts skip all 4 critique passes (no overhead for simple tasks)
- Contractor writes all four typed findings arrays and `readinessForPlanning` to contract.json output
- Orchestrator surfaces `readinessForPlanning.verdict` and summary in the Phase 1 human approval prompt

### Changed
- Proofpack schema bumped to v4.6 (backward compatible with 4.0–4.5)
- Contract schema bumped to v3.7 (backward compatible with v3.0–v3.6)
- Synthesizer is now iteration-aware: computes `iterationScore`, tracks findings across passes
- Fresh-reviewer rule removed — Claude reviewer always uses Opus
- Archive/restart cleanup includes iteration artifacts

## [4.5.0] - 2026-03-15

### Added
- Contract schema v3.6: upstream staleness detection via four new optional fields inside `contextInheritance`:
  - `contextSnapshotHash` (string) — SHA-256 hex digest over concatenated byte contents of `staleIfChanged` files in array order, computed at contract creation time
  - `staleIfChanged` (string[]) — upstream artifact paths whose modification triggers staleness; at minimum includes `project.intent.md` when loaded
  - `stalenessStatus` (enum: `fresh|warning|stale`) — current staleness state updated by the pipeline
  - `stalenessPolicy` (enum: `block|warn`, default `warn`) — action when upstream hash differs
- `upstream_staleness_check` step in Phase 1 CONTRACT (after `adr_relevance_check`): recomputes SHA-256 over `staleIfChanged` paths, compares to `contextSnapshotHash`, emits BLOCK when `stalenessPolicy=block` or WARN when `warn` if hash differs; skips when `staleIfChanged` is absent or empty
- Contractor agent (Phase 4 upstream staleness tracking): automatically populates `staleIfChanged`, `contextSnapshotHash`, `stalenessStatus`, and `stalenessPolicy` at contract creation time when contextInheritance artifacts are loaded

### Changed
- Contract schema bumped to v3.6 (backward compatible with v3.0–v3.5)

## [4.4.0] - 2026-03-15

### Added
- Contract schema v3.5: four new optional fields for cross-contract graph queries:
  - `dependsOnContractIds` (string[]) — ordered dependency edges (user-declared)
  - `supersedesContractIds` (string[]) — obsolescence edges (user-declared)
  - `supersededByContractId` (string) — reverse obsolescence pointer
  - `interfacesTouched` (string[]) — named interfaces/APIs touched by the contract
- Phase 3 cross-contract coherence checks (all WARN-only, non-blocking):
  - `cross_contract_overlap_check`: detects inScope file overlap with active contracts in index.json; writes `overlap_warnings` to `spec_quality.json`
  - `assumption_contradiction_check`: compares assumption text pairs across related contracts for direct contradiction keywords; writes `assumption_warnings` to `spec_quality.json`
  - `adr_relevance_check`: scans `docs/adr/` and `docs/decisions/` for relevant ADRs against inScope paths; warns when `adrRefs` is absent/empty; graceful no-op when directories absent; writes `adr_warnings` to `spec_quality.json`
- Contractor agent documents all four new v3.5 fields with usage guidance

### Changed
- Contract schema bumped to v3.5 (backward compatible with v3.0–v3.4)

## [4.3.0] - 2026-03-15

### Added
- `glossaryVersion` field in contract schema v3.4 (optional string, set from `project.glossary.json`)
- `project.glossary.json` integration: contractor reads `canonicalTerms` and `aliases` from project root; omits `glossaryVersion` when file is absent
- `glossary_check`: deterministic lexical scan of goal, inScope, and AC descriptions for forbidden synonyms; WARN-only, non-blocking, results in `spec_quality.json` `glossary_warnings`
- `terminology_consistency_check`: cross-contract synonym proliferation detection across active contracts in `.signum/contracts/index.json`; WARN-only, non-blocking, skips gracefully when index absent or no active contracts
- Step 1.4 displays `Glossary: loaded (version X, N terms)` or `Glossary: not found`
- `lib/prose-check.sh` extended with `run_glossary_scan` function (accepts contract.json + project.glossary.json paths, exits 0 always)

### Changed
- Contract schema bumped to v3.4 (backward compatible with v3.0–v3.3)

## [4.2.0] - 2026-03-15

### Added
- Project intent layer: contractor reads `project.intent.md` from target project root
- `contextInheritance` block in contract schema v3.3 (projectRef, projectIntentSha256)
- Intent alignment check (LLM-based, medium/high risk, informational)
- Missing project intent blocks medium/high risk tasks with escapable question

## v4.1.0 (2026-03-09)

### Security
- **BREAKING**: Replace `eval` in holdout verification with typed DSL runner
- Zero shell execution in verification path — eliminates code injection risk
- Exec whitelist: only `test`, `ls`, `wc`, `cat`, `jq` allowed

### Added
- Typed verification DSL with primitives: `http`, `exec`, `expect`, `capture`
- `visibility` field on acceptance criteria (`visible` / `holdout`)
- `holdoutManifest` for tamper detection of redacted holdouts
- `trust: "local"` trust model declaration
- Detailed holdout report with per-criterion results
- DSL runner with validation + execution (`lib/dsl-runner.sh`)
- Test suite for DSL runner

### Changed
- Contract schema bumped to v3.1 (backward compatible with v3.0)
- Contractor agent generates DSL verify blocks instead of shell commands
- Engineer contract strips holdout-visibility ACs (not just holdoutScenarios)
- Synthesizer handles detailed holdout report format (results array, errors count)

## [4.0.0] - 2026-03-04

### Changed
- **BREAKING**: proofpack.json schema v3.0 → v4.0
- All artifact fields changed from file path strings to envelope objects with embedded content
- `checksums` top-level field removed (per-artifact sha256 in each envelope)
- `checks.audit_summary` renamed to `checks.auditSummary` (camelCase unification)
- `auditChain` fields renamed: `contract_sha256` → `contractSha256`, `approved_at` → `approvedAt`, `base_commit` → `baseCommit`
- Hash format changed from `sha256:hex` prefix to plain hex string

### Added
- Self-contained proofpack: all artifact contents embedded in single JSON file
- Envelope format: `{ content, sha256, sizeBytes, status, omitReason? }`
- Envelope status field: `present | omitted | error` for each artifact
- Contract redaction: holdouts stripped from embedded content, `fullSha256` preserves original hash
- Diff omit-but-hash: patches >100KB stored as hash + size only
- Dynamic review provider keys (not limited to claude/codex/gemini)
- `signumVersion` and `createdAt` top-level fields
- `baseline` and `executeLog` as first-class proofpack artifacts

## [3.0.0] - 2026-03-03

### Added
- Trustless baseline capture: orchestrator runs lint/typecheck/tests BEFORE Engineer, saves to baseline.json
- Deterministic scope gate: verifies all changed files are within inScope after execute phase
- Holdout scenarios: hidden acceptance criteria in contract that Engineer never sees, run as blind validation
- Adversarial review templates: Codex gets security-focused template, Gemini gets performance-focused template
- Confidence scoring: weighted metric (execution health + baseline stability + review alignment) in audit summary
- Cross-platform sha256: auto-detects sha256sum or shasum (macOS compatibility)
- allowNewFilesUnder field in contract schema for explicit new file directory permissions

### Changed
- Schema version bumped to 3.0 (contract, proofpack)
- Mechanic now compares post-change results with baseline, flags regressions only
- AUTO_BLOCK triggers on NEW regressions vs baseline, not pre-existing failures
- Engineer reads baseline (does not capture it), removes self-reporting bias
- Codex/Gemini receive only goal + diff (adversarial isolation, no contract/mechanic context)
- Template substitution uses python3 instead of sed (fixes shell injection vulnerability)
- Extracted JSON temp files use .signum/ instead of /tmp/ (fixes race condition)
- HUMAN_REVIEW message now suggests refining acceptance criteria instead of manual code review
- Execute gate requires SUCCESS status explicitly (was only checking for non-FAILED)
- Engineer handles verify.type: "manual" gracefully (skips in repair loop, logs as manual)

### Planned (v3.1)
- Multi-path execution: parallel implementation strategies with winner selection via worktree isolation

## [2.0.1] - 2026-03-02

### Changed
- Rename plugin: sigil → signum (lat. signum — "sign, seal")

## [2.0.0] - 2026-03-02

### Changed
- Complete rewrite: 4-phase pipeline (CONTRACT -> EXECUTE -> AUDIT -> PACK)
- Multi-model audit panel (Claude + Codex + Gemini) replaces single-model review
- contract.json replaces narrative design.md
- proofpack.json replaces review-verdict.md
- Decomposed agents replace 1188-line monolith

### Added
- Contractor agent (haiku/sonnet) for structured contract generation
- Engineer agent (sonnet) with 3-attempt repair loop
- Reviewer-Claude agent (opus) for semantic review
- Synthesizer agent (sonnet) for multi-model verdict
- CLI adapter for Codex and Gemini external reviews
- JSON schemas for contract and proofpack validation
- Deterministic synthesis rules for audit decisions

### Removed
- Observer agent (replaced by multi-model audit)
- Reviewer/Skeptic/Round2 prompts (replaced by unified review template)
- Diverge/diverge-lite build strategies (deferred to future)
- Triage/fast-path/bugfix-path (deferred to future)

## [1.0.0] - 2026-02-25

### Added
- 4-phase development pipeline: Scope → Explore → Design → Build
- 3 review strategies: simple, adversarial, consensus
- Risk-adaptive agent scaling (low/medium/high)
- Observer agent for post-build plan compliance checking
- Session resume and run archiving
- Codex CLI integration with graceful degradation
