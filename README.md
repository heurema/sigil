# Sigil

Risk-adaptive development pipeline with adversarial consensus code review for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## What It Does

4-phase pipeline that scales review rigor to match task complexity:

- **Scope** — deterministic precompute: branch creation, risk assessment, agent planning (zero LLM)
- **Explore** — codebase mapping with parallel sonnet agents
- **Design** — architecture doc with user approval gate (opus for medium/high risk)
- **Build** — implementation + test execution + observer + adversarial code review

3 review strategies, auto-selected by risk level:

| Strategy | When | Agents | Rounds | Codex |
|----------|------|--------|--------|-------|
| simple | low risk | 1 reviewer | 1 | fallback only |
| adversarial | medium risk | Reviewer + Skeptic (blind parallel) | 1 | no |
| consensus | high risk | Reviewer + Skeptic | 1-2 + tiebreaker | yes |

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) v2.1.47+
- `git` (initialized repo)
- `jq` (used for scope parsing and post-checks)
- Optional: [Codex CLI](https://github.com/openai/codex) for design review and tiebreaker

## Install

```bash
git clone https://github.com/Real-AI-Engineering/sigil.git ~/.claude/plugins/sigil
```

Then enable in `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "sigil@local": true
  }
}
```

If the file already exists, add `"sigil@local": true` inside the existing `enabledPlugins` object. Note: the key must be `enabledPlugins` (not `plugins`).

Verify: `ls ~/.claude/plugins/sigil/commands/sigil.md` should show the command file. Then open a new Claude Code session.

## Quick Start

```
/sigil add user authentication with JWT
```

The pipeline will:
1. Assess risk and create a feature branch
2. Explore the codebase with parallel agents
3. Design the implementation (requires your approval)
4. Build, test, review, and present a summary

## How It Works

```
┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Scope  │───>│ Explore  │───>│  Design  │───>│  Build   │
│ (bash)  │    │ (sonnet) │    │(son/opus)│    │ (sonnet) │
└─────────┘    └──────────┘    └──────────┘    └──────────┘
 risk=low:      1 agent         sonnet          1 impl
 risk=med:      2 agents        opus            2 impl + observer
 risk=high:     3 agents        opus            3 impl + observer + Codex
```

Each phase writes a structured artifact to `.dev/`:
- `scope.json` — risk level, agent counts, review strategy
- `exploration.md` — codebase map, patterns, constraints
- `design.md` — architecture, files, test plan, risks
- `review-verdict.md` + `review-summary.json` — review results

Post-checks validate each artifact before proceeding.

## Review Strategies

**Simple** — single code reviewer. Fast, cheap. Auto-selected for low-risk changes.

**Adversarial** — two agents review the same diff blind:
- *Reviewer*: finds code bugs, security issues, logic errors
- *Skeptic*: finds spec gaps, missing tests, hallucinated functionality
- Findings machine-validated (file exists, line range, evidence grep, scope check)
- Deduplication across agents

**Consensus** — adversarial + escalation:
- If Reviewer and Skeptic disagree (PASS vs BLOCK), Round 2 runs
- Both agents re-review with merged findings
- Codex CLI acts as tiebreaker if still blocked

## Cost Estimates

| Strategy | Agents | Est. Cost | Latency |
|----------|--------|-----------|---------|
| simple | 1 | ~$0.03-0.05 | 1-2 min |
| adversarial | 2 | ~$0.10-0.20 | 3-5 min |
| consensus | 2-4 + Codex | ~$0.20-0.40 | 5-10 min |

Costs are approximate and depend on diff size and codebase complexity.

## Optional: Codex Integration

Sigil optionally uses [Codex CLI](https://github.com/openai/codex) for:
- **Design review** (high risk) — independent second opinion on architecture
- **Tiebreaker** (consensus) — breaks deadlock between Reviewer and Skeptic
- **Fallback reviewer** (simple) — when primary reviewer agent is unavailable

If Codex is not installed, Sigil degrades gracefully — all Codex steps are skipped with a logged reason. The `codex_status` field in `.dev/review-summary.json` tracks what happened: `ok`, `not_installed`, `auth_expired`, `timeout`, `error`, or `skipped`.

Install Codex: `npm install -g @openai/codex`

## Session Resume

If you interrupt a `/sigil` session, the pipeline detects existing `.dev/` artifacts on restart and offers:
- **resume** — continue from the next incomplete phase
- **restart** — clear artifacts, start fresh
- **abort** — stop

Run history is archived to `.dev/runs/<timestamp>/` after each completed build.

## Security Notes

- `.dev/` artifacts (including `review-diff.txt`) contain your full git diff. The pipeline adds `.dev/` to your project's `.gitignore` automatically (Step 0.1) — but verify this before committing.
- Review agents analyze code content via LLM prompts. When reviewing untrusted codebases, be aware that malicious code could attempt prompt injection. The multi-agent architecture and evidence validation provide defense-in-depth but are not immune.
- Codex integration sends design docs and diffs to an external service. Use `review=simple` or `review=adversarial` to avoid Codex calls, or uninstall Codex CLI.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `jq: command not found` | Install jq: `brew install jq` (macOS) or `apt install jq` (Linux) |
| `codex: auth expired` | Run `codex auth` to refresh credentials |
| `.dev/` exists from previous run | `/sigil` detects this and offers resume/restart/abort |
| Plugin not loading | Verify: `ls ~/.claude/plugins/sigil/commands/sigil.md` exists and `"sigil@local": true` in `~/.claude/settings.json` `enabledPlugins` |

## Configuration (v2 Roadmap)

Coming in v2:
- `.sigil.json` project overrides (custom risk thresholds, review strategy, agent counts)
- Configurable timeouts and cost limits

## See Also

Other [Real-AI-Engineering](https://github.com/Real-AI-Engineering) projects:

- **[herald](https://github.com/Real-AI-Engineering/herald)** — daily curated news digest plugin for Claude Code
- **[teams-field-guide](https://github.com/Real-AI-Engineering/teams-field-guide)** — comprehensive guide to Claude Code multi-agent teams
- **[codex-partner](https://github.com/Real-AI-Engineering/codex-partner)** — using Codex CLI as second AI alongside Claude Code
- **[proofpack](https://github.com/Real-AI-Engineering/proofpack)** — proof-carrying CI gate for AI agent changes

## License

MIT
