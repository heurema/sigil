# Signum Quickstart

Get from zero to a verified code change in 3 minutes.

## 1. Install

Signum is a Claude Code plugin. Install it:

```bash
claude plugin add heurema/signum
```

Verify:

```bash
claude /signum explain
```

## 2. Run Your First Pipeline

Give Signum a task:

```bash
claude "/signum Add a health check endpoint that returns {status: ok}"
```

Signum runs 4 phases automatically:

1. **CONTRACT** — Generates a verifiable spec from your request
2. **EXECUTE** — Implements code against the spec (with repair loop)
3. **AUDIT** — Reviews with up to 3 independent AI models
4. **PACK** — Bundles proof artifacts into `proofpack.json`

You approve the contract once. Everything else is autonomous.

## 3. Read the Proofpack

After a run, check the result:

```bash
jq '.decision, .confidence.overall' .signum/proofpack.json
```

Decisions:
- **AUTO_OK** — All checks passed. Review the diff and commit.
- **AUTO_BLOCK** — Issues found. Check `.signum/audit_summary.json`.
- **HUMAN_REVIEW** — Inconclusive. Review flagged findings manually.

## 4. Understand the Phases

| Phase | What happens | Duration |
|-------|-------------|----------|
| CONTRACT | AI generates spec + acceptance criteria + holdout tests | ~30s |
| EXECUTE | AI implements + runs repair loop (max 3 attempts) | 1-5 min |
| AUDIT | Mechanic checks + up to 3 model reviews + holdout validation | 1-3 min |
| PACK | Bundles all artifacts into signed proofpack | ~5s |

Key artifacts in `.signum/`:
- `contract.json` — The verified spec
- `combined.patch` — The code diff
- `mechanic_report.json` — Lint/typecheck/test results vs baseline
- `audit_summary.json` — Consensus decision with reasoning
- `proofpack.json` — Self-contained evidence bundle

## 5. Configure External Providers (Optional)

Signum uses Claude for the primary review. For multi-model audit, install:

```bash
# Codex CLI (security-focused review)
npm install -g @openai/codex

# Gemini CLI (performance-focused review)
npm install -g @google/gemini-cli
```

Override models via `~/.claude/emporium-providers.local.md`:

```yaml
---
defaults:
  codex:
    model: o4-mini
  gemini:
    model: gemini-2.5-pro
---
```

Risk-proportional audit:
- **Low risk** — Claude only (~$0.20, <2 min)
- **Medium risk** — Claude + available externals (3-5 min)
- **High risk** — Full 3-model panel (5-10 min)

## Next Steps

- Run `/signum` on a real task in your project
- Check `.signum/audit_summary.json` after a run to understand findings
- Use `lib/signum-ci.sh` to integrate into CI/CD
