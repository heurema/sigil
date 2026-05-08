# Signum Quickstart

Get from zero to a verified code change in 3 minutes.

## 1. Install

Signum is available as a Claude Code plugin and ships Codex App plugin metadata.

For Claude Code, install it:

```bash
claude plugin marketplace add heurema/emporium
claude plugin install signum@emporium
```

Verify:

```bash
claude "/signum explain"
```

For Codex App, install Signum from a Codex plugin marketplace entry that points at the plugin package. The install manifest lives at `.codex-plugin/plugin.json` and exposes the `signum` skill from `platforms/codex/SKILL.md`.

Example Codex marketplace entry:

```json
{
  "name": "signum",
  "source": {
    "source": "local",
    "path": "./plugins/signum"
  },
  "policy": {
    "installation": "AVAILABLE",
    "authentication": "ON_INSTALL"
  },
  "category": "Coding"
}
```

## 2. Run Your First Pipeline

Give Signum a task:

```bash
claude "/signum Add a health check endpoint that returns {status: ok}"
```

In Codex App, use the skill-oriented prompt form:

```text
Use Signum to add a health check endpoint that returns {status: ok}
```

Signum runs 4 phases automatically:

1. **CONTRACT** — Generates a verifiable spec from your request
2. **EXECUTE** — Implements code against the spec (with repair loop)
3. **AUDIT** — Reviews with up to 3 independent AI models
4. **PACK** — Bundles proof artifacts into `proofpack.json` and writes advisory `anti_entropy_report.json` under the active contract artifact root

You approve the contract once. Everything else is autonomous.

## 3. Read the Proofpack

After a run, check the result under the active contract artifact root that Signum prints at the end of the run:

```bash
ARTIFACT_ROOT=".signum/contracts/<contractId>"
jq '.decision, .confidence.overall' "$ARTIFACT_ROOT/proofpack.json"
```

Decisions:
- **AUTO_OK** — All checks passed. Review the diff and commit.
- **AUTO_BLOCK** — Issues found. Check `audit_summary.json` under the active contract artifact root.
- **HUMAN_REVIEW** — Inconclusive. Review flagged findings manually.

Optional follow-up:
- `jq '.status, .summary' "$ARTIFACT_ROOT/anti_entropy_report.json"` — advisory cleanup / anti-drift findings

## 4. Understand the Phases

| Phase | What happens | Duration |
|-------|-------------|----------|
| CONTRACT | AI generates spec + acceptance criteria + holdout tests | ~30s |
| EXECUTE | AI implements + runs repair loop (max 3 attempts) | 1-5 min |
| AUDIT | Mechanic checks + up to 3 model reviews + holdout validation | 1-3 min |
| PACK | Bundles all artifacts into signed proofpack | ~5s |

Key artifacts under the active contract artifact root (`.signum/contracts/<contractId>/`):
- `contract.json` — The verified spec
- `combined.patch` — The code diff
- `mechanic_report.json` — Lint/typecheck/test results vs baseline
- `audit_summary.json` — Consensus decision with reasoning
- `proofpack.json` — Self-contained evidence bundle
- `anti_entropy_report.json` — Advisory follow-up findings (non-blocking)

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

## 6. Set Up Your Project (Recommended)

Signum works without any setup — just run `/signum "task"`. But for best results in existing projects, add these optional files:

### project.intent.md (recommended)

Tells the contractor what your project is about. Without it, medium/high-risk tasks trigger a blocking question.

```bash
cat > project.intent.md << 'EOF'
# <Project Name> — Project Intent

## Goal
<1-2 sentences: what this project does>

## Core Capabilities
- <capability 1>
- <capability 2>

## Non-Goals
- <what this project does NOT do>

## Success Criteria
- <measurable outcome 1>
- <measurable outcome 2>
EOF
```

The contractor reads this before generating contracts — non-goals flow into `outOfScope`, terms into acceptance criteria language.

### project.glossary.json (optional)

Enforces consistent terminology. The glossary check warns when contracts use forbidden synonyms.

```bash
cat > project.glossary.json << 'EOF'
{
  "version": "1.0.0",
  "canonicalTerms": ["your", "canonical", "terms"],
  "aliases": {
    "forbidden-synonym": "canonical-term"
  }
}
EOF
```

### modules.yaml (optional)

Declares module lifecycle status. Enables cleanup contracts with structured removals.

```bash
cat > modules.yaml << 'EOF'
version: 1
modules:
  - path: src/api/
    name: api
    status: active
    owner: "@you"
  - path: src/old-api/
    name: old-api
    status: deprecated
    deprecated_since: "2026-03-01"
    remove_after: "2026-04-01"
    replaced_by: src/api/
    reason: "Replaced by v2 API"
EOF
```

When you run `/signum "remove the old-api module"`, the contractor reads `modules.yaml`, generates `removals` and `cleanupObligations` entries, and the engineer deletes files + cleans up references in a single verified pass.

### repo-contract.json (optional)

Invariants that must always hold. Any regression is AUTO_BLOCK regardless of task.

```bash
cat > repo-contract.json << 'EOF'
{
  "schemaVersion": "1.0",
  "invariants": [
    { "id": "I-1", "description": "All tests pass", "verify": "npm test", "severity": "critical" },
    { "id": "I-2", "description": "No lint errors", "verify": "npm run lint", "severity": "high" }
  ],
  "owner": "human"
}
EOF
```

### First run checklist

1. `cd your-project`
2. Create `project.intent.md` (or skip — Signum will ask)
3. Run: `/signum "describe your first task"`
4. Review the contract when prompted (5-item checklist)
5. Check `proofpack.json` under the active contract artifact root for the result
6. Optionally check `anti_entropy_report.json` there for follow-up hygiene work

`.signum/` is auto-added to `.gitignore`. No cleanup needed.

## Next Steps

- Run `/signum` on a real task in your project
- Check `audit_summary.json` under the active contract artifact root after a run to understand findings
- Add `repo-contract.json` for project-wide invariant enforcement
