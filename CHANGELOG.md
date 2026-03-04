# Changelog

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

### Planned (v4.1)
- Multi-path execution: parallel implementation strategies with winner selection via worktree isolation

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
