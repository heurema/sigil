# Phase 1: Project Intent Layer — Design Spec

Date: 2026-03-15
Status: approved
Validated: Claude + Codex (GPT-5.4) via arbiter ask (3 rounds)

## Summary

Add `project.intent.md` as a project-level intent artifact that the Signum contractor
reads before generating task contracts. This aligns task-local contracts with project
goals and prevents semantic drift in multi-contract projects.

## 1. New Artifact: project.intent.md

**Location:** repo root of the target project (not `.signum/`).

**Template:**

```markdown
Updated: YYYY-MM-DD

# Project Intent

## Goal
<What this project does, 1-3 sentences>

## Core Capabilities
- <Capability 1>
- <Capability 2>
- <Capability 3>

## Non-Goals
- <What we explicitly do NOT build>

## Glossary
| Term | Definition | Avoid |
|------|------------|-------|
| contract | JSON spec defining task scope | spec, ticket |
```

Sections used by Phase 1 checks: Goal, Non-Goals, Glossary, Core Capabilities.
Personas and Success Criteria deferred — no enforcement mechanism yet.

## 2. Schema Change: contract.schema.json

Update `schemaVersion` enum to: `["3.0", "3.1", "3.2", "3.3"]` (append "3.3", keep all prior).

**Replace** the existing `if/then` block (which currently uses `"const": "3.2"`) with:
```json
"if": {
  "properties": { "schemaVersion": { "enum": ["3.2", "3.3"] } }
},
"then": {
  "required": ["contractId", "status", "timestamps"]
}
```
This is a replacement, not an addition — JSON Schema draft-07 only supports one `if/then` pair at the root level.

Add optional top-level property:
```json
"contextInheritance": {
  "type": "object",
  "properties": {
    "projectRef": {
      "type": ["string", "null"],
      "description": "Path or status: string path=loaded, 'not_found'=checked but missing (low risk), null=explicit waiver, absent=legacy contract"
    },
    "projectIntentSha256": {
      "type": "string",
      "description": "SHA-256 of project.intent.md contents at contract creation time. Present only when projectRef is a file path."
    }
  },
  "additionalProperties": true
}
```

**Semantics of `projectRef`:**
- `"project.intent.md"` — file found and loaded. `projectIntentSha256` set.
- `"not_found"` — contractor checked, file missing, risk=low → continued without blocking
- `null` — user explicitly confirmed "proceed without project context" (waiver)
- field absent — legacy contract (pre-3.3), contractor did not have this feature

**Audit trail:** When `projectRef` is a file path, `projectIntentSha256` captures the
exact state of project.intent.md used during contract generation. PACK phase includes
this hash in proofpack, enabling post-hoc verification that intent didn't change.

**Contractor schemaVersion:** Update `agents/contractor.md` to generate `schemaVersion: "3.3"` for new contracts (currently hardcoded to "3.2").

## 3. Contractor Agent Changes (agents/contractor.md)

### Modified Process Flow

Current: (1) parse → (2) scan → (3) assess risk → (4) generate → (5) detect lineage → (6) validate → (7) write

New: (1) parse → **(1.5) read project.intent.md** → (2) scan → (3) assess risk → **(3.5) decide project intent gate)** → (4) generate → (5) detect lineage → (6) validate → (7) write

### Step 1.5: Read project intent (early, before scan)

```
Check if PROJECT_ROOT/project.intent.md exists.
If exists:
  - Read it
  - Extract: Goal, Core Capabilities, Non-Goals, Glossary terms
  - Use this context to inform goal parsing, scope boundaries, and terminology in step 4
If missing:
  - Note absence, continue to step 2 (decision deferred to step 3.5)
```

### Step 3.5: Project intent gate (after risk assessment)

```
If project.intent.md was found:
  - Set contextInheritance.projectRef = "project.intent.md"
  - Compute SHA-256 of file contents, set contextInheritance.projectIntentSha256
  - Use project non-goals to populate outOfScope if user didn't specify
  - Use glossary terms in acceptance criteria language

If project.intent.md was NOT found:
  If riskLevel >= medium:
    - Add to openQuestions: "[INTENT_WAIVER] Project intent not defined. Create
      project.intent.md at repo root, or reply 'proceed without project context'
      to continue."
    - Set requiredInputsProvided = false
  If riskLevel = low:
    - Set contextInheritance.projectRef = "not_found"
    - Continue normally

If user previously answered with waiver (see Waiver Detection):
  - Set contextInheritance.projectRef = null (explicit waiver)
  - Do NOT re-ask the question
  - Continue normally
```

### Waiver Detection

The open question includes the marker `[INTENT_WAIVER]` in its text. When the contractor
is re-launched with user answers:

1. Find the open question containing `[INTENT_WAIVER]` in the appended user answers
2. Check if the user's answer to THAT specific question is affirmative:
   - Match: "proceed without project context", "yes, proceed", "yes" (case-insensitive)
   - Do NOT match: negations ("do not proceed", "no", "don't")
3. If affirmative: set projectRef=null, remove this question from openQuestions
4. If negative or no answer found: keep the question, keep requiredInputsProvided=false

The `[INTENT_WAIVER]` marker solves the scoping problem: the contractor can distinguish
this question from other open questions even in the unstructured "appended answers" flow.

## 4. Orchestrator Changes (commands/signum.md)

### Step 1.2: Validate contract

Add `contextInheritance` to the non-critical fields list (validation passes without it).

### Step 1.3.5: Spec quality gate

**No change to the 7-dimension scoring.** Total remains /115. Thresholds unchanged.

### New Step 1.3.6: Intent alignment check (informational)

Insert between Step 1.3.5 (deterministic spec quality gate + inline prose check) and
Step 1.3.7 (multi-model spec validation).

**Skip conditions** (matches risk-proportional policy of multi-model spec validation):
- Skip if `riskLevel` is `low` — low-risk tasks don't benefit from LLM alignment checks
- Skip if `contextInheritance.projectRef` is not a file path (null, "not_found", or absent)

Runs only when: riskLevel >= medium AND projectRef is a file path string (not null, not "not_found").

**Implementation:** LLM-based (like Clover reconstruction test), NOT deterministic jq.

Launch a sonnet subagent with:
```
You are checking whether a task contract aligns with its project's stated intent.

Project intent:
<contents of project.intent.md>

Contract:
Goal: <contract goal>
Out of scope: <contract outOfScope>
Acceptance criteria: <AC descriptions>

Check:
1. Does the contract goal relate to the project's stated goal or core capabilities?
2. Does the contract scope overlap with any project non-goals?
3. Does the contract use terminology inconsistent with the project glossary?

Output JSON:
{
  "aligned": true|false,
  "concerns": ["<concern 1>", ...],
  "glossary_violations": ["<used 'X' but glossary says use 'Y'>", ...]
}
```

Parse the subagent response as JSON. If parsing fails (malformed output), write:
`{"aligned": null, "concerns": [], "glossary_violations": [], "parse_error": true}`.
Note: `aligned: null` (not true) — so display shows "skipped" rather than false "OK".
Assume `CONTRACT_PATH="$ARTIFACT_ROOT/contract.json"` and `INTENT_CHECK_PATH="$ARTIFACT_ROOT/intent_check.json"` are already available, then write the result to `$INTENT_CHECK_PATH`.

**Display in Step 1.4:** If `aligned=false` or concerns non-empty:
```
--- Intent alignment WARNING ---
Contract may diverge from project intent:
  - <concern 1>
  - <concern 2>
Glossary: <violations or "consistent">
```

This is informational — does NOT block the pipeline.

### Step 1.4: Display contract summary

Add after risk signals display:
```bash
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

Also show projectRef in contract summary:
```bash
# Use jq -e to test for null explicitly (jq -r turns null into "null" string)
if jq -e '.contextInheritance.projectRef' "$CONTRACT_PATH" >/dev/null 2>&1; then
  PROJECT_REF=$(jq -r '.contextInheritance.projectRef' "$CONTRACT_PATH")
  if [ "$PROJECT_REF" = "not_found" ]; then
    echo "Project intent: not found (low risk, continued)"
  else
    echo "Project intent: $PROJECT_REF (loaded)"
  fi
elif jq -e '.contextInheritance | has("projectRef")' "$CONTRACT_PATH" >/dev/null 2>&1; then
  # projectRef exists but is null → waiver
  echo "Project intent: waived by user"
fi
# If contextInheritance absent entirely → legacy contract, show nothing
```

### Step 1.5 (EXECUTE prep): contract-engineer.json

Update the jq whitelist to include `contextInheritance`:
```jq
{
  schemaVersion, contractId, status, timestamps, goal, inScope, allowNewFilesUnder, outOfScope,
  acceptanceCriteria: [.acceptanceCriteria[] | select(.visibility != "holdout")],
  assumptions, openQuestions, riskLevel, riskSignals, requiredInputsProvided,
  contextInheritance
} | with_entries(select(.value != null))
```

### PACK phase: proofpack serialization

Ensure `contextInheritance` is preserved in the full contract embedded in proofpack.
The redacted contract already includes it via the updated whitelist above.

### Cleanup list

Add `intent_check.json` under the active contract artifact root to:
- Archive mode cleanup (transient, discard — not copied to archive dir)
- Setup cleanup (rm at pipeline start)
- Per-contract directory intermediate purge (archive command)

## 5. Documentation Updates

### README.md
- Fix "six dimensions" → "seven dimensions" (existing bug)
- Add mention of project.intent.md support
- Add `contextInheritance` to contract.json fields table

### docs/reference.md
- Add `contextInheritance` to contract.json fields table
- Update schemaVersion from "3.0" to "3.3"

### CHANGELOG.md
- Add Phase 1 entry

## 6. Platform Sync

`platforms/claude-code/` files are identical to root files.

**Sync order:** update root files first, then copy to `platforms/claude-code/`.
Never update platform copies independently.

Files to sync:
- `agents/contractor.md`
- `commands/signum.md`
- `lib/schemas/contract.schema.json`

## 7. Test Plan

### Schema validation
- Contract with schemaVersion "3.3" + contextInheritance.projectRef → VALID
- Contract with schemaVersion "3.3" without contractId → INVALID (required)
- Contract with schemaVersion "3.2" without contextInheritance → VALID (backward compat)

### Contractor behavior
- project.intent.md exists, risk=low → projectRef="project.intent.md", projectIntentSha256 set, no blocking
- project.intent.md exists, risk=high → projectRef="project.intent.md", projectIntentSha256 set, no blocking
- project.intent.md missing, risk=low → projectRef="not_found", no blocking
- project.intent.md missing, risk=medium → openQuestion with [INTENT_WAIVER] marker, requiredInputsProvided=false
- user answers "proceed without project context" to [INTENT_WAIVER] question → projectRef=null, no re-ask
- user answers "no, do not proceed" to [INTENT_WAIVER] question → no waiver, openQuestion persists
- user answers "yes" to a DIFFERENT open question → no waiver triggered (scoping via marker)
- legacy contract (schemaVersion 3.2) → no contextInheritance field at all

### Intent alignment check
- risk=low → check skipped entirely (no intent_check.json created)
- risk=medium, aligned contract → aligned=true, no concerns
- risk=medium, unrelated contract goal → aligned=false, concern listed
- Contract uses term from Avoid column → glossary_violations populated
- Subagent returns malformed output → aligned=null, parse_error=true, display "skipped"

### Downstream preservation
- contextInheritance (incl. projectIntentSha256) present in contract-engineer.json
- contextInheritance present in proofpack.json contract envelope
- projectIntentSha256 enables post-hoc verification that intent file didn't change

## 8. Acceptance Criteria

1. Contractor loads project.intent.md when present and uses it to inform contract generation
2. Missing project.intent.md blocks medium/high risk with escapable open question
3. Waiver path works without looping
4. contextInheritance.projectRef correctly set in all three states (path/null/absent)
5. Intent alignment check runs and displays warnings when misaligned
6. contextInheritance preserved through engineer contract and proofpack
7. All existing tests pass unchanged
8. Schema backward compatible with 3.0/3.1/3.2 contracts
