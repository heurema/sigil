---
status: draft
owner: @vi
last_reviewed: 2026-04-10
review_cadence: quarterly
---

# signum — Security

## Trust Boundaries
- **Local deterministic boundary**: shell scripts in `lib/`, schemas, proofpack assembly, receipt logic.
- **Claude Code / LLM orchestration boundary**: `commands/` and `agents/` define what context goes to contractor/engineer/reviewer agents.
- **External provider boundary**: current docs state Codex CLI and Gemini CLI receive the diff only, not the full codebase.
- **Plugin/install boundary**: plugin metadata and install surfaces live under `.claude-plugin/` for Claude Code and `.agents/plugins/marketplace.json`, `.codex-plugin/`, plus `platforms/codex/.codex-plugin/` and `platforms/codex/SKILL.md` for Codex App.

## Sensitive Surfaces

| Surface | Why sensitive |
| --- | --- |
| `lib/dsl-runner.sh` | Executes verify DSL primitives; command surface must stay constrained |
| `lib/policy-scanner.sh` / `lib/policy-resolver.sh` | Enforces execution policy and denied command patterns |
| `lib/contract-injection-scan.sh` | Guards against contract/prompt injection input |
| `commands/signum.md` and `agents/*.md` | Control what context and instructions reach models |
| `.agents/plugins/marketplace.json`, `.codex-plugin/plugin.json`, and `platforms/codex/.codex-plugin/plugin.json` | Control how Codex App discovers and installs the plugin |
| `lib/schemas/*.json` | Define structured inputs/outputs trusted by the pipeline |

## Existing Controls
- Holdouts are physically removed from `contract-engineer.json`; they are not hidden only by prompt text.
- Execution policy is derived into `contract-policy.json` before EXECUTE and enforced after execution.
- The README documents a whitelisted `exec` surface in the verify DSL.
- Pre-commit hooks include:
  - `gitleaks`
  - `detect-private-key`
  - `check-added-large-files`
- `lib/contract-injection-scan.sh` exists as a dedicated deterministic defense layer.

## Secrets and Data Handling
- Current public docs say Signum does not phone home and does not add telemetry/analytics.
- Artifacts are written to `.signum/` locally.
- External review providers are documented as diff-only recipients.
- Do not add test fixtures, prompts, or docs that contain real credentials or tokens.

## Security Review Triggers
- Any change to `lib/dsl-runner.sh`
- Any change to `lib/policy-scanner.sh`, `lib/policy-resolver.sh`, or `lib/contract-injection-scan.sh`
- Any schema change under `lib/schemas/`
- Any change that widens what external providers receive
- Any change that modifies holdout blinding or execution-policy enforcement semantics

## Minimum Security Evidence for Sensitive Changes
- Add or update a deterministic test when the security-relevant script behavior changes.
- Update docs/reference if the externally visible contract or trust boundary changes.
- Avoid “silent” overlay-only security behavior changes; document them explicitly if unavoidable.
