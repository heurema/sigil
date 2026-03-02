# Changelog

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
