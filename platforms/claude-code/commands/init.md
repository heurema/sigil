---
name: init
description: Bootstrap project context (project.intent.md and project.glossary.json) from an existing codebase using deterministic scan + LLM synthesis + interactive editing. Use --actualize to update existing intent against current code state. Use --harness to scaffold additional repo-level harness docs.
arguments:
  - name: flags
    description: "Optional: --force to overwrite existing files, --actualize to update existing intent with section-by-section diff, --harness to scaffold repo-level harness docs, --project-root <path> to specify target directory"
    required: false
---

# Signum Init: Project Context Bootstrapping

You are the Signum Init orchestrator. Bootstrap project context for a new or existing project.

The user's arguments: `$ARGUMENTS`

## Pipeline

```
SCAN → SYNTHESIZE → PRESENT → VERIFY
```

---

## Step 0: Parse Arguments

Parse `$ARGUMENTS`:
- If `--force` is present, set FORCE_MODE=true (overwrite existing files without prompting)
- If `--actualize` is present, set ACTUALIZE_MODE=true (update existing intent with section diff)
- If `--harness` is present, set HARNESS_MODE=true (scaffold repo-level harness docs)
- If `--project-root <path>` is present, use that path. Otherwise use current directory.
- If both `--force` and `--actualize` are present: error "Cannot combine --force and --actualize. Use --actualize for section-by-section updates." and stop.
- If both `--actualize` and `--harness` are present: error "Cannot combine --actualize and --harness in one run. Actualize intent first, then run /signum:init --harness." and stop.
- Any other argument: print usage and stop.

**Usage:**
```
/signum:init [--force] [--actualize] [--harness] [--project-root <path>]
```

For Claude Code plugin usage, `/signum:init` is the canonical form. `--harness` requires Signum `>= v4.18.0`.

---

## Step 1: SCAN (deterministic)

### 1a. Resolve Signum helper paths

Run:
```bash
resolve_signum_helper() {
  local helper="$1"
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/lib/${helper}" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/lib/${helper}"
    return 0
  fi
  if [ -f "lib/${helper}" ]; then
    printf '%s\n' "lib/${helper}"
    return 0
  fi
  echo "ERROR: Signum helper not found: ${helper}" >&2
  return 1
}

INIT_SCANNER_PATH=$(resolve_signum_helper "init-scanner.sh") || exit 1
INIT_HARNESS_SCAFFOLD_PATH=$(resolve_signum_helper "init-harness-scaffold.sh") || exit 1
printf 'INIT_SCANNER_PATH=%s\n' "$INIT_SCANNER_PATH"
printf 'INIT_HARNESS_SCAFFOLD_PATH=%s\n' "$INIT_HARNESS_SCAFFOLD_PATH"
```

Save the resolved helper paths as `INIT_SCANNER_PATH` and `INIT_HARNESS_SCAFFOLD_PATH`.

### 1b. Check for existing files

Run:
```bash
ls project.intent.md 2>/dev/null && echo "INTENT_EXISTS=true" || echo "INTENT_EXISTS=false"
ls project.glossary.json 2>/dev/null && echo "GLOSSARY_EXISTS=true" || echo "GLOSSARY_EXISTS=false"
```

If `HARNESS_MODE=true`, also run:
```bash
bash "$INIT_HARNESS_SCAFFOLD_PATH" --project-root "${PROJECT_ROOT:-.}" 2>/dev/null
```

Save this JSON as HARNESS_SCAFFOLD. It contains the additional harness-doc drafts plus `.missingCount` / `.existingCount`.

**If ACTUALIZE_MODE=true:**
- If `project.intent.md` does NOT exist: print error and STOP:
  ```
  actualize requires an existing project.intent.md. Run /signum:init first.
  ```
- If `project.glossary.json` does NOT exist: print warning "Glossary will be created fresh." and continue.
- Do NOT prompt about overwrite — actualize uses section-by-section confirmation.

**If FORCE_MODE=false AND ACTUALIZE_MODE=false:**
- If `HARNESS_MODE=true` AND **both** `project.intent.md` and `project.glossary.json` already exist:
  - Preserve the existing context files (do NOT regenerate them)
  - Scaffold only the harness docs whose `exists=false`
  - If `HARNESS_SCAFFOLD.missingCount == 0`, print:
    ```
    Harness docs already exist. No files written.
    ```
    and stop.
- Else if `project.intent.md` OR `project.glossary.json` already exists: print message and STOP:
  ```
  project.intent.md already exists.

  To overwrite, run: /signum:init --force
  To update with diff review, run: /signum:init --actualize
  ```

**If FORCE_MODE=true AND ACTUALIZE_MODE=false:**
- Continue with full overwrite (existing behavior).

### 1c. Run scanner

```bash
bash "$INIT_SCANNER_PATH" --project-root "${PROJECT_ROOT:-.}" 2>/dev/null
```

Save the output JSON as SCAN_SIGNALS. This contains all signals needed for synthesis.

Report to user:
```
SCAN complete. Found signals:
  - Authoritative docs: [yes/no]
  - CLAUDE.md: [yes/no]
  - README.md: [yes/no]
  - Package manifest: [yes/no]
  - Git history (6 months): [N commits]
  - Public entrypoints: [N found]
  - Existing glossary: [yes/no]
  - Existing intent: [yes/no]
  - Harness docs missing: [N]   (only when --harness)
  - Harness docs already present: [N]   (only when --harness)
```

---

## Step 2: SYNTHESIZE (LLM)

If `HARNESS_MODE=true`, harness docs come from `INIT_HARNESS_SCAFFOLD_PATH` (deterministic; do NOT ask the synthesizer to invent them).

If existing `project.intent.md` **and** `project.glossary.json` are both being preserved (harness-only brownfield mode), skip the synthesizer entirely.

Before passing SCAN_SIGNALS to the synthesizer, inject the mode:

**If ACTUALIZE_MODE=true:**
- Tell the synthesizer: "Run in actualize mode. The signals JSON contains existing intent in existingFiles.intent. Produce ACTUALIZE_DIFF output comparing existing sections against current signals. Do NOT produce full file drafts."

**Otherwise (full mode):**
- Tell the synthesizer: "Run in full mode. Produce complete project.intent.md and project.glossary.json drafts." (existing behavior)

Pass SCAN_SIGNALS to the init-synthesizer agent. The synthesizer will:
1. Apply source precedence hierarchy (docs/ > CLAUDE.md > README > package.json)
2. In full mode: generate full drafts with evidence comments and confidence annotations
3. In actualize mode: generate ACTUALIZE_DIFF with per-section status and proposed changes
4. Generate/merge `project.glossary.json` with canonicalTerms and aliases
5. Emit coverage summary

**Key rules enforced by synthesizer:**
- Non-Goals ONLY from explicit negative signals (ADRs rejected, README "Not supported", CLAUDE.md exclusions)
- Every section annotated with `<!-- evidence: ... -->` and `<!-- confidence: high|medium|low -->`
- Low confidence → TODO markers, not fabricated content
- Existing glossary terms preserved (merge-only)

---

## Step 3: PRESENT

### Full mode (default)

If brownfield preserve mode is active (`--harness` with existing intent + glossary), skip this section and use the harness-only presentation below.

Show the generated drafts to the user with a separator:

```
════════════════════════════════════════
DRAFT: project.intent.md
════════════════════════════════════════
[full generated content]

════════════════════════════════════════
DRAFT: project.glossary.json
════════════════════════════════════════
[full generated content]

════════════════════════════════════════
```

Then ask:
```
Review the drafts above.

Options:
  [1] Accept and write both files
  [2] Edit intent first, then write
  [3] Edit glossary first, then write
  [4] Accept intent only, skip glossary
  [5] Cancel (write nothing)

Enter choice (1-5):
```

Wait for user confirmation before writing any file.

If the user chooses to edit (options 2 or 3), open the draft for editing and present the revised version before final write.

On cancel (option 5): print "Cancelled. No files written." and stop.

### Harness mode (`--harness`, non-actualize only)

If brownfield preserve mode is active, show only the missing harness-doc drafts:

```
════════════════════════════════════════
DRAFT: AGENTS.md
════════════════════════════════════════
[content when exists=false]

...repeat for ARCHITECTURE.md, docs/PLANS.md, docs/RELIABILITY.md, docs/SECURITY.md, docs/QUALITY_SCORE.md when missing...

════════════════════════════════════════
```

Then ask:
```
Review the harness drafts above.

Options:
  [1] Accept and write missing harness docs
  [2] Cancel (write nothing)

Enter choice (1-2):
```

If full init + harness mode is active (fresh bootstrap with extra docs), show:
- the normal `project.intent.md` draft
- the normal `project.glossary.json` draft
- then each harness-doc draft from HARNESS_SCAFFOLD

Then ask:
```
Review the drafts above.

Options:
  [1] Accept and write all drafts
  [2] Edit intent first, then write selected files
  [3] Edit glossary first, then write selected files
  [4] Accept context files only, skip harness docs
  [5] Accept harness docs only, skip context files
  [6] Cancel (write nothing)

Enter choice (1-6):
```

Harness-doc drafts are deterministic templates. Do not ask the synthesizer to rewrite them unless the user explicitly asks for edits.

### Actualize mode

The synthesizer returns an ACTUALIZE_DIFF with one entry per section. Process sections in order:
**Goal → Core Capabilities → Non-Goals → Success Criteria → Personas**

First show the summary:
```
Actualize analysis:
  Sections unchanged: N
  Sections updated: N
  Sections added: N
  Glossary: +N terms, +M aliases

Reviewing changed sections...
```

**If ALL sections are UNCHANGED and glossary has no additions:** print "Everything up to date. No changes needed." and STOP without writing.

For each section from the ACTUALIZE_DIFF:

```
────────────────────────────────────────
Section: <Name>   [UNCHANGED | UPDATED | ADDED | REMOVED]
────────────────────────────────────────
```

**If UNCHANGED:** print "No changes. Auto-accepted." and move to next section. Do NOT prompt.

**If UPDATED:**
```
EXISTING:
<existing section content>

PROPOSED:
<new section content from signals>

Evidence: <source files>
Confidence: <high|medium|low>
Reason: <one sentence>

[a] Accept proposed  [k] Keep existing  [e] Edit proposed  [s] Skip
Choice:
```

**If ADDED:**
```
NEW SECTION (not in existing intent):
<proposed content>

Evidence: <source files>
Confidence: <high|medium|low>

[a] Accept  [s] Skip (omit section)
Choice:
```

**If REMOVED:**
```
EXISTING SECTION — signals no longer support this:
<existing content>
Reason: <synthesizer's explanation>

[r] Remove section  [k] Keep existing
Choice:
```

After all intent sections, show glossary changes:
```
────────────────────────────────────────
Glossary: +N terms, +M aliases
────────────────────────────────────────
[list new terms]
[a] Accept glossary additions  [s] Skip glossary
Choice:
```

Final confirmation:
```
Summary:
  Goal:               <unchanged/updated/added> (<accepted/kept>)
  Core Capabilities:  <unchanged/updated/added> (<accepted/kept>)
  Non-Goals:          <unchanged/updated/added> (<accepted/kept>)
  Success Criteria:   <unchanged/updated/added> (<accepted/kept>)
  Personas:           <unchanged/updated/added> (<accepted/kept>)
  Glossary:           +N terms (<accepted/skipped>)

[1] Write changes  [2] Cancel
Choice:
```

---

## Step 4: WRITE

After user confirms, write the files using the Write tool (NOT shell heredoc — prevents delimiter injection and symlink following):

For `project.intent.md`:
- First check: `[ -L project.intent.md ]` — if symlink, refuse and print: "ERROR: project.intent.md is a symlink. Refusing to overwrite for safety."
- **Full mode:** Use the Write tool to write the full synthesized content.
- Skip entirely when brownfield preserve mode is active or when the user chose "harness docs only"
- **Actualize mode:** Reconstruct the file by merging:
  - ACCEPTED sections: use proposed content from synthesizer (with fresh evidence comments)
  - KEPT/SKIPPED sections: use content from existing project.intent.md verbatim (including any existing comments)
  - EDITED sections: use user-edited content
  - Preserve the header line from existing file.
  - Section order follows the registry: Goal, Core Capabilities, Non-Goals, Success Criteria, Personas

For `project.glossary.json`:
- First check: `[ -L project.glossary.json ]` — if symlink, refuse and print: "ERROR: project.glossary.json is a symlink. Refusing to overwrite for safety."
- Skip entirely when brownfield preserve mode is active or when the user chose "harness docs only"
- Use the **Write** tool to write the synthesized/merged JSON to `project.glossary.json`

For harness docs from HARNESS_SCAFFOLD (`AGENTS.md`, `ARCHITECTURE.md`, `docs/PLANS.md`, `docs/RELIABILITY.md`, `docs/SECURITY.md`, `docs/QUALITY_SCORE.md`):
- Create parent directories first (at minimum `mkdir -p docs`)
- For each selected file:
  - If `[ -L <path> ]`, refuse and print: `"ERROR: <path> is a symlink. Refusing to overwrite for safety."`
  - If the file already exists AND `--force` was NOT provided, skip and print: `"Skipped existing: <path>"`
  - Otherwise use the **Write** tool to write the deterministic draft from HARNESS_SCAFFOLD

**Security notes:**
- NEVER use shell heredoc (`cat << EOF`) to write LLM-generated content — delimiter injection risk
- NEVER write to symlinks — prevents overwrite outside project root
- Always use the Write tool which writes atomically to the exact path

Print confirmation:
```
Written: project.intent.md
Written: project.glossary.json
Written: AGENTS.md
Written: ARCHITECTURE.md
Written: docs/PLANS.md
Written: docs/RELIABILITY.md
Written: docs/SECURITY.md
Written: docs/QUALITY_SCORE.md
```

---

## Step 5: VERIFY

Run coverage verification:

```bash
INTENT_GOALS=$(grep -c "^## Goal" project.intent.md 2>/dev/null || echo 0)
INTENT_CAPS=$(grep -c "^- " project.intent.md 2>/dev/null || echo 0)
INTENT_NG=$(grep -c "^## Non-Goals" project.intent.md 2>/dev/null || echo 0)

GLOSSARY_TERMS=$(python3 -c "
import json
d = json.load(open('project.glossary.json'))
terms = len(d.get('canonicalTerms', []))
aliases = len(d.get('aliases', {}))
print(f'{terms} terms, {aliases} aliases')
" 2>/dev/null || echo "0 terms, 0 aliases")

echo "Glossary has ${GLOSSARY_TERMS}"
echo "Intent covers: ${INTENT_GOALS} goal section, ${INTENT_CAPS} bullet points, ${INTENT_NG} non-goals section"
HARNESS_PRESENT=$(python3 -c "
from pathlib import Path
targets = [
  Path('AGENTS.md'),
  Path('ARCHITECTURE.md'),
  Path('docs/PLANS.md'),
  Path('docs/RELIABILITY.md'),
  Path('docs/SECURITY.md'),
  Path('docs/QUALITY_SCORE.md'),
]
print(sum(1 for p in targets if p.exists()))
" 2>/dev/null || echo 0)
echo \"Harness docs present: ${HARNESS_PRESENT}/6\"
```

Print VERIFY summary:
```
VERIFY complete:
  Glossary has N terms, M aliases
  Intent covers: 1 goal, N capabilities, N non-goals
  Harness docs present: N/6

Next steps:
  1. Review project.intent.md — edit sections marked TODO
  2. Review AGENTS.md / ARCHITECTURE.md / docs/*.md — replace TODOs with repo-specific facts
  3. Commit the generated files to your repository
  4. Contractor will now use project context automatically
```

---

## Error Handling

- If scanner fails: print error and stop (do not proceed to synthesize)
- If synthesis produces empty Goal: warn user, proceed with TODO placeholder
- If jq/python3 unavailable: skip verification step, still write files
- If project has no signals at all (no README, no manifest, no git): warn and emit minimal template with TODO markers throughout
- If actualize with no existing intent: error and stop (must run init first)
- If `INIT_HARNESS_SCAFFOLD_PATH` fails in `--harness` mode: print error and stop (do not synthesize partial state)

---

## Notes

- Files are written to project root (not `.signum/`)
- `--force` overwrites without prompting — use for full regeneration
- `--actualize` compares existing intent against current code signals — use for updates
- `--harness` scaffolds `AGENTS.md`, `ARCHITECTURE.md`, `docs/PLANS.md`, `docs/RELIABILITY.md`, `docs/SECURITY.md`, and `docs/QUALITY_SCORE.md`
- `--harness` cannot be combined with `--actualize` in this MVP
- The synthesizer never writes files — this command writes after user confirms
- Evidence comments (`<!-- evidence: ... -->`) are HTML comments, invisible in rendered markdown
- Low-confidence sections have TODO markers to guide manual editing
- In actualize mode, UNCHANGED sections are auto-accepted to keep the flow fast
