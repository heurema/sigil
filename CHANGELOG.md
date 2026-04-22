# Changelog

## [Unreleased]

### Added
- Release guardrails for marketplace sync:
  - `lib/check-emporium-sync.sh` — fail-loud check that compares local Signum release metadata against the `signum` entry in `heurema/emporium/.claude-plugin/marketplace.json`
  - `lib/release-smoke.sh` — maintainer smoke path that runs the Emporium sync check plus `/signum:init --harness` coverage
  - `.github/workflows/release-guardrails.yml` — CI workflow that checks out Emporium and runs the same release smoke path on `workflow_dispatch`, published releases, and release-related pushes to `main`, while skipping fork/canonical-repo mismatches
  - `tests/test-emporium-sync.sh`, `tests/test-release-smoke.sh` — regression coverage for the sync check and smoke/workflow wiring

### Documentation
- `README.md`, `docs/RELIABILITY.md` now document the Emporium update step for Signum releases and point maintainers at `bash lib/release-smoke.sh`

### Fixed
- `/signum init` now treats root `ARCHITECTURE.md` as an authoritative input alongside legacy `docs/architecture.md`, so harness-generated architecture docs are actually read back by the scanner
- Claude overlay PACK parity test now follows the current `sync_contract_artifacts` implementation instead of the removed direct `cp` command
- Claude overlay runtime assets now include the helper scripts, schemas, agents, and review prompts that its packaged commands reference, instead of pointing at missing or stale copies

### Documentation
- `README.md` now clearly marks Signum as experimental / use-at-your-own-risk
- `QUICKSTART.md`, `docs/how-it-works.md`, and `docs/reference.md` were re-aligned with current behavior and mirrored into the Claude overlay docs

## [4.19.1] - 2026-04-20

### Fixed
- Durable contract/archive evidence now preserves the full execute receipt chain for replay and verification
  - `commands/signum.md` and `platforms/claude-code/commands/signum.md` now mirror/archive `execution_context.json`, `receipts/`, `runs/`, and `snapshots/` instead of only `receipts/execute.json`
  - `lib/contract-dir.sh` and `platforms/claude-code/lib/contract-dir.sh` now sync directories idempotently, avoiding nested `receipts/receipts`-style copies on repeated syncs
  - `tests/test-contract-dir.sh` and `platforms/claude-code/tests/test-contract-dir.sh` now cover directory evidence sync and re-sync behavior

## [4.19.0] - 2026-04-10

### Added
- Offline eval harness v1 for prompt/orchestration-sensitive changes
  - `evals/checks.py` — deterministic invariant grader for contract/audit/proofpack semantics
  - `evals/run.py` — snapshot runner for 6 representative fixtures with `--update-snapshots` support
  - `evals/fixtures/*.json` + `evals/snapshots/*.json` — committed eval corpus and reviewed golden outputs
  - `tests/test-eval-harness.sh` — shell coverage for the green path and broken-snapshot regression detection

### Documentation
- `README.md`, `docs/how-it-works.md`, and `docs/QUALITY_SCORE.md` — maintainer guidance for the new offline eval harness
- `docs/PLANS.md` — provider-alignment intake rule plus eval-harness-first planning note

## [4.18.1] - 2026-04-10

### Fixed
- Claude overlay PACK parity — `platforms/claude-code/commands/signum.md` now emits advisory `anti_entropy_report.json` under the active contract artifact root, advertises it in explain mode, syncs it to per-contract directories, and shows its summary in final output so `signumVersion` 4.18.x matches actual overlay behavior

## [4.18.0] - 2026-04-10

### Added
- `/signum init --harness` — deterministic harness-doc bootstrap on top of project context bootstrap
  - `lib/init-harness-scaffold.sh` — emits drafts for `AGENTS.md`, `ARCHITECTURE.md`, `docs/PLANS.md`, `docs/RELIABILITY.md`, `docs/SECURITY.md`, and `docs/QUALITY_SCORE.md`
  - `tests/test-init-harness-scaffold.sh` — validation for scaffold structure, content, and existing-file detection
  - Brownfield-safe behavior: if `project.intent.md` and `project.glossary.json` already exist, `--harness` preserves them and scaffolds only missing harness docs unless `--force` is also provided
- Anti-entropy Stage 1 report-only flow
  - `lib/anti-entropy-report.sh` — aggregates follow-up findings from cleanup evidence, `modules.yaml`, doc parity reports, and metric-ratchet reports
  - `lib/pack-anti-entropy.sh` — safe PACK wrapper that always writes `anti_entropy_report.json` under the active contract artifact root and never changes pipeline decision
  - `tests/test-anti-entropy-report.sh` and `tests/test-pack-anti-entropy.sh` — coverage for report generation and fallback artifact behavior

### Changed
- `commands/init.md` — documents `--harness` mode for root Signum init flow
- `platforms/claude-code/commands/init.md` — documents `--harness` mode for Claude overlay init flow; disallows `--actualize` + `--harness` in the MVP
- `commands/signum.md` — root PACK now emits advisory `anti_entropy_report.json` under the active contract artifact root after proofpack assembly and archives/cleans it with the rest of the working set

### Documentation
- `docs/reference.md` — canonical source policy now states root `commands/signum.md` is the source of truth and platform variants are overlays
- `docs/overlay-deviations.json` — machine-readable allowlist for intentional overlay differences (currently `RECONCILE` in Claude Code overlay)
- `lib/doc-parity-check.sh` + `tests/test-doc-parity.sh` + `.github/workflows/doc-parity.yml` — warn-only doc/parity validation
- `docs/plans/2026-03-15-large-project-support-roadmap.md` — roadmap statuses corrected for shipped Phase 1-5 capabilities; remaining debt now tracked separately
- `docs/how-it-works.md` and `README.md` — public docs synced to `init --harness`
- Added repo-level harness docs for Signum itself: `AGENTS.md`, `ARCHITECTURE.md`, `docs/PLANS.md`, `docs/RELIABILITY.md`, `docs/SECURITY.md`, `docs/QUALITY_SCORE.md`

## [4.17.0] - 2026-03-27

### Added
- **Verification-before-completion gate** (engineer) — 5-step gate: IDENTIFY/RUN/READ/VERIFY/LOG with mandatory evidence capture and red flags list
- **4-status reviewer protocol** — APPROVE_WITH_CONCERNS verdict + concerns[] field for documented-but-acceptable issues; synthesizer AUTO_OK accepts concerns with severity <= MINOR
- **Execute log schema v2** — timing (started_at/finished_at/duration_ms), error_type (transient/permanent), termination_reason, per-attempt status and timing, output + evidence fields
- **INTERRUPTED status** — engineer writes execute_log.json after every attempt; new status for mid-loop crashes
- **Contract injection scan** — lib/contract-injection-scan.sh defends against MINJA-class Unicode injection (zero-width, bidi overrides, tag characters) between contractor and engineer
- **Session context** — lib/session-manager.sh provides cross-run memory with typed entries (success/failure/scope_violation/model_disagreement) and TTL-based eviction; contractor reads session for improved contracts
- **Policy-driven model routing** — lib/policy-resolver.sh reads .signum/policy.toml for risk-based model overrides (e.g., high-risk -> opus engineer)
- **Failure taxonomy** — codex/gemini review failures classified as transient (timeout, rate_limit, provider_overloaded) vs permanent (auth_expired, adapter_crash) with failure_reason field
- **Proofpack chain** — lib/proofpack-index.sh appends hash-linked entries to .signum/proofpack-index.jsonl (tamper-evident audit trail)
- **Metric ratchet** — lib/metric-ratchet.sh computes weekly performance comparison (auto_ok_rate, confidence, etc.) from proofpack archive
- **Proofpack v4.8 schema** — timing, releaseVerdict, riskLevel, reviewCoverage fields for punk-run receipt compatibility

### Fixed
- **Contractor haiku fails on medium-risk** (#9) — orchestrator auto-retries with sonnet when haiku fails; maxTurns increased 12 -> 18
- **Engineer execute_log.json missing on partial completion** — CRITICAL note to write after every attempt + INTERRUPTED status
- **Scope gate broken with annotated paths** — strip parenthetical annotations from inScope, use while-read loop instead of for-in
- **Contract injection scan crashes on string assumptions** — handle both object ({text: ...}) and plain string formats

### Documentation
- docs/shared-receipt-mapping.md — field mapping between signum proofpack and specpunk receipt v1
- docs/thin-cli-extraction-plan.md — prioritized plan for extracting 15 bash scripts (~3200 LOC) to Rust signum-core crate
- lib/templates/policy.toml — example policy configuration

## [4.16.1] - 2026-03-23

## [4.16.0] - 2026-03-22

## [4.15.1] - 2026-03-22

## [4.15.0] - 2026-03-20

## [4.14.0] - 2026-03-20

## [4.13.0] - 2026-03-20

### Added
- **Receipt chain** — deterministic phase-boundary enforcement with append-only receipts (issue #7)
  - `lib/snapshot-tree.sh` — workspace tree snapshot before each engineer launch, captures sorted manifest + tree hash
  - `lib/boundary-verifier.sh` — runs AC verifiers via DSL runner after engineer returns, checks scope integrity (both out-of-scope and missing inScope), hashes artifacts, classifies evidence strength (observational/predicate/exit_only), writes append-only receipts under the active contract artifact root in `runs/<run_id>/`
  - `lib/transition-verifier.sh` — blocks execute→audit transition unless receipt is present, PASS, contract hash matches, artifact hashes valid, append-only chain intact, and all ACs have non-vacuous evidence
  - Orchestrator steps: 2.0.5 (pre-execute snapshot), 2.4.6 (scope existence gate), 2.5 (boundary verification), 2.6 (transition verification)
  - Iterative repair: fresh snapshot per attempt, boundary+transition verify per repair iteration, `RECEIPT_CHAIN_OK` flag prevents silent failure swallowing
  - Synthesizer: **Execute Receipt Coverage Gate** — AUTO_BLOCK when receipt missing, status != PASS, any AC without evidence, or vacuous evidence on medium/high risk. Overrides reviewer approval.
- **Vacuous verify detection** — boundary verifier classifies each AC verify block as `observational`, `predicate`, or `exit_only`. Exit-only blocked on medium/high risk contracts.
- **Scope existence gate** (Step 2.4.6) — verifies all non-glob `inScope` paths exist after engineer runs. Catches the incident class where files were promised in contract but never created.

### Changed
- **Policy scanner** — `TODO:`, `FIXME:`, `HACK:`, `XXX:` upgraded from MINOR to CRITICAL `incomplete_implementation`. Added `panic("not implemented")`, `raise NotImplementedError`, `throw new Error("TODO")` patterns. Non-code files (markdown, json, yaml, docs, examples, tests) excluded from incomplete_implementation rules.
- **Contractor prompt** — `verify.type: "manual"` forbidden. All ACs must use typed DSL with `steps`. Non-vacuous evidence required (must assert observable state via `expect.*` or predicates like `test`, `grep`, `jq -e`).
- **Engineer prompt** — receipt-chain paths (`receipts/`, `runs/`, `snapshots/`) under the active contract artifact root are declared verifier-owned, forbidden for engineer writes.
- **Archive mode** — preserves execute receipt before purging receipt chain intermediates.
- **`allowNewFilesUnder` scope strictness** — only permits file additions, not modifications or deletions of existing files under those paths.

### Security
- `dsl-runner.sh` resolved from trusted Signum install paths only (prevents workspace-local runner injection); workspace fallback requires explicit `SIGNUM_TRUST_LOCAL=1`
- `LC_ALL=C` enforced in all receipt chain scripts (prevents locale-dependent sort/join collation mismatches)
- `git ls-files -- .` constrains file listing to workspace root (monorepo-safe)
- Portable empty array expansion `${arr[@]+"${arr[@]}"}` for bash < 4.4 compatibility
- Receipt chain verifiers are hard gates — missing scripts cause `exit 1`, not silent degradation

## [4.12.1] - 2026-03-20

## [4.12.0] - 2026-03-19

### Added
- **Anti-entropy system** — module lifecycle tracking and cleanup contracts for combating code quality degradation in AI-assisted development
  - `modules.yaml` manifest + JSON Schema (`lib/schemas/modules.schema.json`) for declaring module lifecycle status (active/experimental/deprecated/removed)
  - Contract schema v3.8: `removals` array (RM01-pattern) for declarative file/directory deletion with `preventReintroduction` and `modulesYamlTransition`
  - Contract schema v3.8: `cleanupObligations` array (CO01-pattern) with K8s Finalizer semantics — blocking obligations prevent AUTO_OK
  - `file_not_exists` DSL assertion for verifying successful removals
  - `grep` added to DSL exec whitelist for reference-checking verify blocks
  - Contractor: steps 1.7 (modules.yaml reading), 3.7 (cleanup task detection), 3.7.5 (removal/obligation extraction with auto-verify generation)
  - Engineer: steps 2.5 (execute removals before implementation), 2.6 (execute cleanup obligations in repair loop)
  - Synthesizer: `removalVerification` + `obligationVerification` sections, AUTO_BLOCK on unfulfilled blocking obligations
  - Scope gate: removal target paths allowed as deletion targets
- **Proofpack v4.7** — `removalEvidence` section with per-removal filesystem state and per-obligation fulfillment tracking

## [4.11.0] - 2026-03-19

## [4.10.0] - 2026-03-18

### Added
- **Evidence coverage score** — new `evidenceCoverage` section in audit_summary.json tracking AC verification rate and file review coverage. Formula: `(verified/total * 60) + (reviewed/total * 40)`. AC ID normalization handles mismatched formats (ac-1 vs AC1).
- **Release verdict** — new `releaseVerdict` field (PROMOTE/HOLD/REJECT) alongside `decision`. Derived from decision + evidence coverage score. PROMOTE requires AUTO_OK + score >= 70.
- **Finding support level** — `supportLevel` (HIGH/MEDIUM/LOW) on each deduplicated finding, calculated as `confirmedBy.length / availableReviews`. Replaces absolute count with relative measure.
- **reviewedFiles[]** — new required field in all 3 review templates (general, security, performance). Lists every analyzed file including clean ones with no findings. Enables accurate file coverage tracking.

### Changed
- Synthesizer version bump to v4.9 in agent prompt

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
