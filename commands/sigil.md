---
description: Risk-adaptive development pipeline with adversarial consensus code review
argument-hint: Feature description (e.g., "add user authentication with JWT")
---

# Sigil — Risk-Adaptive Development Pipeline

This command orchestrates a 4-phase development workflow for `$ARGUMENTS`. Each phase writes a structured artifact to `.dev/` before the next phase begins. Post-checks validate each artifact. Agent count scales with risk level (low/medium/high).

**Phases:**
1. **Scope** (bash only) — deterministic precompute, branch creation, risk assessment
2. **Explore** (sonnet agents) — codebase mapping, pattern discovery, open questions
3. **Design** (sonnet or opus) — architecture, files, test plan, risks — requires user approval
4. **Build** (sonnet implementers + post-build observer) — implement, test, verify, review

---

## Error Handling

**Post-check failures:**
- Each phase has a post-check. If it fails: retry the phase ONCE.
- If retry also fails: STOP. Show the user what went wrong, display the artifact state, and ask how to proceed.
- Never retry more than once per phase.

**Agent failures:**
- If a subagent returns an error or empty result: report it to the user and ask whether to retry or skip.
- Never silently swallow agent errors.
- "Skip" semantics per phase:
  - Phase 1 (Explore): CANNOT skip — Design requires exploration input. Offer retry or abort.
  - Phase 2 (Design): CANNOT skip — Build requires design input. Offer retry or abort.
  - Phase 3 (Build): individual implementer can be skipped if others cover remaining tasks. Reassign failed tasks to another agent or ask user.

**User abort:**
- At any pause point, the user can say "abort" to stop.
- `.dev/` directory is preserved for inspection. Branch is preserved.

---

## Phase 0: Scope (bash only, zero LLM)

**Goal:** Deterministic precompute. No LLM reasoning in this phase — only bash commands and tool calls.

### Actions

**Step 0.0 — Check for existing session:**

If `.dev/scope.json` exists, read it and check for existing artifacts:
```bash
if [ -f .dev/scope.json ]; then
  PREV_FEATURE=$(jq -r '.feature' .dev/scope.json)
  PREV_RISK=$(jq -r '.risk' .dev/scope.json)
  ARTIFACTS=""
  [ -f .dev/exploration.md ] && ARTIFACTS="$ARTIFACTS exploration.md"
  [ -f .dev/design.md ] && ARTIFACTS="$ARTIFACTS design.md"
  [ -f .dev/observer-report.md ] && ARTIFACTS="$ARTIFACTS observer-report.md"
fi
```

If artifacts exist, present to user:
> Found existing session for '<feature>' (risk=<risk>).
> Artifacts present: <list>.
> **Resume from next incomplete phase? (resume / restart / abort)**

Handle responses:
- **"resume"**: determine the earliest incomplete phase (no exploration.md → Phase 1, no design.md → Phase 2, else Phase 3). Skip to that phase using existing artifacts.
- **"restart"**: remove all files in `.dev/` except `.dev/runs/` (preserve history), then proceed with Phase 0 from Step 0.1.
- **"abort"**: stop.

If `.dev/scope.json` does not exist, proceed to Step 0.1.

**Step 0.1 — Clean worktree check:**
```bash
if [ -n "$(git status --porcelain)" ]; then
  echo "WARNING: Working tree has uncommitted changes."
  echo "These changes will be included in the feature branch and review diff."
fi
```
Present the warning to the user if triggered: **"Uncommitted changes detected. Stash them first? (stash / continue / abort)"**
- "stash" → `git stash push -m "sigil: pre-pipeline stash"`, proceed
- "continue" → proceed with dirty tree (user accepts the risk)
- "abort" → stop

**Step 0.2 — Prepare workspace:**
```bash
mkdir -p .dev
# Add .dev/ to .gitignore if not already present
grep -qxF '.dev/' .gitignore 2>/dev/null || echo '.dev/' >> .gitignore
```

**Step 0.3 — Create feature branch:**
- Record the current branch BEFORE creating the new branch: `BASE_REF=$(git rev-parse --abbrev-ref HEAD)`
- Convert `$ARGUMENTS` to kebab-case, truncate to 50 chars max
- Run: `git checkout -b feat/<kebab-case-summary>`
- If `git checkout -b` fails with "already exists": run `git checkout feat/<kebab-case-summary>` instead and continue. If it fails for any other reason (bad ref, detached HEAD, etc.): stop and show the error to the user.

**Step 0.4 — Gather data (bash only):**
```bash
# repo_root
pwd

# languages: detect from file extensions
find . -not \( -path './.git/*' -o -path './node_modules/*' -o -path './__pycache__/*' -o -path './.venv/*' \) -type f \
  | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20

# file_count
find . -not \( -path './.git/*' -o -path './node_modules/*' -o -path './__pycache__/*' -o -path './.venv/*' \) -type f | wc -l

# has_tests: set to true if test directory or test files found, false otherwise
HAS_TESTS=false
[ -n "$(find . -not \( -path './.git/*' -o -path './node_modules/*' -o -path './.venv/*' -o -path './__pycache__/*' \) -type d \( -name 'tests' -o -name 'test' \) 2>/dev/null | head -1)" ] && HAS_TESTS=true
[ -n "$(find . -not \( -path './.git/*' -o -path './node_modules/*' -o -path './.venv/*' -o -path './__pycache__/*' \) -type f \( -name '*_test.*' -o -name '*.test.*' \) 2>/dev/null | head -1)" ] && HAS_TESTS=true

# has_ci: set to true if CI config found, false otherwise
HAS_CI=false
[ -d .github/workflows ] && HAS_CI=true
[ -f .gitlab-ci.yml ] && HAS_CI=true
```

**Step 0.5 — Estimate scope from `$ARGUMENTS` and repo structure:**
- Review the arguments and directory structure to guess which files will be touched.
- List `estimated_files` as best-guess paths (not guaranteed, just planning hints).

**Step 0.6 — Assess risk:**

| Condition | Risk |
|---|---|
| `estimated_files` < 5 AND exactly 1 language | low |
| `estimated_files` 5-15 OR 2+ languages | medium |
| `estimated_files` > 15 OR feature involves external APIs / security / auth | high |

**Risk escalation keywords — force minimum `risk=medium` regardless of file count if ANY of these apply:**

- `$ARGUMENTS` contains any of: `auth`, `token`, `secret`, `payment`, `crypto`, `permission`, `password`, `jwt`, `oauth`, `key`, `migration`, `schema`, `deploy`, `credential`, `session`, `certificate`, `ssl`, `tls`
- `estimated_files` includes entry-point files: `__main__.py`, `main.go`, `main.rs`, `index.ts`, `index.js`, `app.py`, `manage.py`
- `estimated_files` includes configuration files: `*.yml`, `*.yaml`, `*.toml`, `*.env*`, `Dockerfile`, `docker-compose.*`
- `estimated_files` includes database-related paths: files containing `migration`, `migrate`, `schema`, `alembic`, `prisma`

**Step 0.7 — Agent count table:**

| Risk | Explorers | Design Model | Implementers | Observer |
|---|---|---|---|---|
| low | 1 | sonnet | 1 | no |
| medium | 2 | opus | 2 | yes (post-build) |
| high | 3 | opus | 3 | yes (post-build) |

**Step 0.8 — Write `.dev/scope.json`:**
```json
{
  "feature": "<from $ARGUMENTS>",
  "branch": "feat/<name>",
  "repo_root": "<absolute path>",
  "base_ref": "<parent branch name>",
  "risk": "low|medium|high",
  "agent_count": 1,
  "estimated_files": ["path/to/file1.py", "path/to/file2.py"],
  "file_count": 42,
  "has_tests": true,
  "has_ci": false,
  "languages": ["python"],
  "review_strategy": "<simple|adversarial|consensus>",
  "started_at": "<ISO-8601 UTC timestamp>"
}
```

**Step 0.9 — Post-check:**
```bash
jq '.risk, .feature, .agent_count, .started_at, .review_strategy' .dev/scope.json
```
Must succeed and return non-null values. If it fails: fix the JSON and retry once. If retry fails: stop and show user.

**Step 0.10 — Display scope summary.**

Review strategy defaults: low→simple, medium→adversarial, high→consensus.
For risk=low: auto-set review_strategy to "simple" in scope.json (no prompt, no pause).

Show a table like:
```
Feature:    <feature>
Branch:     feat/<name>
Risk:       low | medium | high
Agents:     explorer*N, implementer*N, observer=yes/no
Est. files: N
Languages:  python, typescript, ...
Review:     <strategy> (suggested for risk=<risk>)
```

- If `risk="low"`: write `"review_strategy": "simple"` to scope.json, then proceed to Phase 1 automatically (no pause).
- If `risk="medium"` or `risk="high"`: ask user to confirm scope before proceeding:
  > Scope summary above. Review strategy: `<default>`. Proceed? (yes / adjust / abort)
  > To override strategy, type: `review=simple`, `review=adversarial`, or `review=consensus`
  - "yes": proceed to Phase 1
  - `review=simple` / `review=adversarial` / `review=consensus`: persist the override by writing the new value to `.dev/scope.json` under `"review_strategy"`, then proceed to Phase 1
  - "adjust": user provides corrections (e.g., override risk level), update scope.json, re-display
  - "abort": stop workflow

---

## Phase 1: Explore (sonnet agents)

**Goal:** Map the codebase, identify patterns, surface constraints and open questions.

**Input:** `.dev/scope.json`

### Actions

**Step 1.1 — Read `.dev/scope.json`.** Extract: `feature`, `estimated_files`, `languages`, `agent_count`.

**Step 1.2 — Launch explorer agents** (count = `agent_count` from scope.json):

All explorer agents:
- `subagent_type="general-purpose"`, `model="sonnet"`, `run_in_background=true`
- Each prompt must include: feature description, `estimated_files`, `languages` from scope.json

Agent focus by count:
- **1 agent:** covers all aspects — similar code patterns, architecture, tests, CI, extension points
- **2 agents:** agent 1 -> similar code patterns + architecture; agent 2 -> testing/CI patterns + extension points
- **3 agents:** agent 1 -> similar code patterns; agent 2 -> architecture + module boundaries; agent 3 -> testing/CI + extension points

**Step 1.3 — Collect and synthesize all agent outputs** into `.dev/exploration.md`.

The file MUST contain EXACTLY these four `## ` headings (in this order):
```
## Codebase Map
## Patterns and Conventions
## Constraints
## Open Questions
```

**Step 1.4 — Post-check:**
```bash
test -f .dev/exploration.md && \
  grep -q '## Codebase Map' .dev/exploration.md && \
  grep -q '## Patterns and Conventions' .dev/exploration.md && \
  grep -q '## Constraints' .dev/exploration.md && \
  grep -q '## Open Questions' .dev/exploration.md

# Content minimums: each section must have >=30 words
for SECTION in "Codebase Map" "Patterns and Conventions" "Constraints" "Open Questions"; do
  WORDS=$(awk -v s="## $SECTION" 'index($0,s)==1{f=1;next} /^## /{f=0} f{c+=NF} END{print c+0}' .dev/exploration.md)
  [ "$WORDS" -lt 30 ] && echo "FAIL: '$SECTION' has $WORDS words (min 30)" && exit 1
done
```
If check fails: fix the file and retry once. If retry fails: stop and show user.

**Step 1.5 — If `## Open Questions` section is non-empty:** present questions to user and wait for answers. Append answers in-line below each question in `exploration.md`.

**Step 1.6 — Proceed to Phase 2.**

---

## Phase 2: Design (sonnet or opus based on risk)

**Goal:** Design the implementation approach before any code is written.

**Input:** `.dev/scope.json` + `.dev/exploration.md`

### Actions

**Step 2.1 — Read both input files.**

**Step 2.2 — Model selection:**
- `risk="low"` -> orchestrator writes design directly (sonnet, no subagent)
- `risk="medium"` or `risk="high"` -> dispatch opus subagent:
  - `subagent_type="general-purpose"`, `model="opus"`, `run_in_background=false`
  - Include full contents of `exploration.md` and `scope.json` in the prompt
  - Prompt: "Design the implementation for: `<feature>`. Use the exploration and scope below. Output `.dev/design.md` with exactly four sections: ## Architecture, ## Files, ## Test Plan, ## Risks."

**Step 2.3 — Write `.dev/design.md`.** It MUST contain EXACTLY these four `## ` headings:
```
## Architecture
## Files
## Test Plan
## Risks
```

The `## Files` section should list each file to be created or modified, with a brief note on what changes.

**Step 2.4 — Post-check:**
```bash
test -f .dev/design.md && \
  grep -q '## Architecture' .dev/design.md && \
  grep -q '## Files' .dev/design.md && \
  grep -q '## Test Plan' .dev/design.md && \
  grep -q '## Risks' .dev/design.md

# Content minimums: each section must have >=50 words
for SECTION in "Architecture" "Files" "Test Plan" "Risks"; do
  WORDS=$(awk -v s="## $SECTION" 'index($0,s)==1{f=1;next} /^## /{f=0} f{c+=NF} END{print c+0}' .dev/design.md)
  [ "$WORDS" -lt 50 ] && echo "FAIL: '$SECTION' has $WORDS words (min 50)" && exit 1
done

# Files section must list at least one file (supports - , * , 1. , - [ ] list formats)
FILES_COUNT=$(awk '/^## Files/{f=1;next} /^## /{f=0} f && /^[-*][ ]|^[0-9]+[.][ ]/{c++} END{print c+0}' .dev/design.md)
[ "$FILES_COUNT" -lt 1 ] && echo "FAIL: ## Files section lists no files" && exit 1
```
If check fails: fix and retry once. If retry fails: stop and show user.

**Step 2.5 — Codex design review (conditional):**

If `risk="high"`: automatically run Codex review before presenting to user:
```bash
# SECURITY: never interpolate file content into shell strings — use stdin
cat .dev/design.md | codex exec --ephemeral -C "$PWD" \
  "Review this feature design (provided via stdin). Flag security risks, architectural weaknesses, and missing edge cases. Be concise." 2>&1
```
- Filter style disagreements (different model aesthetics are noise — only flag bugs, security, performance)
- Present Codex findings alongside the design under a `### Codex Perspective` section

Codex error handling (apply after each `codex` invocation):
1. Check binary: `which codex` — if empty, log "Codex CLI not installed — skipping", set `codex_status: "not_installed"` in `.dev/review-summary.json`, proceed without Codex
2. Run the codex command
3. If exit=0: set `codex_status: "ok"`
4. If exit≠0 + stderr contains "auth" or "token": log "Codex auth expired — run `codex auth`", set `codex_status: "auth_expired"`, proceed
5. If exit≠0 (other): log "Codex failed: <first 200 chars of stderr>", set `codex_status: "error"`, proceed

Valid `codex_status` values: `"ok"`, `"not_installed"`, `"auth_expired"`, `"error"`, `"skipped"`.

**Step 2.6 — PAUSE. Present design to user and wait for explicit approval.**

Display:
- Architecture summary (from `## Architecture`)
- Files to change (from `## Files`)
- Test plan (from `## Test Plan`)
- Risks (from `## Risks`)
- Codex perspective (if available, from Step 2.5)

Then ask:
> **Approve this design? Reply: yes / revise / ask-codex / abort**

Handle responses:
- **"yes"** -> proceed to Phase 3
- **"revise"** -> ask what to change, update `design.md`, re-present (return to Step 2.6)
- **"ask-codex"** -> run Codex review (same as Step 2.5) if not already done, present findings, return to approval gate
- **"abort"** -> stop. Keep `.dev/` for reference. Done.

---

## Phase 3: Build (sonnet implementers + post-build observer)

**Goal:** Implement the feature following the approved design, with test verification, scope checks, and observer oversight (medium/high risk) AFTER implementation.

**Input:** `.dev/scope.json` + `.dev/design.md`

### Actions

**Step 3.1 — Read both input files.** Extract `agent_count`, `risk`, `base_ref` from scope.json. Assign for use in subsequent steps:
```bash
BASE_REF=$(jq -r '.base_ref' .dev/scope.json) || { echo "FATAL: jq failed reading scope.json"; exit 1; }
if [ -z "$BASE_REF" ] || [ "$BASE_REF" = "null" ]; then echo "FATAL: base_ref is empty/null in scope.json"; exit 1; fi
```

**Step 3.2 — Plan tasks from `## Files` section of design.md.** Group files by independence (files that don't share imports/deps can be done in parallel).

If `agent_count > 1`: write a file ownership registry to `.dev/file-ownership.json`:
```json
{
  "agent_1": ["src/module_a.py", "tests/test_module_a.py"],
  "agent_2": ["src/module_b.py", "tests/test_module_b.py"]
}
```

**Step 3.3 — Launch implementer agents** (count = `agent_count`):

All implementer agents:
- `subagent_type="general-purpose"`, `model="sonnet"`, `run_in_background=true`
- Prompt includes:
  - Assigned files/tasks from design.md
  - Relevant patterns from exploration.md
  - Full scope.json context
  - If multi-agent: file ownership registry with rule "You are agent_N. You MUST NOT modify files assigned to other agents."
  - Instruction: implement, write tests (TDD — tests before or alongside implementation), **commit after EACH completed task** (each logical unit of work = one atomic commit with a clear message), follow existing patterns found during exploration
- **1 agent:** implements all files sequentially, committing after each logical task
- **2+ agents:** split tasks by independence. If agents need to touch overlapping files, assign them sequentially instead of in parallel (file ownership = no two agents editing the same file)

**Step 3.4 — After all implementers complete, run test suite:**

Detect test runner from `scope.json` languages field:
```bash
LANG=$(jq -r '.languages[0]' .dev/scope.json)
HAS_TESTS=$(jq -r '.has_tests' .dev/scope.json)

case "$LANG" in
  python)                TEST_CMD="python -m pytest tests/ -v --tb=short" ;;
  javascript|typescript) TEST_CMD="npm test" ;;
  rust)                  TEST_CMD="cargo test" ;;
  go)                    TEST_CMD="go test ./..." ;;
  *)                     TEST_CMD="" ;;
esac
```

If `TEST_CMD` is non-empty and `has_tests` is true:
- Run the test command and capture output to `.dev/test-results.txt`
- Exit code 0 -> `Tests: PASS`
- Non-zero -> `Tests: FAIL`. Present failures to user: **"Tests failed. Fix and retry? / Proceed to review? / Abort?"**
  - "fix": dispatch a fix agent with test output as context, then re-run tests (one retry)
  - "proceed": continue to observer/review with failing tests noted
  - "abort": stop

If `has_tests=false` or `TEST_CMD` is empty: record `Tests: not run` and proceed.

**Step 3.5 — Scope creep check (always runs, bash only):**
```bash
DESIGNED=$(awk '/^## Files/{f=1;next} /^## /{f=0} f && /^[-*][ ]|^[0-9]+[.][ ]/{c++} END{print c+0}' .dev/design.md)
ACTUAL=$(git diff --name-only "$BASE_REF"..HEAD | wc -l | tr -d ' ')
if [ "$ACTUAL" -gt $((DESIGNED + 2)) ]; then
  echo "WARN: Scope creep — $ACTUAL files changed vs $DESIGNED designed (+2 tolerance)."
  echo "Extra files:"
  git diff --name-only "$BASE_REF"..HEAD
fi
```
This is informational (WARN, not BLOCK). Display the warning in the final summary if triggered.

**Step 3.6 — If `risk="medium"` or `risk="high"` (observer=yes):** launch observer agent after all implementation agents have completed and committed their changes:
- `subagent_type="general-purpose"`, `model="sonnet"`, `run_in_background=false` (wait for result)
- Load the observer prompt from the [Appendix](#appendix-observer-prompt-loading) and substitute all placeholders with actual values: replace `<DESIGN_PATH>` with `.dev/design.md`, replace `<BASE_REF>` with the actual value from `scope.json` (e.g., `main`), replace `<SCOPE>` with `all`
- Instruct it to write its output to `.dev/observer-report.md`

**Step 3.7 — Process observer results (if observer ran):**

Read `.dev/observer-report.md`:
- **Verdict = BLOCK:** most severe — show findings, do NOT proceed. Ask user to fix manually or abort
- **Verdict = STOP:** second severity — show findings, recommend fixing before merge. Ask user: continue or abort
- **Verdict = WARN:** show findings as informational, proceed
- **Verdict = PASS:** no issues, proceed

**Step 3.8 — Review Dispatcher:**

Read `review_strategy` from `.dev/scope.json`. If field is missing (old session), default to `"simple"`.

**CASE review_strategy:**

- `"simple"` → launch 1 code reviewer:
  - `subagent_type="general-purpose"`, `model="sonnet"`, `run_in_background=false`
  - Prompt: use the REVIEWER_PROMPT from `lib/prompts/reviewer.md` with `{diff}`, `{design_md}`, `{scope_json}` substituted (same prompt as adversarial path). Instruct agent to write output to `.dev/reviewer-round-1.json`.
  - Fallback: `codex review 2>&1` → fallback: `general-purpose` sonnet with inline review prompt
  - Codex error handling (apply after each `codex` invocation):
    1. Check binary: `which codex` — if empty, log "Codex CLI not installed — skipping", set `codex_status: "not_installed"` in `.dev/review-summary.json`, proceed without Codex
    2. Run the codex command
    3. If exit=0: set `codex_status: "ok"`
    4. If exit≠0 + stderr contains "auth" or "token": log "Codex auth expired — run `codex auth`", set `codex_status: "auth_expired"`, proceed
    5. If exit≠0 (other): log "Codex failed: <first 200 chars of stderr>", set `codex_status: "error"`, proceed
  - Write `.dev/review-verdict.md` using the **same format as Step 3.8e** (unified schema):
    ```
    ## Review Verdict: PASS | WARN | BLOCK
    **Strategy:** simple
    **Rounds:** 1
    **Codex tiebreaker:** no
    ### Findings (N total, M verified)
    | # | Sev | Cat | File:Line | Claim | Source | Verified |
    ...
    ### Verdict Reasoning
    ...
    ```
    For simple strategy: `Source` = "reviewer" for all, `Verified` = "n/a" (no machine validation).
  - Write `.dev/review-summary.json` with same schema as Step 3.8e:
    `strategy: "simple"`, `rounds: 1`, `round_1.reviewer` filled, `round_1.skeptic: null`,
    `round_2: null`, `codex_invoked: false`, `diff_sha: null` (no diff capture in simple path).
  - Present verdict to user:
    - PASS → go to Step 3.9
    - WARN → "Review found warnings. Proceed? (yes / fix / abort)"
    - BLOCK → "Review found blocking issues. Type override rationale to proceed, or: fix / abort"
      - If override: log `{"rationale": "...", "timestamp": "..."}` to `review-summary.json` under `override` field
    - "fix" → re-run Step 3.8 (single retry only)

- `"adversarial"` → go to Step 3.8a

- `"consensus"` → go to Step 3.8a

- Invalid value → print error: "Unknown review_strategy: '<value>'" → write `## Review Verdict: ABORTED` and `Verdict: ABORTED` to `.dev/review-verdict.md` → STOP

**Step 3.8a — Round 1: Blind Parallel Review:**

1. **Capture diff + size gate:**
```bash
git diff "$BASE_REF"..HEAD > .dev/review-diff.txt
DIFF_SHA=$(shasum -a 256 .dev/review-diff.txt | cut -d' ' -f1)
DIFF_SIZE=$(wc -c < .dev/review-diff.txt)
```

If `DIFF_SIZE == 0`:
> No changes to review (empty diff). Skip review? (yes / abort)
- `yes` → write `## Review Verdict: SKIPPED` to `.dev/review-verdict.md` → go to Step 3.9
- `abort` → STOP

If `DIFF_SIZE > 51200` (50KB):
> WARNING: Diff is $(($DIFF_SIZE / 1024))KB (>50KB). Review quality may degrade.
> Options: proceed / switch-to-simple / abort

- `proceed` → continue with current strategy
- `switch-to-simple` → write `"review_strategy": "simple"` back to `.dev/scope.json`, go to Step 3.8 dispatcher (re-enter as simple)
- `abort` → write `## Review Verdict: ABORTED` to `.dev/review-verdict.md` → STOP

2. **Read `.dev/design.md`**

3. **Cost estimate + user confirmation:**
```
adversarial: ~$0.10-0.20 (2 agents × 1 round)
consensus:   ~$0.20-0.40 (2 agents × up to 2 rounds + Codex)
Proceed? (yes / skip-review / abort)
```
- `skip-review` → write `## Review Verdict: SKIPPED` to `.dev/review-verdict.md` → go to Step 3.9
- `abort` → write `## Review Verdict: ABORTED` to `.dev/review-verdict.md` → STOP

4. **REVIEWER_PROMPT** — injected from plugin prompts:

@${CLAUDE_PLUGIN_ROOT}/lib/prompts/reviewer.md

Substitute these variables in the prompt above before passing to the Reviewer subagent:
- `{diff}` → contents of `.dev/review-diff.txt`
- `{design_md}` → contents of `.dev/design.md`
- `{scope_json}` → contents of `.dev/scope.json`

5. **SKEPTIC_PROMPT** — injected from plugin prompts:

@${CLAUDE_PLUGIN_ROOT}/lib/prompts/skeptic.md

Substitute the same variables as REVIEWER_PROMPT:
- `{diff}` → contents of `.dev/review-diff.txt`
- `{design_md}` → contents of `.dev/design.md`
- `{scope_json}` → contents of `.dev/scope.json`

6. **Launch parallel (separate output files):**
```
Agent A (Reviewer):
  subagent_type="general-purpose", model="sonnet", run_in_background=true
  prompt = REVIEWER_PROMPT with {diff, design_md, scope_json} substituted
  Instruct agent to write output to .dev/reviewer-round-1.json

Agent B (Skeptic):
  subagent_type="general-purpose", model="sonnet", run_in_background=true
  prompt = SKEPTIC_PROMPT with {diff, design_md, scope_json} substituted
  Instruct agent to write output to .dev/skeptic-round-1.json
```

7. **Wait for both agents. Timeout: 5 minutes per agent.** If an agent exceeds timeout, mark it `UNRELIABLE` and proceed with the other agent's output only.

8. **JSON recovery chain (5 steps, per agent):**
   0. Check file exists: `[ -f .dev/reviewer-round-1.json ]` (or skeptic). If missing → skip to step (c) (agent retry).
   a. `json.loads(output)` — direct parse
   b. If fails: extract content between ` ```json ` and ` ``` ` fences, parse
   c. If fails: **retry the AGENT** once with amended prompt: "Previous output was invalid JSON. Output ONLY valid JSON." (this re-runs the agent, not just re-parses)
   d. If retry output fails: extract from fences again
   e. If still fails: mark agent `UNRELIABLE`, use `{"findings": [], "verdict": "UNRELIABLE"}`

9. **Write `.dev/review-round-1.json`** combining both agent outputs + `diff_sha`

**Step 3.8b — Validate and Merge:**

1. **Per-finding validation** (for each finding from each agent):

   a. `file == "_spec_"` → skip file/line/evidence validation, `verified=true`
      - Cap: max 3 `_spec_` findings per agent. If exceeded: warn "Agent produced too many spec-level findings — capping at 3."

   b. File exists? `[ -f "$file" ]` → no: DROP finding, `invalid_count++`

   c. Line in range? `1..$(wc -l < "$file")` → no: DROP finding, `invalid_count++`

   d. Evidence grep (full pipeline):
      ```bash
      grep -qF "$(printf '%s' "$evidence" | head -c 80)" "$file"
      ```
      Match → `verified=true`. No match → `verified=false` (keep finding but **excluded from verdict calculation** — only verified findings drive BLOCK/WARN).
      Note: grep checks substring presence in file, not binding to the claimed line. This is a pragmatic trade-off — it catches outright hallucinations while accepting that short common patterns may false-match. The 80-char window + verdict exclusion mitigates most abuse.

   e. Scope check: file in design `## Files` or scope `estimated_files`?
      No → tag `[OUT-OF-SCOPE]`. Out-of-scope findings are **excluded from verdict calculation** but **kept visible** in `review-summary.json` under `out_of_scope_warnings[]` (informational, never dropped silently).

   f. Invalid count threshold: if `invalid_count > 50%` of agent's findings → flag agent `UNRELIABLE`, retry agent once (same prompt). If retry also >50% invalid → agent stays `UNRELIABLE`.

2. **Handle unreliable agents:**
   - Both UNRELIABLE → write `## Review Verdict: UNRELIABLE` to `.dev/review-verdict.md`, ask user: "Both review agents unreliable. retry-all / skip / abort"
     - `retry-all` → re-run Step 3.8a from scratch
     - `skip` → overwrite verdict to `## Review Verdict: SKIPPED`, write `review-summary.json` with `final_verdict: "SKIPPED"`, `findings: []`, `unreliable_agents: ["reviewer", "skeptic"]` → go to Step 3.9
     - `abort` → write `## Review Verdict: ABORTED` → STOP
   - One UNRELIABLE → exclude from verdict, use other agent's verdict only. Tag unreliable agent in `review-summary.json` under `unreliable_agents[]`.

3. **Dedup across agents:**
   ```
   dedup_key = (file, category, first_20_words_of_claim)
   ```
   - `_spec_` findings: separate dedup pool (key = `category + first_20_words` only)
   - Same key, same agent → keep higher severity
   - Same key, cross-agent → merge, set `source: "both"`, keep higher severity
   - Unique findings → set `source: "reviewer"` or `source: "skeptic"`
   - **Algorithm:** two-pass. First collapse same-agent duplicates by key, then cross-reference across agents. Output order: sort by severity (critical → important → minor), then by file path (alphabetical), then by line number (ascending). This guarantees stable indices for Round 2 refutals.

4. **Recompute round verdict from VALIDATED findings** (do NOT use raw agent verdicts):
   ```
   validated_findings = all findings that passed gates (b)-(e), excluding out-of-scope
   if any validated finding has severity "critical" → BLOCK
   else if any validated finding has severity "important" → WARN
   else → PASS
   Exclude UNRELIABLE agents from this computation entirely.
   ```
   Note: this may differ from what agents self-reported. The validated set is authoritative.

5. **Write `.dev/review-round-1-validated.json`**

**Step 3.8c — Escalation Decision:**

- `adversarial` → go to Step 3.8e (no Round 2, ever)

- `consensus` only — first check UNRELIABLE, then compute gap:
  1. Both UNRELIABLE → already handled in Step 3.8b (never reaches here)
  2. One UNRELIABLE → use other agent's verdict as final, skip gap calculation → Step 3.8e
  3. Both reliable → compute gap using **recomputed** verdicts from Step 3.8b item 4 (NOT raw agent-reported verdicts):
     ```
     gap = |level(recomputed_reviewer_verdict) - level(recomputed_skeptic_verdict)|
     where PASS=0, WARN=1, BLOCK=2
     recomputed_X_verdict = verdict derived from X's validated findings in Step 3.8b item 4
     ```
     - gap 0 → Step 3.8e (consensus reached)
     - gap 1 → strictest wins → Step 3.8e
     - gap 2 (PASS vs BLOCK) → Step 3.8d (Round 2)

**Step 3.8d — Round 2: Escalation (consensus only, triggered by gap=2):**

1. **Verify diff integrity:** Re-compute `shasum -a 256 .dev/review-diff.txt` and compare against stored `DIFF_SHA`. If mismatch: warn "Diff changed between rounds — possible concurrent modification. Recompute? (yes / abort)". If user says yes, re-capture diff and update DIFF_SHA.

2. **Prepare Round 1 merged findings** as JSON context for agents.

3. **ROUND_2_PROMPT** — injected from plugin prompts:

@${CLAUDE_PLUGIN_ROOT}/lib/prompts/round2.md

Substitute these variables:
- `{round_1_merged_findings_json}` → the merged+validated findings JSON from Step 3.8b
- `{diff}` → contents of `.dev/review-diff.txt`

4. **Launch parallel:** both agents with Round 2 prompt
   ```
   Reviewer: ROUND_2_PROMPT with {round_1_merged_findings_json, diff} substituted
             output → .dev/reviewer-round-2.json
   Skeptic:  ROUND_2_PROMPT with {round_1_merged_findings_json, diff} substituted
             output → .dev/skeptic-round-2.json
   ```

5. **Wait** (same 5-minute timeout), **parse** (same 5-step JSON recovery chain including agent retry).

6. **Handle Round 2 UNRELIABLE agents:**
   - Both Round 2 agents UNRELIABLE → skip refutals and additions entirely; recompute verdict from unmodified Round 1 findings; log `"unreliable_round2_agents": ["reviewer", "skeptic"]` in review-summary.json. Proceed to item 8.
   - One Round 2 agent UNRELIABLE → exclude its `refuted[]` and `added[]` from the merge. Since the BOTH-must-agree rule (item 8) cannot be satisfied with one agent, **no findings may be refuted**. Only `added[]` from the reliable agent are applied. Log `"unreliable_round2_agents": ["<agent>"]`.
   - Both reliable → proceed to item 7.

7. **Validate `added[]` findings** using the same validation pipeline as Step 3.8b (file exists, line range, evidence grep, scope check).

8. **Merge Round 2 into Round 1:**
   - A finding is refuted only if **BOTH** Round 2 agents list it in `refuted[]` with a rationale. If only one agent refutes, log it as `disputed_refutals[]` in `review-summary.json` (informational) but **keep the finding**.
   - Findings NOT in the agreed `refuted[]` → implicitly CONFIRMED (keep unchanged)
   - Agreed refuted findings → REMOVE from set, log `{index, rationale_reviewer, rationale_skeptic}` in `review-summary.json` under `refuted_findings[]`
   - `added[]` findings (from reliable agents only) → validated, then appended to set

9. **Recompute verdict** from merged finding set (same rules as Step 3.8b item 4: from validated findings, not agent verdicts).

10. **If recomputed verdict is still BLOCK and Round 1 had gap 2: Codex tiebreaker**
   `{verdict_A}` = Round 1 **recomputed** reviewer verdict, `{verdict_B}` = Round 1 **recomputed** skeptic verdict (from Step 3.8b item 4, NOT raw agent self-reports).
   Prepare tiebreaker input — the orchestrator MUST substitute `verdict_A` and `verdict_B` with the actual recomputed verdicts (PASS/WARN/BLOCK strings) from Step 3.8b item 4 before running this block:
   ```bash
   # SECURITY: build prompt via printf + cat (no heredoc expansion of untrusted content)
   TMPFILE="/tmp/sigil-tiebreaker-$$.txt"
   trap 'rm -f "$TMPFILE"' EXIT
   (umask 077; touch "$TMPFILE")
   {
     printf 'Tiebreak review. Reviewer: %s. Skeptic: %s.\n' "$verdict_A" "$verdict_B"
     printf 'Findings:\n'
     cat .dev/review-round-2-validated.json 2>/dev/null || cat .dev/review-round-1-validated.json
     printf '\nDiff (truncated to 50KB):\n'
     head -c 51200 .dev/review-diff.txt
     printf '\nReply ONLY: PASS, WARN, or BLOCK with one sentence reason.\n'
   } > "$TMPFILE"
   cat "$TMPFILE" | codex exec --ephemeral --skip-git-repo-check "" 2>&1
   rm -f "$TMPFILE"
   ```
   - Codex error handling (apply after each `codex` invocation):
     1. Check binary: `which codex` — if empty, log "Codex CLI not installed — skipping", set `codex_status: "not_installed"` in `.dev/review-summary.json`, proceed without Codex
     2. Run the codex command
     3. If exit=0: set `codex_status: "ok"`
     4. If exit≠0 + stderr contains "auth" or "token": log "Codex auth expired — run `codex auth`", set `codex_status: "auth_expired"`, proceed
     5. If exit≠0 (other): log "Codex failed: <first 200 chars of stderr>", set `codex_status: "error"`, proceed
   - Parse Codex response (extract PASS/WARN/BLOCK)
   - Codex unavailable (any non-ok codex_status) → final = BLOCK (conservative fallback)
   - Record tiebreaker artifact: `{input, output, verdict}` in `review-summary.json` under `codex_tiebreaker`
   - Set `codex_invoked: true` in `review-summary.json`

11. **Write `.dev/review-round-2-validated.json`**

**Step 3.8e — Final Output:**

1. **Write `.dev/review-summary.json`** with this schema:
```json
{
  "strategy": "simple|adversarial|consensus",
  "rounds": 1,  // set to 2 when Step 3.8d (Round 2) was executed
  "round_1": {
    "reviewer": {"verdict": "PASS|WARN|BLOCK|UNRELIABLE", "findings_count": 0, "invalid_count": 0},
    "skeptic":  {"verdict": "PASS|WARN|BLOCK|UNRELIABLE", "findings_count": 0, "invalid_count": 0}
  },
  "round_2": null,
  "escalation_reason": "gap_2|null",
  "codex_invoked": false,
  "codex_status": "ok|not_installed|auth_expired|error|skipped",
  "codex_tiebreaker": null,
  "final_verdict": "PASS|WARN|BLOCK|SKIPPED|ABORTED|UNRELIABLE",
  "findings_total": 0,
  "findings_verified": 0,
  "findings": [],
  "out_of_scope_warnings": [],
  "unreliable_agents": [],
  "unreliable_round2_agents": [],
  "refuted_findings": [],
  "disputed_refutals": [],
  "override": null,
  "diff_sha": "..."
}
```

For `round_2`: same structure as `round_1` when Round 2 was executed, `null` otherwise.
For `codex_tiebreaker`: `{"input": "...", "output": "...", "verdict": "..."}` when invoked, `null` otherwise.
For `override`: `{"rationale": "...", "timestamp": "..."}` when user overrides BLOCK, `null` otherwise.
For `refuted_findings`: array of `{"index": N, "rationale_reviewer": "...", "rationale_skeptic": "..."}` — only when BOTH agents agreed to refute.
For `disputed_refutals`: array of `{"index": N, "agent": "reviewer|skeptic", "rationale": "..."}` — single-agent refutals (informational, finding kept).
For `unreliable_round2_agents`: array of agent names flagged UNRELIABLE in Round 2 (separate from Round 1 `unreliable_agents`).

2. **Write `.dev/review-verdict.md`** (human-readable):
```
## Review Verdict: {PASS|WARN|BLOCK|SKIPPED|ABORTED|UNRELIABLE}

**Strategy:** {strategy}
**Rounds:** {N}
**Codex tiebreaker:** {yes|no}

### Findings ({total} total, {verified} verified)
| # | Sev | Cat | File:Line | Claim | Source | Verified |
|---|-----|-----|-----------|-------|--------|----------|
...

### Out-of-Scope Warnings
| File:Line | Claim | Source |
|-----------|-------|--------|
...

### Verdict Reasoning
{verdict_reasoning}
```

3. **Present to user:**
   - **PASS** → proceed automatically to Step 3.9
   - **WARN** → "Review found warnings. Proceed? (yes / fix / abort)"
   - **BLOCK** → "Review found blocking issues. Type override rationale to proceed, or: fix / abort"
     - If user types rationale: log `{"rationale": "<text>", "timestamp": "<ISO>"}` to `review-summary.json` under `override` field, then proceed
   - **SKIPPED** → proceed to Step 3.9
   - **ABORTED** → STOP
   - **UNRELIABLE** → should not reach 3.8e (handled in Step 3.8b). If it does: treat as BLOCK
   - **"fix"** action → write `"review_retry": 1` to `.dev/scope.json` (if not already present). If `review_retry` already exists → do NOT allow another fix: "Already retried once. Override with rationale, or abort." Otherwise re-run from Step 3.8.

**Step 3.9 — Post-check:**
```bash
RISK=$(jq -r '.risk' .dev/scope.json)

# Observer is required for medium/high risk — file must exist:
if [ "$RISK" = "medium" ] || [ "$RISK" = "high" ]; then
  if [ ! -f .dev/observer-report.md ]; then
    echo "FAIL: Observer report missing for $RISK-risk build"
    exit 1
  fi
  # PASS and WARN always proceed. STOP proceeds only if user approved in Step 3.7.
  grep -qE 'Verdict:.*(PASS|WARN|STOP)' .dev/observer-report.md || \
    { echo "Observer verdict is BLOCK — review required"; exit 1; }
fi

# Review verdict must exist and contain a valid verdict line
if [ ! -f .dev/review-verdict.md ]; then
  echo "FAIL: review-verdict.md missing"
  exit 1
fi
if ! grep -qE 'Review Verdict:.*(PASS|WARN|BLOCK|SKIPPED|ABORTED|UNRELIABLE)' .dev/review-verdict.md; then
  echo "FAIL: review-verdict.md has no valid verdict (PASS/WARN/BLOCK/SKIPPED/UNRELIABLE)"
  exit 1
fi

# Tests must have been recorded:
if [ -f .dev/test-results.txt ]; then
  tail -1 .dev/test-results.txt
fi
```
For low-risk: observer is not expected, post-check passes automatically.
For medium/high: observer report MUST exist — if the observer agent failed to produce it, the post-check fails.
BLOCK is the only verdict that hard-fails. STOP is handled interactively in Step 3.7 before reaching here.

**Step 3.10 — Archive run artifacts:**
```bash
STARTED_AT=$(jq -r '.started_at' .dev/scope.json | tr ':' '-' | tr 'T' '_' | tr -d 'Z')
if [ -z "$STARTED_AT" ] || [ "$STARTED_AT" = "null" ]; then STARTED_AT="unknown"; fi
mkdir -p ".dev/runs/$STARTED_AT"
cp .dev/scope.json .dev/exploration.md .dev/design.md ".dev/runs/$STARTED_AT/" 2>/dev/null
[ -f .dev/observer-report.md ] && cp .dev/observer-report.md ".dev/runs/$STARTED_AT/"
[ -f .dev/test-results.txt ] && cp .dev/test-results.txt ".dev/runs/$STARTED_AT/"
[ -f .dev/file-ownership.json ] && cp .dev/file-ownership.json ".dev/runs/$STARTED_AT/"
# Archive review artifacts
[ -f .dev/review-summary.json ] && cp .dev/review-summary.json ".dev/runs/$STARTED_AT/"
[ -f .dev/review-verdict.md ] && cp .dev/review-verdict.md ".dev/runs/$STARTED_AT/"
[ -f .dev/review-diff.txt ] && cp .dev/review-diff.txt ".dev/runs/$STARTED_AT/"
for f in .dev/reviewer-round-*.json .dev/skeptic-round-*.json .dev/review-round-*-validated.json; do
  [ -f "$f" ] && cp "$f" ".dev/runs/$STARTED_AT/"
done
```

**Step 3.11 — Present final summary to user:**

```
## Build Complete

**Feature:** <feature>
**Branch:** feat/<name>
**Files changed:** <list from git diff --name-only base_ref..HEAD>
**Tests:** PASS | FAIL | not run
**Scope creep:** none | WARN: N extra files
**Observer verdict:** PASS | WARN | STOP | N/A
**Review verdict:** PASS | WARN | BLOCK | SKIPPED | N/A
**Review strategy:** simple | adversarial | consensus
**Review rounds:** 1 | 2 | N/A
**Codex tiebreaker:** yes | no | N/A
**Run archived:** .dev/runs/<started_at>/

### Next Steps
- Review changes: git diff <base_ref>..HEAD
- Run tests manually if needed
- Create PR when ready: gh pr create --base <base_ref>
```

---

## Appendix: Observer Prompt Loading

The observer prompt for Step 3.6 is loaded via static injection:

@${CLAUDE_PLUGIN_ROOT}/lib/prompts/observer-body.md

Before passing to the observer subagent (`subagent_type="general-purpose"`, `model="sonnet"`), substitute these placeholders in the loaded text:
- `<DESIGN_PATH>` → `.dev/design.md`
- `<BASE_REF>` → value from `scope.json` (e.g., `main`)
- `<SCOPE>` → `all`

NOTE: This prompt uses `DESIGN_PATH` (not `PLAN_PATH`) because in the sigil workflow, `.dev/design.md` serves as both plan and design document. The standalone agent at `agents/observer.md` has a different variable contract — see the cross-reference comment in each file.

---

*End of sigil command.*
