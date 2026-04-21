# Phase 1: Project Intent Layer — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add project.intent.md support so the Signum contractor reads project-level intent before generating task contracts, with schema extension, alignment checks, and audit trail.

**Architecture:** Extend contract.schema.json v3.2→v3.3 with `contextInheritance` block. Contractor reads `project.intent.md` from target project root, sets `projectRef` + SHA-256 hash, blocks medium/high risk if missing. New LLM-based intent alignment check (medium/high risk only). All changes flow through to contract-engineer.json and proofpack.

**Tech Stack:** JSON Schema (draft-07), Markdown, Bash/jq, Claude Code agent prompts

**Spec:** `docs/plans/2026-03-15-phase1-project-intent-layer-design.md`

---

## Chunk 1: Schema + Contractor

### Task 1: Update contract.schema.json

**Files:**
- Modify: `lib/schemas/contract.schema.json`

- [ ] **Step 1: Add "3.3" to schemaVersion enum**

In `lib/schemas/contract.schema.json`, change line 12:
```json
"schemaVersion": { "type": "string", "enum": ["3.0", "3.1", "3.2", "3.3"] },
```

- [ ] **Step 2: Replace if/then block to cover 3.2 AND 3.3**

Replace lines 5-10 (the `if/then` block):
```json
"if": {
  "properties": { "schemaVersion": { "enum": ["3.2", "3.3"] } }
},
"then": {
  "required": ["contractId", "status", "timestamps"]
},
```

- [ ] **Step 3: Add contextInheritance property**

Add after the `relatedContractIds` property (before the closing `}` of `properties`):
```json
"contextInheritance": {
  "type": "object",
  "properties": {
    "projectRef": {
      "type": ["string", "null"],
      "description": "Path or status: string path=loaded, 'not_found'=checked but missing, null=explicit waiver, absent=legacy"
    },
    "projectIntentSha256": {
      "type": "string",
      "description": "SHA-256 of project.intent.md contents at contract creation time"
    }
  },
  "additionalProperties": true
}
```

- [ ] **Step 4: Validate schema is valid JSON**

Run: `python3 -c "import json; json.load(open('lib/schemas/contract.schema.json')); print('VALID')"`
Expected: `VALID`

- [ ] **Step 5: Verify backward compat — existing fixture validates**

Run: `python3 -c "
import json
schema = json.load(open('lib/schemas/contract.schema.json'))
# Check 3.2 is still in enum
assert '3.2' in schema['properties']['schemaVersion']['enum']
assert '3.3' in schema['properties']['schemaVersion']['enum']
# Check if/then covers both
assert schema['if']['properties']['schemaVersion']['enum'] == ['3.2', '3.3']
print('BACKWARD_COMPAT_OK')
"`
Expected: `BACKWARD_COMPAT_OK`

- [ ] **Step 6: Commit**

```bash
git add lib/schemas/contract.schema.json
git commit -m "feat: bump contract schema to v3.3, add contextInheritance"
```

---

### Task 2: Update contractor agent

**Files:**
- Modify: `agents/contractor.md`

- [ ] **Step 1: Update schemaVersion from 3.2 to 3.3**

Change line 36 from `"3.2"` to `"3.3"`:
```
   - `schemaVersion`: always `"3.3"` for new contracts
```

- [ ] **Step 2: Add Step 1.5 — Read project intent**

After the `## Process` section, step 1 ("Parse request"), add:

```markdown
1.5. **Read project intent** (before scan):
   - Check if `PROJECT_ROOT/project.intent.md` exists
   - If exists: read it, extract Goal, Core Capabilities, Non-Goals, Glossary
   - If missing: note absence, continue to step 2 (decision deferred to step 3.5)
```

- [ ] **Step 3: Add Step 3.5 — Project intent gate**

After step 3 ("Assess risk"), add:

```markdown
3.5. **Project intent gate** (after risk assessment):
   - If project.intent.md was found:
     - Set `contextInheritance.projectRef` = `"project.intent.md"`
     - Compute SHA-256 of file contents, set `contextInheritance.projectIntentSha256`
     - Use project non-goals to populate `outOfScope` if user didn't specify
     - Use glossary terms in acceptance criteria language
   - If project.intent.md was NOT found AND riskLevel >= medium:
     - Add to openQuestions: `"[INTENT_WAIVER] Project intent not defined. Create project.intent.md at repo root, or reply 'proceed without project context' to continue."`
     - Set `requiredInputsProvided` = false
   - If project.intent.md was NOT found AND riskLevel = low:
     - Set `contextInheritance.projectRef` = `"not_found"`
   - **Waiver detection** (when re-launched with user answers):
     1. Find the answer to the open question containing `[INTENT_WAIVER]`
     2. If affirmative ("yes", "proceed without project context", "yes, proceed" — case-insensitive):
        - Set `contextInheritance.projectRef` = null, remove the question
     3. If negative ("no", "do not proceed", "don't" — case-insensitive):
        - Keep the question, keep `requiredInputsProvided` = false
     4. The `[INTENT_WAIVER]` marker ensures matching only this specific question, not other open questions
```

- [ ] **Step 4: Add contextInheritance to Generate contract step**

In step 4 ("Generate contract.json"), add `contextInheritance` to the field list:
```
   - contextInheritance (projectRef, projectIntentSha256 — set in step 3.5)
```

- [ ] **Step 5: Commit**

```bash
git add agents/contractor.md
git commit -m "feat: contractor reads project.intent.md, sets contextInheritance"
```

---

### Task 3: Update orchestrator — open questions + contract-engineer whitelist

**Files:**
- Modify: `commands/signum.md`

- [ ] **Step 0: Note Step 1.2 validation — no change needed**

Step 1.2 validates `schemaVersion, goal, inScope, acceptanceCriteria, riskLevel`. `contextInheritance` is optional — existing validation passes without it. No code change needed, but confirm by reading the validation jq command (~line 389) to verify it won't reject contracts with unknown fields.

Assume the active contract artifact root is already resolved and these canonical paths are available in the orchestration snippets below:
```bash
CONTRACT_PATH="$ARTIFACT_ROOT/contract.json"
INTENT_CHECK_PATH="$ARTIFACT_ROOT/intent_check.json"
```

- [ ] **Step 1: Add intent_check.json to setup cleanup list**

Find the setup cleanup block (~line 355 in the original draft) and add the canonical intent-check artifact:
```bash
       "$INTENT_CHECK_PATH" \
```

- [ ] **Step 2: Add intent_check.json to archive mode purge list**

Find the archive mode `rm -f` block (~line 108, uses `${DIR}` variable) and add:
```bash
      "${DIR}intent_check.json" \
```
Note: this block uses `${DIR}` (per-contract directory path). The setup cleanup block (~line 355) uses `.signum/` prefix directly. Use the correct prefix for each block.

- [ ] **Step 3: Update contract-engineer.json jq whitelist**

Find the jq command that creates contract-engineer.json (~line 933). Add `contextInheritance` to the whitelist:
```jq
{
  schemaVersion, contractId, status, timestamps, goal, inScope, allowNewFilesUnder, outOfScope,
  acceptanceCriteria: [.acceptanceCriteria[] | select(.visibility != "holdout")],
  assumptions, openQuestions, riskLevel, riskSignals, requiredInputsProvided,
  contextInheritance
} | with_entries(select(.value != null))
```

- [ ] **Step 4: Verify PACK phase preserves contextInheritance**

Read the PACK phase in `commands/signum.md` (~line 1785). The redacted contract for proofpack is built from `contract-engineer.json` (which now includes `contextInheritance` via our whitelist update). Confirm that the PACK code reads from `contract-engineer.json` or `contract.json` — no additional change needed if so. If PACK has its own field whitelist, add `contextInheritance` there too.

- [ ] **Step 5: Commit**

```bash
git add commands/signum.md
git commit -m "feat: orchestrator cleanup + contract-engineer whitelist for contextInheritance"
```

---

## Chunk 2: Intent Alignment Check + Display

### Task 4: Add Step 1.3.6 — intent alignment check

**Files:**
- Modify: `commands/signum.md`

- [ ] **Step 1: Add new Step 1.3.6 section**

After Step 1.3.5 (spec quality gate + prose check) and before Step 1.3.7 (multi-model spec validation), add:

````markdown
### Step 1.3.6: Intent alignment check (informational, medium/high risk only)

**Skip if `riskLevel` is `low`.** Low-risk tasks don't benefit from LLM alignment checks.

Check if contract has a project intent reference:

```bash
PROJECT_REF=$(jq -r '.contextInheritance.projectRef // "absent"' "$CONTRACT_PATH")
RISK=$(jq -r '.riskLevel' "$CONTRACT_PATH")
if [ "$RISK" = "low" ] || [ "$PROJECT_REF" = "absent" ] || [ "$PROJECT_REF" = "null" ] || [ "$PROJECT_REF" = "not_found" ]; then
  echo "Intent alignment check: skipped (risk=$RISK, projectRef=$PROJECT_REF)"
else
  echo "Running intent alignment check against $PROJECT_REF..."
fi
```

If not skipped, read project.intent.md and launch a sonnet subagent:

```
You are checking whether a task contract aligns with its project's stated intent.

Project intent:
<contents of project.intent.md from PROJECT_ROOT>

Contract:
Goal: <contract goal>
Out of scope: <contract outOfScope>
Acceptance criteria: <AC descriptions>

Check:
1. Does the contract goal relate to the project's stated goal or core capabilities?
2. Does the contract scope overlap with any project non-goals?
3. Does the contract use terminology inconsistent with the project glossary?

Output JSON only:
{
  "aligned": true|false,
  "concerns": ["<concern 1>", ...],
  "glossary_violations": ["<used 'X' but glossary says use 'Y'>", ...]
}
```

Parse the subagent response as JSON. If parsing fails, write safe default:
`{"aligned": null, "concerns": [], "glossary_violations": [], "parse_error": true}`

Write result to `$INTENT_CHECK_PATH`.
````

- [ ] **Step 2: Commit**

```bash
git add commands/signum.md
git commit -m "feat: add intent alignment check (Step 1.3.6, medium/high risk)"
```

---

### Task 5: Update Step 1.4 — display projectRef + intent warnings

**Files:**
- Modify: `commands/signum.md`

- [ ] **Step 1: Add projectRef display after risk signals**

Final display order in Step 1.4 should be:
1. Goal, Risk, In scope, ACs, Holdouts (existing)
2. Spec quality score (existing)
3. **Project intent status** (NEW — insert here)
4. Spec validation findings from codex/gemini (existing)
5. Clover reconstruction test (existing)
6. **Intent alignment results** (NEW — insert here, after clover)
7. Approval checklist (existing)

Find Step 1.4 display section (~line 836, after riskSignals display). Add:

```bash
# Show project intent status
if jq -e '.contextInheritance.projectRef' "$CONTRACT_PATH" >/dev/null 2>&1; then
  PROJECT_REF=$(jq -r '.contextInheritance.projectRef' "$CONTRACT_PATH")
  if [ "$PROJECT_REF" = "not_found" ]; then
    echo "Project intent: not found (low risk, continued)"
  else
    echo "Project intent: $PROJECT_REF (loaded)"
  fi
elif jq -e '.contextInheritance | has("projectRef")' "$CONTRACT_PATH" >/dev/null 2>&1; then
  echo "Project intent: waived by user"
fi
```

- [ ] **Step 2: Add intent check results display**

After clover results display, add:

```bash
# Show intent alignment results
if [ -f "$INTENT_CHECK_PATH" ]; then
  ALIGNED=$(jq -r '.aligned // "null"' "$INTENT_CHECK_PATH")
  PARSE_ERR=$(jq -r '.parse_error // false' "$INTENT_CHECK_PATH")
  CONCERNS=$(jq -r '.concerns | length' "$INTENT_CHECK_PATH")
  if [ "$PARSE_ERR" = "true" ] || [ "$ALIGNED" = "null" ]; then
    echo "Intent alignment: skipped (check failed)"
  elif [ "$ALIGNED" = "false" ] || [ "$CONCERNS" -gt 0 ]; then
    echo ""
    echo "--- Intent alignment WARNING ---"
    jq -r '.concerns[]' "$INTENT_CHECK_PATH" | sed 's/^/  - /'
    GLOSSARY_V=$(jq -r '.glossary_violations | length' "$INTENT_CHECK_PATH")
    if [ "$GLOSSARY_V" -gt 0 ]; then
      echo "Glossary violations:"
      jq -r '.glossary_violations[]' "$INTENT_CHECK_PATH" | sed 's/^/  - /'
    fi
  else
    echo "Intent alignment: OK"
  fi
fi
```

- [ ] **Step 3: Update explain mode JSON**

Find the explain mode JSON output (~line 33). Update CONTRACT steps:
```json
"steps": ["contractor agent", "spec quality gate (7 dimensions)", "prose checks", "intent alignment check", "multi-model spec validation", "clover reconstruction test", "human approval"],
```

- [ ] **Step 4: Commit**

```bash
git add commands/signum.md
git commit -m "feat: display projectRef + intent alignment warnings in contract summary"
```

---

## Chunk 3: Docs + Platform Sync + Tests

### Task 6: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/reference.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Fix README "six dimensions" → "seven dimensions"**

Find line ~66 in README.md. Change "six dimensions" to "seven dimensions".

- [ ] **Step 2: Add project intent mention to README**

After the "Holdout scenarios" feature paragraph, add:
```markdown
**Project intent alignment** — If the target project has a `project.intent.md` at its root, the contractor reads it before generating contracts. Non-goals and glossary terms flow into contract scope and terminology. For medium/high-risk tasks, missing project intent triggers a blocking question. An LLM-based alignment check warns when the contract diverges from project goals.
```

- [ ] **Step 3: Add contextInheritance to README contract fields table**

If README.md has a contract.json fields table (check near line 74+), add:
```markdown
| `contextInheritance.projectRef` | string\|null | Project intent reference |
| `contextInheritance.projectIntentSha256` | string | Hash of project.intent.md at contract creation |
```

- [ ] **Step 4: Update docs/reference.md contract fields table**

Add to the contract.json fields table:
```markdown
| `contextInheritance` | object | Project context references (optional) |
| `contextInheritance.projectRef` | string\|null | Path to project.intent.md, "not_found", null (waiver), or absent (legacy) |
| `contextInheritance.projectIntentSha256` | string | SHA-256 of project.intent.md at contract creation |
```

Update schemaVersion row from `"3.0"` to `"3.0"–"3.3"`.

- [ ] **Step 4: Add CHANGELOG entry**

Add at the top of CHANGELOG.md:
```markdown
## [4.2.0] - 2026-03-15

### Added
- Project intent layer: contractor reads `project.intent.md` from target project root
- `contextInheritance` block in contract schema v3.3 (projectRef, projectIntentSha256)
- Intent alignment check (LLM-based, medium/high risk, informational)
- Missing project intent blocks medium/high risk tasks with escapable question
```

- [ ] **Step 6: Commit**

```bash
git add README.md docs/reference.md CHANGELOG.md
git commit -m "docs: project intent layer, fix dimensions count, update reference"
```

---

### Task 7: Platform sync

**Files:**
- Copy: `agents/contractor.md` → `platforms/claude-code/agents/contractor.md`
- Copy: `commands/signum.md` → `platforms/claude-code/commands/signum.md`
- Copy: `lib/schemas/contract.schema.json` → `platforms/claude-code/lib/schemas/contract.schema.json`

- [ ] **Step 1: Copy all modified files to platforms/claude-code/**

```bash
cp agents/contractor.md platforms/claude-code/agents/contractor.md
cp commands/signum.md platforms/claude-code/commands/signum.md
cp lib/schemas/contract.schema.json platforms/claude-code/lib/schemas/contract.schema.json
```

- [ ] **Step 2: Verify copies are identical**

```bash
diff agents/contractor.md platforms/claude-code/agents/contractor.md && echo "contractor: OK"
diff commands/signum.md platforms/claude-code/commands/signum.md && echo "signum: OK"
diff lib/schemas/contract.schema.json platforms/claude-code/lib/schemas/contract.schema.json && echo "schema: OK"
```
Expected: all three print OK with no diff output.

- [ ] **Step 3: Commit**

```bash
git add platforms/claude-code/
git commit -m "chore: sync platforms/claude-code with root"
```

---

### Task 8: Add test fixture for schema v3.3

**Files:**
- Create: `tests/fixtures/contract-v3.3-with-intent.json`

- [ ] **Step 1: Create a v3.3 contract fixture with contextInheritance**

```bash
cat > tests/fixtures/contract-v3.3-with-intent.json << 'EOF'
{
  "schemaVersion": "3.3",
  "contractId": "sig-20260315-test",
  "status": "draft",
  "timestamps": {"createdAt": "2026-03-15T10:00:00Z"},
  "goal": "Test contract with project intent support",
  "inScope": ["tests/fixtures/"],
  "acceptanceCriteria": [
    {"id": "AC1", "description": "contextInheritance is preserved", "visibility": "visible",
     "verify": {"type": "manual", "value": "check contextInheritance in output"}}
  ],
  "riskLevel": "low",
  "contextInheritance": {
    "projectRef": "project.intent.md",
    "projectIntentSha256": "abc123def456"
  }
}
EOF
```

- [ ] **Step 2: Validate fixture against schema**

```bash
python3 -c "
import json
contract = json.load(open('tests/fixtures/contract-v3.3-with-intent.json'))
assert contract['schemaVersion'] == '3.3'
assert contract['contextInheritance']['projectRef'] == 'project.intent.md'
assert 'projectIntentSha256' in contract['contextInheritance']
print('FIXTURE_VALID')
"
```
Expected: `FIXTURE_VALID`

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/contract-v3.3-with-intent.json
git commit -m "test: add v3.3 contract fixture with contextInheritance"
```

---

### Task 9: Run existing tests

**Files:**
- Read: `tests/test-prose-check.sh`
- Read: `tests/test-contract-dir.sh`
- Read: `tests/test-signum-ci.sh`
- Read: `tests/dsl-runner/test-e2e.sh`

- [ ] **Step 1: Run all existing test suites**

```bash
bash tests/test-prose-check.sh && echo "prose: PASS"
bash tests/test-contract-dir.sh && echo "contract-dir: PASS"
bash tests/test-signum-ci.sh && echo "ci: PASS"
bash tests/dsl-runner/test-e2e.sh && echo "dsl-runner: PASS"
```
Expected: all PASS. No existing tests should break.

- [ ] **Step 2: Commit (only if any test fixture needed updating)**

Only commit if test fixtures needed updating for the new schema version. Otherwise, no commit needed.

---

### Task 10: Version bump

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Bump version in plugin.json**

Update version from `"4.1.1"` to `"4.2.0"`.

- [ ] **Step 2: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "chore: bump version to 4.2.0"
```
