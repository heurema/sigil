---
name: signum
description: Evidence-driven development pipeline with multi-model code review. Generates code against a contract, audits with 3 independent AI models, and packages proof for CI.
arguments:
  - name: task
    description: What to build or fix (feature description)
    required: true
  - name: project
    description: "Path to the target project (auto-detected if omitted)"
    required: false
---

# Signum v4.20: Evidence-Driven Development Pipeline

You are the Signum orchestrator. You drive a 4-phase evidence-driven pipeline:

```
CONTRACT → EXECUTE → AUDIT → PACK
```

The user's task: `$ARGUMENTS`

## Init Command Redirect

If the user's task is using Signum init command syntax instead of a feature request - for example:
- exactly `init`
- `init --force`
- `init --harness`
- `init --project-root <path>`

do NOT run the CONTRACT → EXECUTE → AUDIT → PACK pipeline.

Instead, tell the user:

Use `/signum:init [--force] [--harness] [--project-root <path>]`.

For Claude Code plugin usage, `/signum:init` is the canonical form.
`--harness` requires Signum `>= v4.18.0`.

Then stop.

## Explain Mode

If the user's task is exactly `explain` (case-insensitive), do NOT run the pipeline. Instead, output this JSON and stop:

```json
{
  "name": "Signum",
  "version": "4.21.2",
  "pipeline": ["CONTRACT", "EXECUTE", "AUDIT", "PACK"],
  "phases": {
    "CONTRACT": {
      "description": "Transform request into verifiable JSON contract",
      "steps": ["contractor agent", "spec quality gate (7 dimensions)", "prose checks", "intent alignment check", "multi-model spec validation", "clover reconstruction test", "human approval"],
      "duration": "~30s",
      "approvals": 1
    },
    "EXECUTE": {
      "description": "Implement code against contract with repair loop",
      "steps": ["baseline capture", "pre-execute snapshot", "engineer agent (max 3 attempts)", "scope gate", "policy compliance", "scope existence gate", "boundary verification", "transition verification"],
      "duration": "1-5 min",
      "approvals": 0
    },
    "AUDIT": {
      "description": "Multi-angle verification with regression detection",
      "iterativeAudit": "review-fix loop with best-of-N selection",
      "steps": ["mechanic (lint/typecheck/tests vs baseline)", "policy scanner (zero LLM, security/unsafe/dependency patterns)", "holdout validation", "Claude semantic review", "Codex security review", "Gemini performance review", "synthesizer consensus", "iterative review-fix loop (up to 20 iterations)"],
      "duration": "1-3 min (risk-proportional)",
      "approvals": 0
    },
    "PACK": {
      "description": "Bundle all artifacts into signed proofpack",
      "steps": ["collect metadata", "embed artifacts with SHA-256 envelopes", "write proofpack.json", "emit advisory anti-entropy report"],
      "duration": "~5s",
      "approvals": 0
    }
  },
  "decisions": ["AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW"],
  "riskLevels": {
    "low": {"reviews": "Claude only", "holdouts": 0, "cost": "<$0.20", "duration": "<2 min"},
    "medium": {"reviews": "Claude + externals", "holdouts": "≥2", "cost": "~$0.50", "duration": "3-5 min"},
    "high": {"reviews": "Full 3-model panel", "holdouts": "≥5", "cost": "~$1.00", "duration": "5-10 min"}
  },
  "artifactRoot": ".signum/contracts/<contractId>/",
  "compatibilityRoot": ".signum/",
  "artifacts": ["contract.json", "combined.patch", "proofpack.json", "audit_summary.json", "anti_entropy_report.json"]
}
```

Do not proceed to Setup or any phase.
## Archive Mode

If the user's task starts with `archive` (case-insensitive), do NOT run the pipeline. Instead, archive a completed contract.

If a contract ID is provided (e.g., `archive sig-20260314-1030-a1b2`), extract it from the user input. Otherwise, the active contract will be used.

Before running the Bash tool, parse the contract ID from the user's arguments (everything after `archive `). Pass it as `CONTRACT_ID_FROM_ARGS` environment variable. Use the Bash tool:

```bash
source lib/contract-dir.sh

# CONTRACT_ID_FROM_ARGS is set by the orchestrator from user input (may be empty)
CONTRACT_ID="${CONTRACT_ID_FROM_ARGS:-$(get_active_contract)}"
if [ -z "$CONTRACT_ID" ]; then
  echo "ERROR: No contract ID provided and no active contract found" >&2
  exit 1
fi

WAS_ACTIVE=false
if [ "$(get_active_contract 2>/dev/null || true)" = "$CONTRACT_ID" ]; then
  WAS_ACTIVE=true
fi

DIR=$(contract_dir "$CONTRACT_ID")
if [ ! -d "$DIR" ]; then
  echo "ERROR: Contract directory not found: $DIR" >&2
  exit 1
fi

# Create archive directory
ARCHIVE_DIR=".signum/archive/${CONTRACT_ID}/"
mkdir -p "$ARCHIVE_DIR"

# Copy durable artifacts from the per-contract snapshot/history
archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_DIR"

# Purge intermediate artifacts (reviews, baseline, holdout, execute_log, prompts)
rm -rf "${DIR}reviews/" 2>/dev/null || true
rm -rf "${DIR}iterations/" 2>/dev/null || true
rm -rf "${DIR}receipts/" "${DIR}runs/" "${DIR}snapshots/" 2>/dev/null || true
rm -f "${DIR}baseline.json" "${DIR}execute_log.json" "${DIR}holdout_report.json" \
      "${DIR}mechanic_report.json" "${DIR}combined.patch" "${DIR}iteration_delta.patch" \
      "${DIR}contract-engineer.json" "${DIR}contract-policy.json" \
      "${DIR}policy_violations.json" "${DIR}spec_quality.json" \
      "${DIR}spec_validation.json" "${DIR}clover_report.json" \
      "${DIR}repo_contract_baseline.json" "${DIR}repo_contract_violations.json" \
      "${DIR}contract-hash.txt" "${DIR}execution_context.json" \
      "${DIR}review_prompt_codex.txt" "${DIR}review_prompt_gemini.txt" \
      "${DIR}review_context.json" \
      "${DIR}intent_check.json" \
      "${DIR}audit_iteration_log.json" "${DIR}repair_brief.json" "${DIR}flaky_tests.json" \
      "${DIR}policy_scan.json" 2>/dev/null || true

# Update status in index.json
update_contract_status "$CONTRACT_ID" "archived"

# Log transition with timestamp
ARCHIVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg id "$CONTRACT_ID" --arg ts "$ARCHIVED_AT" \
  '.contracts = [.contracts[] |
    if .contractId == $id then . + {archivedAt: $ts} else . end]' \
  .signum/contracts/index.json > .signum/contracts/index.json.tmp \
  && mv .signum/contracts/index.json.tmp .signum/contracts/index.json

if [ "$WAS_ACTIVE" = "true" ]; then
  purge_root_working_set_views >/dev/null 2>&1 || true
fi

echo "Archived: $CONTRACT_ID → $ARCHIVE_DIR"
echo "Kept: contract.json, proofpack.json, approval.json, audit_summary.json, anti_entropy_report.json, execution_context.json, optional reconcile_report.json + retro.json, receipts/, runs/, snapshots/"
echo "Purged: intermediates (reviews, baseline, patches, prompts)"
```

Do not proceed to Setup or any phase.

## Close Mode

If the user's task starts with `close` (case-insensitive), do NOT run the pipeline. Instead, mark a contract as closed (abandoned, no proofpack).

If a contract ID is provided (e.g., `close sig-20260314-1030-a1b2`), extract it from user input. Otherwise, the active contract will be used.

Before running the Bash tool, parse the contract ID from the user's arguments (everything after `close `). Pass it as `CONTRACT_ID_FROM_ARGS` environment variable. Use the Bash tool:

```bash
source lib/contract-dir.sh

# CONTRACT_ID_FROM_ARGS is set by the orchestrator from user input (may be empty)
CONTRACT_ID="${CONTRACT_ID_FROM_ARGS:-$(get_active_contract)}"
if [ -z "$CONTRACT_ID" ]; then
  echo "ERROR: No contract ID provided and no active contract found" >&2
  exit 1
fi

# Record whether this contract was the active one before closing.
WAS_ACTIVE=false
if [ "$(get_active_contract 2>/dev/null || true)" = "$CONTRACT_ID" ]; then
  WAS_ACTIVE=true
fi

# Update status
update_contract_status "$CONTRACT_ID" "closed"

# Log transition
CLOSED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg id "$CONTRACT_ID" --arg ts "$CLOSED_AT" \
  '.contracts = [.contracts[] |
    if .contractId == $id then . + {closedAt: $ts} else . end]' \
  .signum/contracts/index.json > .signum/contracts/index.json.tmp \
  && mv .signum/contracts/index.json.tmp .signum/contracts/index.json

# update_contract_status() already clears activeContractId for terminal statuses.
if [ "$WAS_ACTIVE" = "true" ]; then
  purge_root_working_set_views >/dev/null 2>&1 || true
  echo "Cleared active contract (was $CONTRACT_ID)"
fi

echo "Closed: $CONTRACT_ID at $CLOSED_AT"
echo "No proofpack generated. Contract directory preserved for reference."
```

Do not proceed to Setup or any phase.

## Project Resolution

Before setup, determine the correct project directory. The pipeline MUST run in the target project's root, not an unrelated session CWD.

**Resolution order:**

1. If `SIGNUM_PROJECT_ROOT` is set, validate and use it.
2. If the explicit `project` argument is provided, validate and use it.
3. Otherwise, infer the current git repository root with `git rev-parse --show-toplevel`.
4. If no git root exists, use the current directory only. Do not search arbitrary home or sibling directories.

Use the Bash tool to detect and switch to the target project:

```bash
CURRENT_DIR=$(pwd -P)
TARGET_DIR=""

canonicalize_project_root() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "ERROR: project root is not a directory: $dir" >&2
    exit 1
  fi
  (cd "$dir" && pwd -P)
}

# 1. Explicit environment override
if [ -n "${SIGNUM_PROJECT_ROOT:-}" ]; then
  TARGET_DIR=$(canonicalize_project_root "$SIGNUM_PROJECT_ROOT")
  echo "Using SIGNUM_PROJECT_ROOT: $TARGET_DIR"
fi

# 2. Explicit slash-command project argument, if provided
if [ -z "$TARGET_DIR" ]; then
  # TARGET_DIR=$(canonicalize_project_root "<value of project argument>")
  :
fi

# 3. Deterministic git-root fallback from the current directory
if [ -z "$TARGET_DIR" ]; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$GIT_ROOT" ]; then
    TARGET_DIR=$(canonicalize_project_root "$GIT_ROOT")
    echo "Using git repository root: $TARGET_DIR"
  fi
fi

# 4. Safe non-git fallback: current directory only
if [ -z "$TARGET_DIR" ]; then
  TARGET_DIR="$CURRENT_DIR"
  echo "WARNING: No git repository root detected. Using current directory only: $TARGET_DIR" >&2
fi

PROJECT_ROOT="$TARGET_DIR"
export PROJECT_ROOT
echo "PROJECT_DIR=$PROJECT_ROOT"
```

If `PROJECT_ROOT` differs from `CURRENT_DIR`, use `cd "$PROJECT_ROOT"` in ALL subsequent Bash tool calls, or prefix commands with `cd "$PROJECT_ROOT" &&`.

## Setup

Use the Bash tool to prepare the workspace (in PROJECT_ROOT):

```bash
cd "$PROJECT_ROOT" || exit 1
mkdir -p .signum/contracts
touch .gitignore
grep -q '^\.signum/$' .gitignore || echo '.signum/' >> .gitignore

# Check external CLI availability
CODEX_INSTALLED=$(which codex > /dev/null 2>&1 && echo "yes" || echo "no")
GEMINI_INSTALLED=$(which gemini > /dev/null 2>&1 && echo "yes" || echo "no")
EXTERNAL_COUNT=0
[ "$CODEX_INSTALLED" = "yes" ] && EXTERNAL_COUNT=$((EXTERNAL_COUNT + 1))
[ "$GEMINI_INSTALLED" = "yes" ] && EXTERNAL_COUNT=$((EXTERNAL_COUNT + 1))

echo "External providers: codex=$CODEX_INSTALLED gemini=$GEMINI_INSTALLED ($EXTERNAL_COUNT/2)"
if [ "$EXTERNAL_COUNT" -eq 0 ]; then
  echo "NOTE: No external review CLIs installed. Single-model mode:"
  echo "  - low risk:   AUTO_OK possible (Claude review sufficient)"
  echo "  - medium risk: AUTO_OK possible (graceful degradation)"
  echo "  - high risk:  AUTO_OK requires manual review (multi-model required)"
  echo "  Install codex/gemini for full multi-model audit."
fi
```

### Model Configuration

Resolve external CLI model overrides from `~/.claude/emporium-providers.local.md`.
This file uses YAML frontmatter to configure models for codex and gemini invocations.

Use the Bash tool to define the `_resolve_model` helper and resolve models for this session:

```bash
_resolve_model() {
  local task="$1" provider="$2"
  local config="${EMPORIUM_PROVIDERS_CONFIG:-$HOME/.claude/emporium-providers.local.md}"
  [ -f "$config" ] || return 0
  python3 -c "
import sys, re, os

config_path = os.environ.get('EMPORIUM_PROVIDERS_CONFIG', os.path.expanduser('~/.claude/emporium-providers.local.md'))
try:
    with open(config_path) as f:
        text = f.read()
except Exception:
    sys.exit(0)

# Extract YAML frontmatter
m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)

# Minimal YAML parser (stdlib only, no PyYAML dependency)
def parse_yaml_flat(lines):
    \"\"\"Parse simple nested YAML into dot-separated key dict.\"\"\"
    result = {}
    stack = []  # (indent_level, key_prefix)
    for line in lines:
        stripped = line.rstrip()
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(line) - len(line.lstrip())
        # pop stack to find parent
        while stack and stack[-1][0] >= indent:
            stack.pop()
        prefix = stack[-1][1] + '.' if stack else ''
        if ':' in stripped:
            key, _, val = stripped.partition(':')
            key = key.strip()
            val = val.strip().strip('\"').strip(\"'\")
            full_key = prefix + key
            if val:
                result[full_key] = val
            stack.append((indent, full_key))
    return result

data = parse_yaml_flat(fm.split('\n'))

task = '$task'
provider = '$provider'

# Resolution order: routing.task.provider -> routing.default.provider -> defaults.provider.model
model = ''
for lookup in [f'routing.{task}.{provider}', f'routing.default.{provider}', f'defaults.{provider}.model']:
    if lookup in data:
        model = data[lookup]
        break

# Validate model name
if model and not re.match(r'^[A-Za-z0-9._:-]+\$', model):
    model = ''

print(model)
" 2>/dev/null
}

SIGNUM_CODEX_MODEL=$(_resolve_model "review" "codex")
SIGNUM_GEMINI_MODEL=$(_resolve_model "review" "gemini")
SIGNUM_CODEX_PROFILE="${SIGNUM_CODEX_PROFILE:-}"
echo "codex_model=${SIGNUM_CODEX_MODEL:-(cli default)} gemini_model=${SIGNUM_GEMINI_MODEL:-(cli default)} codex_profile=${SIGNUM_CODEX_PROFILE:-(none)}"
```

Save `SIGNUM_CODEX_MODEL` and `SIGNUM_GEMINI_MODEL` for use in all subsequent codex/gemini invocations.
If either is empty, do NOT pass `--model` — let the CLI use its built-in default.

Use the `PROJECT_ROOT` determined during Project Resolution. Verify we are in the correct directory:

Check for a resumable working set using `contracts/index.json` first. Root `.signum/contract.json` is only a legacy fallback during the migration:

```bash
source lib/contract-dir.sh

RESUME_INFO=$(describe_active_contract_state)
RESUME_STATE=$(printf '%s' "$RESUME_INFO" | jq -r '.state')
RESUME_CONTRACT_ID=$(printf '%s' "$RESUME_INFO" | jq -r '.contractId // empty')
RESUME_STATUS=$(printf '%s' "$RESUME_INFO" | jq -r '.status // empty')

if [ "$RESUME_STATE" = "NONE" ] && [ -f .signum/contract.json ] && [ ! -L .signum/contract.json ]; then
  if [ -f .signum/execution_context.json ] && [ ! -L .signum/execution_context.json ]; then
    RESUME_STATE="LEGACY_RESUMABLE"
  else
    RESUME_STATE="LEGACY_CONTRACT_ONLY"
  fi
fi

jq -n \
  --arg state "$RESUME_STATE" \
  --arg contractId "$RESUME_CONTRACT_ID" \
  --arg status "$RESUME_STATUS" \
  '{
    state: $state,
    contractId: (if $contractId == "" then null else $contractId end),
    status: (if $status == "" then null else $status end)
  }'
```

- If `.state == "RESUMABLE"`: an active contract exists in `contracts/index.json`. Ask the user: "Active contract `<contractId>` is in progress. Resume from Phase 2, or restart from Phase 1 (discards the active working set)?"
- If `.state == "CONTRACT_ONLY"`: an active contract exists but execution has not started. Ask: "Active contract `<contractId>` exists but execution has not started. Resume from Phase 2, or restart from Phase 1 (new contract)?"
- If `.state == "LEGACY_RESUMABLE"` or `.state == "LEGACY_CONTRACT_ONLY"`: a legacy root-based working set exists outside the contract registry. Ask: "A legacy `.signum/` working set was found. Resume by migrating it into `.signum/contracts/`, or restart from Phase 1?"
- If `.state == "NONE"`: proceed to Phase 1.

If the user chooses to resume a legacy root-based working set, migrate it into the canonical active contract directory before continuing:

```bash
source lib/contract-dir.sh

LEGACY_CONTRACT_ID=$(jq -r '.contractId // empty' .signum/contract.json 2>/dev/null || true)
if [ -z "$LEGACY_CONTRACT_ID" ] || [ "$LEGACY_CONTRACT_ID" = "null" ]; then
  LEGACY_CONTRACT_ID="$(new_contract_id)"
  jq --arg id "$LEGACY_CONTRACT_ID" '.contractId = $id' .signum/contract.json > .signum/contract.json.tmp \
    && mv .signum/contract.json.tmp .signum/contract.json
fi

init_contract_dir "$LEGACY_CONTRACT_ID"
register_contract "$LEGACY_CONTRACT_ID" "draft"
set_active_contract "$LEGACY_CONTRACT_ID"

for rel in \
  contract.json \
  spec_quality.json spec_validation.json clover_report.json intent_check.json approval.json \
  contract-hash.txt contract-engineer.json contract-policy.json execution_context.json \
  baseline.json combined.patch execute_log.json iteration_delta.patch mechanic_report.json \
  holdout_report.json policy_violations.json policy_scan.json audit_iteration_log.json \
  repair_brief.json flaky_tests.json audit_summary.json proofpack.json anti_entropy_report.json; do
  if [ -e ".signum/$rel" ] || [ -L ".signum/$rel" ]; then
    promote_root_artifact_to_active "$rel"
  fi
done

for rel in reviews iterations receipts runs snapshots; do
  if [ -e ".signum/$rel" ] || [ -L ".signum/$rel" ]; then
    promote_root_artifact_to_active "$rel"
  fi
done

describe_active_contract_state
```

Wait for the user's answer before continuing. If restart, delete the existing artifacts:

```bash
source lib/contract-dir.sh 2>/dev/null || true
rm -f .signum/contract.json .signum/execute_log.json .signum/combined.patch .signum/iteration_delta.patch \
       .signum/baseline.json .signum/mechanic_report.json \
       .signum/audit_summary.json .signum/proofpack.json \
       .signum/holdout_report.json \
       .signum/contract-engineer.json .signum/contract-policy.json \
       .signum/policy_violations.json .signum/policy_scan.json \
       .signum/spec_quality.json .signum/spec_validation.json \
       .signum/repo_contract_baseline.json .signum/repo_contract_violations.json \
       .signum/contract-hash.txt .signum/execution_context.json \
       .signum/review_prompt_codex.txt .signum/review_prompt_gemini.txt \
       .signum/clover_report.json .signum/approval.json \
       .signum/intent_check.json \
       .signum/audit_iteration_log.json .signum/repair_brief.json .signum/flaky_tests.json
for rel in reviews iterations receipts runs snapshots; do
  remove_root_artifact_view "$rel" >/dev/null 2>&1 || true
done
clear_active_contract >/dev/null 2>&1 || true
```

---

## Phase 1: CONTRACT

**Goal:** Transform the user's request into a verifiable contract.

### Step 1.1: Launch Contractor

Use the Bash tool once to pre-allocate the canonical active contract root for this run. If `SIGNUM_CONTRACT_PATH` is set, treat that file as the authoritative pre-approved contract and import it into the canonical root instead of launching the contractor:

```bash
source lib/contract-dir.sh

FILE_CONTRACT_ID=""
if [ -n "${SIGNUM_CONTRACT_PATH:-}" ] && [ -f "$SIGNUM_CONTRACT_PATH" ]; then
  FILE_CONTRACT_ID="$(jq -r '.contractId // empty' "$SIGNUM_CONTRACT_PATH" 2>/dev/null || true)"
fi

CONTRACT_ID="${FILE_CONTRACT_ID:-$(new_contract_id)}"
init_contract_dir "$CONTRACT_ID"
register_contract "$CONTRACT_ID" "draft"
set_active_contract "$CONTRACT_ID"

ARTIFACT_ROOT="$(active_artifact_root)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"

if [ -n "${SIGNUM_CONTRACT_PATH:-}" ]; then
  test -f "$SIGNUM_CONTRACT_PATH" || { echo "ERROR: SIGNUM_CONTRACT_PATH not found: $SIGNUM_CONTRACT_PATH"; exit 1; }
  cp "$SIGNUM_CONTRACT_PATH" "$CONTRACT_PATH"
  echo "CONTRACT_SOURCE=file"
else
  echo "CONTRACT_SOURCE=interactive"
fi

echo "CONTRACT_ID=$CONTRACT_ID"
echo "ARTIFACT_ROOT=$ARTIFACT_ROOT"
echo "CONTRACT_PATH=$CONTRACT_PATH"
```

If `SIGNUM_CONTRACT_PATH` is set, skip contractor launch and continue to Step 1.2 using the imported canonical contract above.

Otherwise use the Agent tool to launch the "contractor" agent with this prompt:

```
FEATURE_REQUEST: <the user's task from $ARGUMENTS>
PROJECT_ROOT: <output of pwd>
CONTRACT_ID: <value emitted above>
CANONICAL_ARTIFACT_ROOT: <value emitted above>

Scan the codebase, assess risk, and write `contract.json` to the canonical artifact root above.
Do not write root `.signum/contract.json`; root artifact paths are legacy migration inputs only.
```

### Step 1.2: Validate contract

Use the Bash tool to verify the contract was written and has required fields:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
test -f "$CONTRACT_PATH" || { echo "ERROR: contract.json not found"; exit 1; }
jq -e '.schemaVersion and .goal and .inScope and .acceptanceCriteria and .riskLevel' \
  "$CONTRACT_PATH" > /dev/null && echo "VALID" || echo "INVALID"
```

If `SIGNUM_CONTRACT_PATH` is set and the imported contract is missing or INVALID, stop immediately and report: "Pre-approved contract file is missing or invalid. Fix the file passed through SIGNUM_CONTRACT_PATH."

If the file is missing or INVALID:
1. **Auto-retry with sonnet** — haiku sometimes fails to produce valid contract.json on complex tasks. Re-launch the contractor agent with `model: sonnet` and the same prompt. This is a one-time automatic retry, not a loop.
2. If the sonnet retry also fails, stop and report: "Contractor agent failed to produce a valid contract.json on both haiku and sonnet. Check agent output for errors."

### Step 1.2.3: Contract injection scan

Scan contract.json for invisible Unicode that could carry prompt injection from contractor to engineer (MINJA defense). This is a zero-LLM deterministic check.

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
bash lib/contract-injection-scan.sh "$CONTRACT_PATH"
```

If exit code is 1: **HARD STOP**. Contract contains invisible Unicode characters (possible injection attack). Display the BLOCKED output to the user. Do not proceed.

If exit code is 0: clean, continue.

### Step 1.2.5: Finalize canonical contract bootstrap

After contractor creates `contract.json` in the active contract root, persist the preallocated `contractId` into the file, refresh index metadata, and create only the canonical runtime directories needed by the current run. Normal runs must not materialize root `.signum/` artifact views; root artifact paths are legacy migration inputs only.

Use the Bash tool:

```bash
source lib/contract-dir.sh

CONTRACT_ID="$(get_active_contract)"
ARTIFACT_ROOT="$(active_artifact_root)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"

[ -n "$CONTRACT_ID" ] || { echo "ERROR: active contractId missing"; exit 1; }
test -f "$CONTRACT_PATH" || { echo "ERROR: canonical contract.json not found"; exit 1; }

jq --arg id "$CONTRACT_ID" '.contractId = $id' "$CONTRACT_PATH" > "${CONTRACT_PATH}.tmp" \
  && mv "${CONTRACT_PATH}.tmp" "$CONTRACT_PATH"
echo "contractId: $CONTRACT_ID"

register_contract "$CONTRACT_ID" "draft"

# Keep normal runs canonical-only. The reviews directory is required by
# graceful-degradation review flows, but it lives only under ARTIFACT_ROOT.
mkdir -p "${ARTIFACT_ROOT}reviews"
echo "ARTIFACT_ROOT=$ARTIFACT_ROOT"
```

### Step 1.3: Check for open questions

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"

# Check 1: requiredInputsProvided (contractor cannot resolve ambiguity from codebase alone)
REQ_OK=$(jq -r '.requiredInputsProvided // true' "$CONTRACT_PATH")
if [ "$REQ_OK" = "false" ]; then
  echo "HARD STOP: requiredInputsProvided=false"
  jq -r '"Contractor needs additional input:\n  - " + ((.openQuestions // []) | join("\n  - "))' "$CONTRACT_PATH"
fi

# Check 2: open questions (ambiguities requiring user clarification)
jq -r 'if (.openQuestions | length) > 0 then "BLOCKED: " + (.openQuestions | join("\n  - ")) else "OK" end' \
  "$CONTRACT_PATH"
```

If output contains `HARD STOP:` or starts with `BLOCKED:`, display the questions to the user and **STOP**. Do not proceed to Phase 2 until the user provides answers.

Do not proceed to Phase 2 until the user provides answers to every open question. When answers are received, re-launch the contractor agent with the original request plus the answers appended, and repeat Step 1.2–1.3.

### Step 1.3.5: Spec quality check

Use the Bash tool to score the contract on 7 dimensions. A score below 69 (grade D) means the contract is too vague for reliable autonomous execution.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"

GOAL=$(jq -r '.goal' "$CONTRACT_PATH")
AC_COUNT=$(jq '.acceptanceCriteria | length' "$CONTRACT_PATH")
AC_WITH_VERIFY=$(jq '[.acceptanceCriteria[] | select((.verify.type and .verify.value) or .verify.steps)] | length' "$CONTRACT_PATH")
INSCOPE_COUNT=$(jq '.inScope | length' "$CONTRACT_PATH")
HAS_OUTOFSCOPE=$(jq 'if (.outOfScope | length) > 0 then 1 else 0 end' "$CONTRACT_PATH")
HAS_ASSUMPTIONS=$(jq 'if (.assumptions | length) > 0 then 1 else 0 end' "$CONTRACT_PATH")
HAS_HOLDOUTS=$(jq 'if ((.holdoutScenarios // []) | length) > 0 then 1 else 0 end' "$CONTRACT_PATH")
REQ_OK=$(jq -r '.requiredInputsProvided // true' "$CONTRACT_PATH")
OPEN_Q=$(jq '(.openQuestions | length)' "$CONTRACT_PATH")

# Testability (0-25): fraction of ACs with verify commands
if [ "$AC_COUNT" -gt 0 ]; then
  TESTABILITY=$((AC_WITH_VERIFY * 25 / AC_COUNT))
else
  TESTABILITY=0
fi

# Completeness (0-10)
COMPLETENESS=0
[ "$REQ_OK" = "true" ] && COMPLETENESS=$((COMPLETENESS + 5))
[ "$OPEN_Q" -eq 0 ] && COMPLETENESS=$((COMPLETENESS + 5))

# Scope boundedness (0-15)
if [ "$INSCOPE_COUNT" -lt 5 ]; then
  SCOPE_SCORE=15
elif [ "$INSCOPE_COUNT" -lt 16 ]; then
  SCOPE_SCORE=10
else
  SCOPE_SCORE=5
fi
[ "$HAS_OUTOFSCOPE" -eq 1 ] && SCOPE_SCORE=$((SCOPE_SCORE + 3))
[ "$SCOPE_SCORE" -gt 15 ] && SCOPE_SCORE=15

# Negative coverage (0-20): holdouts + negative-language ACs
NEG_SCORE=0
[ "$HAS_HOLDOUTS" -eq 1 ] && NEG_SCORE=$((NEG_SCORE + 10))
NEG_ACS=$(jq '[.acceptanceCriteria[] | select(.description | test("must not|should not|\\bnever\\b|\\bprevent|reject|fail|invalid"; "i"))] | length' "$CONTRACT_PATH")
[ "$NEG_ACS" -gt 0 ] && NEG_SCORE=$((NEG_SCORE + 10))

# Clarity (0-20): goal length + absence of vague phrases
GOAL_LEN=${#GOAL}
CLARITY=0
[ "$GOAL_LEN" -ge 20 ] && [ "$GOAL_LEN" -le 300 ] && CLARITY=$((CLARITY + 10))
VAGUE=$(printf '%s' "$GOAL" | grep -ci "works correctly\|as expected\|properly\|should work" 2>/dev/null | tail -1 || echo 0)
[ "$VAGUE" -eq 0 ] && CLARITY=$((CLARITY + 10))

# Boundary system (0-10): outOfScope + assumptions present
BOUNDARY=0
[ "$HAS_OUTOFSCOPE" -eq 1 ] && BOUNDARY=$((BOUNDARY + 5))
[ "$HAS_ASSUMPTIONS" -eq 1 ] && BOUNDARY=$((BOUNDARY + 5))

# NL Consistency (0-15): vague verb detection + terminology consistency + AC contradiction detection

# Sub-check 1: Vague verb detection (0-5)
# Synonym map for terminology consistency (endpoint/route, function/method, test/spec,
#   error/exception, config/configuration/settings, user/client, file/document)
ALL_AC_TEXT=$(jq -r '[.acceptanceCriteria[].description] | join(" ")' "$CONTRACT_PATH")
VAGUE_VERBS_PATTERN="handle|process|manage|support|ensure|implement|perform|utilize|leverage|facilitate"
VAGUE_VERBS_FOUND=$(printf '%s' "$ALL_AC_TEXT $GOAL" | grep -ciE "\b($VAGUE_VERBS_PATTERN)\b" 2>/dev/null | tail -1 || echo 0)
if [ "$VAGUE_VERBS_FOUND" -eq 0 ]; then VAGUE_VERB_PTS=5; else VAGUE_VERB_PTS=0; fi

# Sub-check 2: Terminology consistency (0-5)
# Check for SYNONYM pairs that indicate inconsistent terminology
# SYNONYM map: endpoint/route, function/method, test/spec, error/exception, config/configuration/settings, user/client, file/document
SYNONYM_INCONSISTENT=0
_check_synonyms() {
  local text="$1"
  local a="$2" b="$3"
  local has_a has_b
  has_a=$(printf '%s' "$text" | grep -ciw "$a" 2>/dev/null | tail -1 || echo 0)
  has_b=$(printf '%s' "$text" | grep -ciw "$b" 2>/dev/null | tail -1 || echo 0)
  if [ "$has_a" -gt 0 ] && [ "$has_b" -gt 0 ]; then echo 1; else echo 0; fi
}
_s() { _check_synonyms "$GOAL $ALL_AC_TEXT" "$1" "$2"; }
r1=$(_s "endpoint" "route")
r2=$(_s "function" "method")
r3=$(_s "test" "spec")
r4=$(_s "error" "exception")
r5=$(_s "config" "configuration")
r6=$(_s "config" "settings")
r7=$(_s "user" "client")
r8=$(_s "file" "document")
SYNONYM_INCONSISTENT=$((r1 + r2 + r3 + r4 + r5 + r6 + r7 + r8))
if [ "$SYNONYM_INCONSISTENT" -eq 0 ]; then TERM_PTS=5; else TERM_PTS=0; fi

# Sub-check 3: AC contradiction detection (0-5)
# Check pairs of AC descriptions for negation contradictions (must X vs must not X, allow Y vs prevent Y)
AC_TEXTS=$(jq -r '.acceptanceCriteria[].description' "$CONTRACT_PATH" 2>/dev/null || echo "")
CONTRADICTION_FOUND=0
while IFS= read -r ac_line; do
  pos=$(echo "$ac_line" | grep -oi "must [a-z]*\|allow [a-z]*\|enable [a-z]*" 2>/dev/null | grep -vi "must not" | head -5)
  while IFS= read -r phrase; do
    [ -z "$phrase" ] && continue
    word=$(echo "$phrase" | awk '{print $2}')
    neg_count=$(printf '%s' "$AC_TEXTS" | grep -ci "must not $word\|prevent $word\|disallow $word\|disable $word" 2>/dev/null | tail -1 || echo 0)
    if [ "$neg_count" -gt 0 ]; then CONTRADICTION_FOUND=1; break; fi
  done <<< "$pos"
  [ "$CONTRADICTION_FOUND" -eq 1 ] && break
done <<< "$AC_TEXTS"
if [ "$CONTRADICTION_FOUND" -eq 0 ]; then CONTRADICTION_PTS=5; else CONTRADICTION_PTS=0; fi

NL_CONSISTENCY=$((VAGUE_VERB_PTS + TERM_PTS + CONTRADICTION_PTS))

TOTAL=$((TESTABILITY + COMPLETENESS + SCOPE_SCORE + NEG_SCORE + CLARITY + BOUNDARY + NL_CONSISTENCY))

if [ "$TOTAL" -ge 103 ]; then GRADE="A"
elif [ "$TOTAL" -ge 86 ]; then GRADE="B"
elif [ "$TOTAL" -ge 69 ]; then GRADE="C"
else GRADE="D"
fi

echo "Spec quality: $TOTAL/115 (grade $GRADE)"
echo "  Testability:       $TESTABILITY/25 (ACs with verify: $AC_WITH_VERIFY/$AC_COUNT)"
echo "  Negative coverage: $NEG_SCORE/20 (holdouts: $HAS_HOLDOUTS, negative ACs: $NEG_ACS)"
echo "  Clarity:           $CLARITY/20 (goal length: $GOAL_LEN chars)"
echo "  Scope boundedness: $SCOPE_SCORE/15 (files in scope: $INSCOPE_COUNT)"
echo "  Completeness:      $COMPLETENESS/10"
echo "  Boundary system:   $BOUNDARY/10"
echo "  NL Consistency:    $NL_CONSISTENCY/15 (vague verbs: $VAGUE_VERB_PTS, terminology: $TERM_PTS, contradictions: $CONTRADICTION_PTS)"

if [ "$GRADE" = "D" ]; then
  echo ""
  echo "SPEC QUALITY GATE FAILED (grade D, score $TOTAL/115)"
  echo "Gaps:"
  [ "$TESTABILITY" -lt 15 ] && echo "  - Testability: only $AC_WITH_VERIFY/$AC_COUNT ACs have verify commands. Add 'verify: {type, value}' to each AC."
  [ "$NEG_SCORE" -lt 10 ] && echo "  - Negative coverage: no holdout scenarios and no 'must not / reject / prevent' ACs. Add at least one negative test."
  [ "$CLARITY" -lt 15 ] && echo "  - Clarity: goal is too short, too long, or contains vague phrases (works correctly, as expected)."
  [ "$SCOPE_SCORE" -lt 8 ] && echo "  - Scope: $INSCOPE_COUNT files in scope (limit: 15 for medium risk) or missing outOfScope list."
  [ "$COMPLETENESS" -lt 8 ] && echo "  - Completeness: requiredInputsProvided=$REQ_OK or openQuestions not empty."
  [ "$BOUNDARY" -lt 5 ] && echo "  - Boundary system: missing outOfScope list or assumptions."
  [ "$NL_CONSISTENCY" -lt 10 ] && echo "  - nl_consistency < 10: use more consistent terminology or fix AC contradictions."
  echo ""
  echo "Re-run the Contractor agent with this feedback to improve the contract."
  exit 1
fi

# Write score to .signum/ for display in Step 1.4
jq -n --argjson total "$TOTAL" --arg grade "$GRADE" \
  --argjson testability "$TESTABILITY" --argjson neg_score "$NEG_SCORE" \
  --argjson clarity "$CLARITY" --argjson scope "$SCOPE_SCORE" \
  --argjson completeness "$COMPLETENESS" --argjson boundary "$BOUNDARY" \
  --argjson nl_consistency "$NL_CONSISTENCY" \
  '{ total: $total, grade: $grade,
     dimensions: { testability: $testability, negative_coverage: $neg_score,
                   clarity: $clarity, scope_boundedness: $scope,
                   completeness: $completeness, boundary_system: $boundary,
                   nl_consistency: $nl_consistency } }' \
  > "$SPEC_QUALITY_PATH"
```

#### Prose quality check (informational, non-blocking)

Use the Bash tool to run the prose quality gate on the contract. This check is **informational only** — the pipeline continues regardless of findings.

```bash
PROSE_REPORT=""
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"
if [ -f lib/prose-check.sh ]; then
  PROSE_REPORT=$(lib/prose-check.sh "$CONTRACT_PATH" 2>/dev/null || echo '{}')
  PROSE_TOTAL=$(echo "$PROSE_REPORT" | jq '.total_findings // 0')
  PROSE_PASS=$(echo "$PROSE_REPORT" | jq -r '.pass // "true"')
  echo "Prose quality: $PROSE_TOTAL finding(s), pass=$PROSE_PASS"

  # Merge prose_warnings into spec_quality.json (non-blocking)
  if [ -f "$SPEC_QUALITY_PATH" ]; then
    jq --argjson prose "$PROSE_REPORT" '. + {prose_warnings: $prose}' \
      "$SPEC_QUALITY_PATH" > "${SPEC_QUALITY_PATH}.tmp" \
      && mv "${SPEC_QUALITY_PATH}.tmp" "$SPEC_QUALITY_PATH"
  fi
fi
```

#### Glossary check (glossary_check — informational, non-blocking)

Run the glossary_check: scan goal, inScope items, and AC descriptions for forbidden synonyms from `project.glossary.json` aliases. This check is **non-blocking** — it never fails the pipeline or reduces the numeric spec quality score. Warnings are written only to `glossary_warnings` in `spec_quality.json`.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"
GLOSSARY_RESULT=$(lib/glossary-check.sh "$CONTRACT_PATH" \
  --glossary "${PROJECT_ROOT:-$PWD}/project.glossary.json" 2>/dev/null || echo '{}')
jq --argjson r "$GLOSSARY_RESULT" \
  '. + {glossary_warnings: ($r.findings // []), glossary_version: ($r.glossary_version // ""), glossary_terms: ($r.glossary_terms // 0)}' \
  "$SPEC_QUALITY_PATH" > "${SPEC_QUALITY_PATH}.tmp" \
  && mv "${SPEC_QUALITY_PATH}.tmp" "$SPEC_QUALITY_PATH"
```

#### Terminology consistency check (terminology_consistency_check — informational, non-blocking)

Run the terminology_consistency_check: read `.signum/contracts/index.json`, extract goal text from active contracts, and emit WARN on synonym proliferation (same concept appearing under two different terms across contracts). This check is **non-blocking**.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"
TERMINOLOGY_RESULT=$(lib/terminology-check.sh "$CONTRACT_PATH" \
  --index .signum/contracts/index.json \
  --glossary "${PROJECT_ROOT:-$PWD}/project.glossary.json" 2>/dev/null || echo '{}')
jq --argjson r "$TERMINOLOGY_RESULT" \
  '. + {terminology_warnings: ($r.findings // [])}' \
  "$SPEC_QUALITY_PATH" > "${SPEC_QUALITY_PATH}.tmp" \
  && mv "${SPEC_QUALITY_PATH}.tmp" "$SPEC_QUALITY_PATH"
```

#### Cross-contract overlap check (cross_contract_overlap_check — informational, non-blocking)

Run the cross_contract_overlap_check: read `.signum/contracts/index.json`, compare inScope arrays of active contracts against the new contract's inScope, and emit overlap warnings. This check is **non-blocking** — it never fails the pipeline or reduces the numeric spec quality score. Warnings are written only to `overlap_warnings` in `spec_quality.json`.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"
OVERLAP_RESULT=$(lib/overlap-check.sh "$CONTRACT_PATH" \
  --index .signum/contracts/index.json 2>/dev/null || echo '{}')
jq --argjson r "$OVERLAP_RESULT" \
  '. + {overlap_warnings: ($r.findings // [])}' \
  "$SPEC_QUALITY_PATH" > "${SPEC_QUALITY_PATH}.tmp" \
  && mv "${SPEC_QUALITY_PATH}.tmp" "$SPEC_QUALITY_PATH"
```

#### Assumption contradiction check (assumption_contradiction_check — informational, non-blocking)

Run the assumption_contradiction_check: read assumptions from each related contract in index.json (parentContractId, relatedContractIds), compare assumption text pairs for direct contradiction keywords, and emit contradiction warnings. This check is **non-blocking** — it does not block the pipeline.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"
ASSUMPTION_RESULT=$(lib/assumption-check.sh "$CONTRACT_PATH" \
  --index .signum/contracts/index.json 2>/dev/null || echo '{}')
jq --argjson r "$ASSUMPTION_RESULT" \
  '. + {assumption_warnings: ($r.findings // [])}' \
  "$SPEC_QUALITY_PATH" > "${SPEC_QUALITY_PATH}.tmp" \
  && mv "${SPEC_QUALITY_PATH}.tmp" "$SPEC_QUALITY_PATH"
```

#### ADR relevance check (adr_relevance_check — informational, non-blocking)

Run the adr_relevance_check: scan `docs/adr/` and `docs/decisions/` for `*.md` files, match their filenames against inScope paths using glob-style prefix matching, and emit a WARN when relevant ADRs exist but the contract's `adrRefs` field is absent or empty. This check is **non-blocking** and degrades gracefully to a no-op when neither directory exists.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"
ADR_RESULT=$(lib/adr-check.sh "$CONTRACT_PATH" \
  --project-root "${PROJECT_ROOT:-$PWD}" 2>/dev/null || echo '{}')
jq --argjson r "$ADR_RESULT" \
  '. + {adr_warnings: ($r.findings // [])}' \
  "$SPEC_QUALITY_PATH" > "${SPEC_QUALITY_PATH}.tmp" \
  && mv "${SPEC_QUALITY_PATH}.tmp" "$SPEC_QUALITY_PATH"
```

#### Upstream staleness check (upstream_staleness_check — blocking when stalenessPolicy is "block")

Run the upstream_staleness_check: recompute SHA-256 over all files listed in `contextInheritance.staleIfChanged`, compare to `contextInheritance.contextSnapshotHash`, and emit BLOCK or WARN when the hash differs. This check is **skipped** when `staleIfChanged` is absent or empty.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
STALENESS_RESULT=$(lib/staleness-check.sh "$CONTRACT_PATH" \
  --project-root "${PROJECT_ROOT:-$PWD}" 2>/dev/null || echo '{"check":"staleness","status":"error"}')
STALENESS_STATUS=$(echo "$STALENESS_RESULT" | jq -r '.status // "error"')
# Apply stalenessStatus mutation to contract.json based on check result
if [ "$STALENESS_STATUS" = "fresh" ]; then
  jq '.contextInheritance.stalenessStatus = "fresh"' "$CONTRACT_PATH" > "${CONTRACT_PATH}.tmp" \
    && mv "${CONTRACT_PATH}.tmp" "$CONTRACT_PATH"
elif [ "$STALENESS_STATUS" = "warn" ]; then
  jq '.contextInheritance.stalenessStatus = "warning"' "$CONTRACT_PATH" > "${CONTRACT_PATH}.tmp" \
    && mv "${CONTRACT_PATH}.tmp" "$CONTRACT_PATH"
elif [ "$STALENESS_STATUS" = "block" ]; then
  jq '.contextInheritance.stalenessStatus = "stale"' "$CONTRACT_PATH" > "${CONTRACT_PATH}.tmp" \
    && mv "${CONTRACT_PATH}.tmp" "$CONTRACT_PATH"
  echo "BLOCK: upstream artifacts changed (stalenessPolicy=block). Re-run Contractor agent to refresh."
  exit 1
fi
```

### Step 1.3.6: Intent alignment check (informational, medium/high risk only)

**Skip if `riskLevel` is `low`.** Low-risk tasks don't benefit from LLM alignment checks.

Check if contract has a project intent reference:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
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

Write result to `intent_check.json` under the canonical artifact root.

### Step 1.3.7: Multi-model spec validation (optional, if providers available)

**Skip if `riskLevel` is `low`.** Low-risk tasks don't benefit from multi-model spec validation — proceed directly to Step 1.4.

Use the Bash tool to check which providers are available:

```bash
CODEX_AVAIL=$(which codex > /dev/null 2>&1 && echo "yes" || echo "no")
GEMINI_AVAIL=$(which gemini > /dev/null 2>&1 && echo "yes" || echo "no")
echo "codex=$CODEX_AVAIL gemini=$GEMINI_AVAIL"
```

If both are UNAVAILABLE, skip to Step 1.4.

If at least one is available: read the contract to build validation context:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_CONTEXT=$(python3 - "$CONTRACT_PATH" <<'PY'
import json
import sys
c = json.load(open(sys.argv[1]))
acs = '\n'.join(f'  - [{a[\"id\"]}] {a[\"description\"]}' for a in c.get('acceptanceCriteria', []))
inscope = ', '.join(c.get('inScope', []))
print(f'''Goal: {c[\"goal\"]}
Risk: {c[\"riskLevel\"]}
In scope: {inscope}
Acceptance criteria:
{acs}
Assumptions: {', '.join(c.get('assumptions', ['none']))}
Out of scope: {', '.join(c.get('outOfScope', ['not specified']))}
''')
PY
)
echo "$SPEC_CONTEXT"
```

If codex is available, use the Bash tool with **`run_in_background: true`** to ask codex about spec ambiguities:

```bash
ERR=$(mktemp)
OUT=$(mktemp)
PROMPT="You are reviewing a software specification BEFORE any code is written. Your job: find problems with the spec itself, not the code.

Specification:
$SPEC_CONTEXT

Answer these questions concisely (3-5 bullet points each):
1. AMBIGUITIES: What is unclear or could be interpreted multiple ways by different developers?
2. ASSUMPTIONS: What unstated assumptions would you make to implement this?
3. MISSING: What important behavior, error case, or constraint is not specified?

Be specific and brief. Focus on gaps that would cause implementation mistakes."

CODEX_MODEL_FLAG=""
[ -n "$SIGNUM_CODEX_MODEL" ] && CODEX_MODEL_FLAG="--model $SIGNUM_CODEX_MODEL"
CODEX_PROFILE_FLAG=""
[ -n "$SIGNUM_CODEX_PROFILE" ] && CODEX_PROFILE_FLAG="-p $SIGNUM_CODEX_PROFILE"
codex exec --ephemeral -C "$PWD" $CODEX_PROFILE_FLAG $CODEX_MODEL_FLAG --output-last-message "$OUT" "$PROMPT" 2>"$ERR"
CODEX_SPEC_EXIT=$?
CODEX_SPEC_OUT=$(cat "$OUT" 2>/dev/null || cat "$ERR" | head -c 1000)
rm -f "$OUT" "$ERR"
echo "---CODEX_SPEC---"
echo "$CODEX_SPEC_OUT"
```

Save the task ID as CODEX_SPEC_TASK_ID.

If gemini is available, immediately (without waiting) use the Bash tool with **`run_in_background: true`** to ask gemini about missing coverage:

```bash
ERR=$(mktemp)
PROMPT="You are reviewing a software specification BEFORE any code is written. Your job: find gaps in the spec.

Specification:
$SPEC_CONTEXT

Answer concisely (3-5 bullet points each):
1. EDGE CASES: What scenarios, inputs, or states are not covered by the acceptance criteria?
2. FAILURE MODES: What can go wrong that the spec doesn't address?
3. MISSING CONSTRAINTS: What performance, security, or compatibility constraints should be specified?

Be specific. Focus on what would cause bugs or user complaints if left unaddressed."

GEMINI_MODEL_FLAG=""
[ -n "$SIGNUM_GEMINI_MODEL" ] && GEMINI_MODEL_FLAG="--model $SIGNUM_GEMINI_MODEL"
RESP=$(gemini $GEMINI_MODEL_FLAG -p "$PROMPT" -o text 2>"$ERR")
GEMINI_SPEC_EXIT=$?
if [ $GEMINI_SPEC_EXIT -ne 0 ]; then
  GEMINI_SPEC_OUT="[gemini error: $(cat $ERR | head -c 200)]"
else
  GEMINI_SPEC_OUT="$RESP"
fi
rm -f "$ERR"
echo "---GEMINI_SPEC---"
echo "$GEMINI_SPEC_OUT"
```

Save the task ID as GEMINI_SPEC_TASK_ID.

Use the TaskOutput tool with `block: true` to wait for CODEX_SPEC_TASK_ID (if launched). Then use the TaskOutput tool with `block: true` to wait for GEMINI_SPEC_TASK_ID (if launched).

Write collected findings to `spec_validation.json` under the canonical artifact root:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
SPEC_VALIDATION_PATH="${ARTIFACT_ROOT}spec_validation.json"
jq -n \
  --arg codex_out "$CODEX_SPEC_OUT" \
  --arg gemini_out "$GEMINI_SPEC_OUT" \
  --arg codex_avail "$CODEX_AVAIL" \
  --arg gemini_avail "$GEMINI_AVAIL" \
  '{
    codex: { available: ($codex_avail == "yes"), findings: $codex_out },
    gemini: { available: ($gemini_avail == "yes"), findings: $gemini_out }
  }' > "$SPEC_VALIDATION_PATH"
echo "Spec validation written to $SPEC_VALIDATION_PATH"
```

### Step 1.3.8: Clover reconstruction test

Verify that the acceptance criteria fully capture the goal's intent. Ask a model to reconstruct the goal from ONLY the ACs, then compare with the original.

Use the Agent tool to launch a general-purpose agent (model: sonnet) with this prompt:

```
You are given ONLY the acceptance criteria below. You have NOT seen the original goal.
Reconstruct what the goal/task likely was based solely on these ACs.

Acceptance criteria:
<ACs from contract.json under the canonical artifact root - list each AC id + description, but do NOT include the goal>

Write your reconstructed goal as a single paragraph (2-3 sentences max).
Then write a JSON object:
{
  "reconstructed_goal": "<your reconstruction>",
  "coverage_gaps": ["<any aspects you could NOT infer from the ACs>"],
  "confidence": <0.0-1.0 how confident you are the ACs fully describe the task>
}
Output ONLY the JSON object, no other text.
```

After the agent returns, use the Bash tool to compare:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CLOVER_REPORT_PATH="${ARTIFACT_ROOT}clover_report.json"
ORIGINAL_GOAL=$(jq -r '.goal' "$CONTRACT_PATH")
RECONSTRUCTED=$(echo '<agent output>' | jq -r '.reconstructed_goal // empty')
CONFIDENCE=$(echo '<agent output>' | jq -r '.confidence // 0')
GAPS=$(echo '<agent output>' | jq -r '.coverage_gaps | length')

# Write clover report
jq -n \
  --arg original "$ORIGINAL_GOAL" \
  --arg reconstructed "$RECONSTRUCTED" \
  --argjson confidence "$CONFIDENCE" \
  --argjson gap_count "$GAPS" \
  --argjson gaps "$(echo '<agent output>' | jq '.coverage_gaps')" \
  '{original_goal: $original, reconstructed_goal: $reconstructed,
    confidence: $confidence, coverage_gaps: $gaps, gap_count: $gap_count,
    pass: ($confidence >= 0.7 and $gap_count <= 2)}' > "$CLOVER_REPORT_PATH"

if [ "$(jq '.pass' "$CLOVER_REPORT_PATH")" = "false" ]; then
  echo "CLOVER WARNING: ACs may not fully capture the goal (confidence=$CONFIDENCE, gaps=$GAPS)"
  jq -r '.coverage_gaps[]' "$CLOVER_REPORT_PATH" | sed 's/^/  - /'
  echo "Consider adding ACs to cover the gaps above."
else
  echo "Clover test: PASS (confidence=$CONFIDENCE)"
fi
```

Clover failure is informational — it does not block the pipeline. Display warnings in Step 1.4 if `pass` is false.

### Step 1.4: Display contract summary

**Data collection:** Use a single Bash call to extract all values into shell variables:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SPEC_QUALITY_PATH="${ARTIFACT_ROOT}spec_quality.json"
CLOVER_REPORT_PATH="${ARTIFACT_ROOT}clover_report.json"
INTENT_CHECK_PATH="${ARTIFACT_ROOT}intent_check.json"

CONTRACT_ID=$(jq -r '.contractId' "$CONTRACT_PATH")
GOAL=$(jq -r '.goal' "$CONTRACT_PATH")
RISK=$(jq -r '.riskLevel' "$CONTRACT_PATH")
INSCOPE=$(jq -r '.inScope | join(", ")' "$CONTRACT_PATH")
AC_COUNT=$(jq '.acceptanceCriteria | length' "$CONTRACT_PATH")
HOLDOUT_COUNT=$(jq '((.holdoutScenarios // []) | length) + ([.acceptanceCriteria[] | select(.visibility == "holdout")] | length)' "$CONTRACT_PATH")
VISIBLE_AC=$((AC_COUNT - $(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' "$CONTRACT_PATH")))
SPEC_TOTAL=$(jq -r '.total // "?"' "$SPEC_QUALITY_PATH" 2>/dev/null || echo "?")
SPEC_GRADE=$(jq -r '.grade // "?"' "$SPEC_QUALITY_PATH" 2>/dev/null || echo "?")
CLOVER=$(jq -r 'if .pass then "PASS (" + (.confidence | tostring) + ")" else "WARN (" + (.confidence | tostring) + ")" end' "$CLOVER_REPORT_PATH" 2>/dev/null || echo "skipped")
INTENT=$(jq -r 'if .aligned then "aligned" elif .aligned == false then "MISALIGNED" else "skipped" end' "$INTENT_CHECK_PATH" 2>/dev/null || echo "skipped")
RISK_SIGNALS=$(jq -r 'if .riskLevel == "high" then (.riskSignals // [] | join(", ")) else "" end' "$CONTRACT_PATH")
READINESS=$(jq -r '.readinessForPlanning.verdict // "absent"' "$CONTRACT_PATH")

# Warnings (collect into array for display)
WARNINGS=""
if [ -f "$CLOVER_REPORT_PATH" ] && [ "$(jq '.pass' "$CLOVER_REPORT_PATH")" = "false" ]; then
  WARNINGS="${WARNINGS}\n- Clover: ACs may not fully capture the goal"
  WARNINGS="${WARNINGS}\n$(jq -r '.coverage_gaps[] | "  - " + .' "$CLOVER_REPORT_PATH")"
fi
if [ -f "$INTENT_CHECK_PATH" ] && [ "$(jq '.concerns | length' "$INTENT_CHECK_PATH")" -gt 0 ]; then
  WARNINGS="${WARNINGS}\n- Intent alignment concerns:"
  WARNINGS="${WARNINGS}\n$(jq -r '.concerns[] | "  - " + .' "$INTENT_CHECK_PATH")"
fi
if [ "$READINESS" = "no-go" ]; then
  WARNINGS="${WARNINGS}\n- Contractor self-critique returned no-go"
fi

echo "CONTRACT_ID=$CONTRACT_ID"
echo "GOAL=$GOAL"
echo "RISK=$RISK"
echo "INSCOPE=$INSCOPE"
echo "VISIBLE_AC=$VISIBLE_AC"
echo "HOLDOUT_COUNT=$HOLDOUT_COUNT"
echo "SPEC=$SPEC_TOTAL/115 ($SPEC_GRADE)"
echo "CLOVER=$CLOVER"
echo "INTENT=$INTENT"
echo "RISK_SIGNALS=$RISK_SIGNALS"
echo "READINESS=$READINESS"
if [ -n "$WARNINGS" ]; then echo -e "WARNINGS:$WARNINGS"; fi
```

**Markdown presentation:** After collecting data, present the contract summary as **markdown text output** (NOT bash echo). This ensures proper rendering in the terminal:

```markdown
## Contract: <CONTRACT_ID>

**Goal:** <GOAL — full text, never truncated>

| Field | Value |
|-------|-------|
| Risk | <RISK> |
| Scope | <INSCOPE> |
| ACs | <VISIBLE_AC> visible + <HOLDOUT_COUNT> holdout |
| Spec quality | <SPEC_TOTAL>/115 (<SPEC_GRADE>) |
| Clover | <CLOVER> |
| Intent | <INTENT> |

<if RISK is "high">
**Risk signals:** <RISK_SIGNALS>
</if>

<if WARNINGS non-empty>
### Warnings
<WARNINGS list>
</if>
```

If spec validation ran (medium/high risk), show Codex and Gemini findings as collapsed details below the table — do NOT inline them into the table.

**Present the following 5-item approval checklist to the user.** Display it as a numbered list and ask for a yes/no answer for each item:

```
Human approval checklist — answer yes or no for each:

1. Goal matches intent: Does the contract goal accurately reflect what you asked for?
2. ACs sufficient: Are the acceptance criteria complete and testable?
3. Scope correct: Is the inScope list appropriate (no missing or extra files)?
4. Assumptions valid: Are the listed assumptions accurate for your project?
5. Risk appropriate: Is the stated risk level correct for this change?
```

Wait for the user to answer all 5 items. Collect the responses.

If ANY item is answered "no":

Display which items failed, for example:
```
Approval REJECTED. Failed items:
  - Item 2 (ACs sufficient): [user's reason]
  - Item 4 (Assumptions valid): [user's reason]

Re-run the contractor with this feedback to revise the contract.
Phase 2 will NOT be entered until all checklist items are approved.
```

**STOP. Do not proceed to Phase 2.**

If ALL items are answered "yes", write `approval.json` under the canonical artifact root:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
APPROVAL_PATH="${ARTIFACT_ROOT}approval.json"
APPROVAL_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg ts "$APPROVAL_TS" \
  '{
    approved: true,
    approvedAt: $ts,
    checklist: {
      goal_matches_intent: true,
      acs_sufficient: true,
      scope_correct: true,
      assumptions_valid: true,
      risk_appropriate: true
    }
  }' > "$APPROVAL_PATH"
echo "approval.json written at $APPROVAL_TS"
```

After writing approval.json, transition the contract status from `draft` to `active` and record the `activatedAt` timestamp:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
ACTIVATED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg ts "$ACTIVATED_TS" \
  '.status = "active" | .timestamps.activatedAt = $ts' \
  "$CONTRACT_PATH" > "${CONTRACT_PATH}.tmp" && \
  mv "${CONTRACT_PATH}.tmp" "$CONTRACT_PATH"
echo "Contract status: draft → active at $ACTIVATED_TS"
```

### Step 1.4.5: Record approval timestamp (contract-hash.txt)

After the user confirms, anchor the approved contract with a SHA-256 hash and timestamp. This creates the root of the audit chain.

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_HASH_PATH="${ARTIFACT_ROOT}contract-hash.txt"

if command -v sha256sum >/dev/null 2>&1; then
  CONTRACT_HASH=$(sha256sum "$CONTRACT_PATH" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  CONTRACT_HASH=$(shasum -a 256 "$CONTRACT_PATH" | awk '{print $1}')
else
  CONTRACT_HASH="unavailable"
fi

APPROVAL_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$CONTRACT_HASH_PATH" <<EOF
contract_sha256: $CONTRACT_HASH
approved_at: $APPROVAL_TS
contract_file: $CONTRACT_PATH
EOF

echo "Audit chain anchored: $CONTRACT_HASH at $APPROVAL_TS"
```

### Step 1.5: Prepare sanitized engineer contract

Use the Bash tool to create a contract stripped of holdout scenarios and holdout ACs (data-level isolation):

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_ENGINEER_PATH="${ARTIFACT_ROOT}contract-engineer.json"

# Create engineer contract: remove holdouts + holdoutScenarios
jq '{
  schemaVersion, contractId, status, timestamps, goal, inScope, allowNewFilesUnder, outOfScope,
  acceptanceCriteria: [.acceptanceCriteria[] | select(.visibility != "holdout")],
  assumptions, openQuestions, riskLevel, riskSignals, requiredInputsProvided,
  contextInheritance
} | with_entries(select(.value != null))' "$CONTRACT_PATH" > "$CONTRACT_ENGINEER_PATH"

# Generate holdout manifest for committed spec
HOLDOUT_COUNT=$(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' "$CONTRACT_PATH")
if [ "$HOLDOUT_COUNT" -gt 0 ]; then
  HOLDOUT_HASH=$(jq -c '[.acceptanceCriteria[] | select(.visibility == "holdout")]' "$CONTRACT_PATH" | shasum -a 256 | cut -c1-16)
  jq --argjson count "$HOLDOUT_COUNT" --arg hash "sha256:$HOLDOUT_HASH" \
    '. + {holdoutManifest: {count: $count, hash: $hash}}' "$CONTRACT_ENGINEER_PATH" > "${CONTRACT_ENGINEER_PATH}.tmp"
  mv "${CONTRACT_ENGINEER_PATH}.tmp" "$CONTRACT_ENGINEER_PATH"
fi

AC_VISIBLE=$(jq '[.acceptanceCriteria[] | select(.visibility != "holdout")] | length' "$CONTRACT_PATH")
echo "contract-engineer.json written ($AC_VISIBLE visible ACs, $HOLDOUT_COUNT holdouts redacted)"
```

After writing `contract-engineer.json`, validate holdout count against risk level:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
RISK=$(jq -r '.riskLevel' "$CONTRACT_PATH")
HOLDOUT_COUNT=$(jq '([.acceptanceCriteria[] | select(.visibility == "holdout")] | length) + ((.holdoutScenarios // []) | length)' "$CONTRACT_PATH")

# Minimum holdout requirements by risk level
MIN_HOLDOUTS=0
[ "$RISK" = "medium" ] && MIN_HOLDOUTS=2
[ "$RISK" = "high" ] && MIN_HOLDOUTS=5

if [ "$HOLDOUT_COUNT" -lt "$MIN_HOLDOUTS" ]; then
  echo "HOLDOUT GATE: $RISK risk requires at least $MIN_HOLDOUTS holdout scenarios, got $HOLDOUT_COUNT."
  echo "Re-running Contractor to generate sufficient holdout scenarios..."
  echo "HOLDOUT_INSUFFICIENT"
fi
```

If output contains `HOLDOUT_INSUFFICIENT`, use the Agent tool to re-launch the "contractor" agent with this additional instruction appended to the original request:

```
ADDITIONAL REQUIREMENT: The previous contract had insufficient holdout scenarios for $RISK risk level.
Risk level $RISK requires at least $MIN_HOLDOUTS holdout scenarios.
Current count: $HOLDOUT_COUNT.
Generate exactly the required minimum number of high-quality holdout scenarios:
- Each must be a negative test, error path, or boundary condition
- Each must NOT be derivable from the visible acceptance criteria
- Each must use a verify command (exit code or pattern), not "manual"
Keep all other contract fields the same.
```

After contractor re-runs, repeat the holdout count check. If count is still insufficient after one retry, continue with a warning (do not block indefinitely).

### Step 1.6: Generate execution policy

Derive `contract-policy.json` from the contract. This file defines what the Engineer may and may not do during EXECUTE.

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_POLICY_PATH="${ARTIFACT_ROOT}contract-policy.json"
python3 - "$CONTRACT_PATH" "$CONTRACT_POLICY_PATH" <<'PY'
import json
import sys
contract_path = sys.argv[1]
policy_path = sys.argv[2]
with open(contract_path) as f:
    c = json.load(f)
risk = c.get('riskLevel', 'low')
in_scope = c.get('inScope', [])
max_files = {'low': 25, 'medium': 15, 'high': 10}.get(risk, 15)
policy = {
    'schemaVersion': '1.0',
    'generatedFrom': c.get('taskId', 'unknown'),
    'riskLevel': risk,
    'allowed_tools': ['Read', 'Write', 'Edit', 'Glob', 'Grep', 'Bash'],
    'denied_tools': ['WebSearch', 'WebFetch', 'Agent', 'Task'],
    'bash_deny_patterns': [
        r'rm\s+-[rf]+\s+/',
        r'git\s+push\s+--force',
        r'curl[^|]*\|\s*sh',
        r'eval\s+\\\$',
        r'dd\s+if=',
        r'mkfs\.',
        r'>\s*/dev/sd',
    ],
    'allowed_paths': in_scope,
    'max_files_changed': max_files,
    'network_access': False,
}
with open(policy_path, 'w') as f:
    json.dump(policy, f, indent=2)
print(f'contract-policy.json written (risk={risk}, allowed_paths={len(in_scope)}, max_files={max_files})')
PY
```

---

## Phase 2: EXECUTE

**Goal:** Implement code changes according to the contract.

### Step 2.0: Capture baseline (before any changes)

Use the Bash tool to record the current commit SHA (audit chain: this is where the Engineer starts from) and run project checks BEFORE the engineer touches anything:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
BASELINE_PATH="${ARTIFACT_ROOT}baseline.json"

# Record base commit for audit chain
BASE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
EXECUTE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "{\"base_commit\":\"$BASE_COMMIT\",\"started_at\":\"$EXECUTE_START\"}" > "$EXECUTION_CONTEXT_PATH"
echo "Execution context: base_commit=$BASE_COMMIT"

# Set run_id for receipt chain
RUN_ID=$(jq -r '.contractId // "signum-run"' "$CONTRACT_PATH")
jq --arg rid "$RUN_ID" '. + {run_id:$rid}' "$EXECUTION_CONTEXT_PATH" > "${EXECUTION_CONTEXT_PATH}.tmp" \
  && mv "${EXECUTION_CONTEXT_PATH}.tmp" "$EXECUTION_CONTEXT_PATH"

# Lint
if [ -f "pyproject.toml" ] && grep -q "ruff" pyproject.toml 2>/dev/null; then
  BL_LINT_EXIT=$(ruff check . >/dev/null 2>&1; echo $?)
elif [ -f "package.json" ] && grep -q "eslint" package.json 2>/dev/null; then
  BL_LINT_EXIT=$(npx eslint . >/dev/null 2>&1; echo $?)
else
  BL_LINT_EXIT=0
fi

# Typecheck
if [ -f "pyproject.toml" ] && grep -q "mypy" pyproject.toml 2>/dev/null; then
  BL_TYPE_EXIT=$(mypy . >/dev/null 2>&1; echo $?)
elif [ -f "tsconfig.json" ]; then
  BL_TYPE_EXIT=$(npx tsc --noEmit >/dev/null 2>&1; echo $?)
else
  BL_TYPE_EXIT=0
fi

# Tests — capture per-test names for regression tracking
if [ -f "pyproject.toml" ] && grep -q "pytest" pyproject.toml 2>/dev/null; then
  BL_TEST_RAW=$(pytest --tb=no -q 2>&1)
  BL_TEST_EXIT=$?
  BL_TEST_FAILING=$(echo "$BL_TEST_RAW" | grep -E '^FAILED ' | sed 's/^FAILED //' | sed 's/ - .*//' | jq -R . | jq -s .)
  [ -z "$BL_TEST_FAILING" ] && BL_TEST_FAILING='[]'
elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
  BL_TEST_EXIT=$(npm test >/dev/null 2>&1; echo $?)
  BL_TEST_FAILING='[]'
elif [ -f "Cargo.toml" ]; then
  BL_TEST_EXIT=$(cargo test >/dev/null 2>&1; echo $?)
  BL_TEST_FAILING='[]'
else
  BL_TEST_EXIT=0
  BL_TEST_FAILING='[]'
fi

jq -n \
  --argjson lint "$BL_LINT_EXIT" \
  --argjson type "$BL_TYPE_EXIT" \
  --argjson test "$BL_TEST_EXIT" \
  --argjson failing "$BL_TEST_FAILING" \
  '{ lint: $lint, typecheck: $type, tests: { exit_code: $test, failing: $failing } }' > "$BASELINE_PATH"

echo "Baseline captured: lint=$BL_LINT_EXIT type=$BL_TYPE_EXIT test=$BL_TEST_EXIT"
```

If `repo-contract.json` exists in the project root, also capture invariant baseline to `repo_contract_baseline.json` under the canonical artifact root:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REPO_CONTRACT_BASELINE_PATH="${ARTIFACT_ROOT}repo_contract_baseline.json"

if [ -f "repo-contract.json" ]; then
  python3 - "$REPO_CONTRACT_BASELINE_PATH" <<'PY'
import json
import subprocess
import sys

output_path = sys.argv[1]
with open('repo-contract.json') as f:
    rc = json.load(f)
results = {}
for inv in rc.get('invariants', []):
    r = subprocess.run(inv['verify'], shell=True, capture_output=True, text=True)
    results[inv['id']] = {
        'description': inv['description'],
        'severity': inv['severity'],
        'verify': inv['verify'],
        'exit_code': r.returncode,
        'passed': r.returncode == 0,
    }
with open(output_path, 'w') as f:
    json.dump(results, f, indent=2)
total = len(results)
passed = sum(1 for v in results.values() if v['passed'])
print(f'Repo-contract baseline: {passed}/{total} invariants passing')
PY
fi
```

### Step 2.0.5: Capture pre-execute snapshot (receipt chain)

Use the Bash tool to capture a deterministic workspace snapshot before the engineer runs. This snapshot anchors the receipt chain, and it is written under the canonical artifact root so `base_tree_hash` in the execute receipt references the active contract's snapshot.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
SNAPSHOT_PATH="${ARTIFACT_ROOT}snapshots/execute-attempt-01.json"

# Resolve snapshot-tree.sh from known trusted Signum install roots only.
_SIGNUM_SNAPSHOT=""
for _d in \
  "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
  "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
  "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
  [ -f "${_d}/lib/snapshot-tree.sh" ] || continue
  _SIGNUM_SNAPSHOT="${_d}/lib/snapshot-tree.sh"
  break
done
if [ -z "$_SIGNUM_SNAPSHOT" ]; then
  echo "WARNING: snapshot-tree.sh not found — receipt chain will be incomplete"
else
  bash "$_SIGNUM_SNAPSHOT" execute-attempt-01 --workspace-root "$PWD" --signum-dir "$ARTIFACT_ROOT"
  echo "Pre-execute snapshot captured"
fi
```

### Step 2.1: Launch Engineer

Use the Agent tool to launch the "engineer" agent with this prompt:

```
The canonical artifact root for this execute phase is `.signum/contracts/<activeContractId>/`.
Read `contract-engineer.json` and `baseline.json` from that canonical artifact root.
Implement, run the repair loop (max 3 attempts), save artifacts.
Write `combined.patch` and `execute_log.json` to that same canonical artifact root.
```

### Step 2.2: Check result

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
test -f "$EXECUTE_LOG_PATH" || { echo "ERROR: execute_log.json not found"; exit 1; }
STATUS=$(jq -r '.status' "$EXECUTE_LOG_PATH")
if [ "$STATUS" != "SUCCESS" ]; then
  echo "ERROR: Execute status is '$STATUS' (expected SUCCESS)"
  jq -r '"Attempt failures:",
         (.attempts[] | "  Attempt " + (.number | tostring) + ": " +
           (.checks | to_entries[] | select(.value.passed == false) |
             "  " + .key + " failed: " + (.value.error // "no error message")))' \
    "$EXECUTE_LOG_PATH" 2>/dev/null || jq . "$EXECUTE_LOG_PATH"
  exit 1
fi
```

If exit code is non-zero, report: "Engineer agent failed after all attempts. Fix the issues above and re-run /signum."

Verify the patch exists:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
test -f "$COMBINED_PATCH_PATH" && wc -l "$COMBINED_PATCH_PATH" || echo "WARNING: combined.patch missing"
```

### Step 2.3: Display execution summary

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
jq -r '"Attempts used: " + (.totalAttempts | tostring) + "/" + (.maxAttempts | tostring),
       "Acceptance criteria passed: " +
         ([.attempts[-1].checks | to_entries[] | select(.value.passed == true)] | length | tostring)' \
  "$EXECUTE_LOG_PATH"
```

### Step 2.4: Scope gate

Use the Bash tool to verify no out-of-scope files were modified:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"

# Get changed files from patch
CHANGED=$(git diff --name-only)
# Strip parenthetical annotations from inScope paths (e.g., "src/main.rs (entry point)" -> "src/main.rs")
IN_SCOPE=$(jq -r '.inScope[]' "$CONTRACT_PATH" | sed 's/ (.*$//')
ALLOW_NEW=$(jq -r '.allowNewFilesUnder // [] | .[]' "$CONTRACT_PATH" | sed 's/ (.*$//')
# v3.8: removal targets are also allowed scope
REMOVAL_PATHS=$(jq -r '(.removals // [])[] | .path' "$CONTRACT_PATH" 2>/dev/null || true)

VIOLATIONS=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  match=0
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$file" in
      ${pattern}*) match=1; break ;;
    esac
  done <<< "$(echo "$IN_SCOPE"; echo "$ALLOW_NEW"; echo "$REMOVAL_PATHS")"
  [ $match -eq 0 ] && VIOLATIONS="$VIOLATIONS\n  $file"
done <<< "$CHANGED"

if [ -n "$VIOLATIONS" ]; then
  echo "SCOPE VIOLATION: files outside inScope modified:$VIOLATIONS"
  echo "Pipeline stopped. Fix scope in contract or revert changes."
  exit 1
else
  echo "Scope check: PASS (all changed files within inScope)"
fi
```

If scope violation, **STOP**. Do not proceed to Phase 3.

### Step 2.4.5: Policy compliance check

Use the Bash tool to verify the Engineer's changes comply with `contract-policy.json`:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_POLICY_PATH="${ARTIFACT_ROOT}contract-policy.json"
POLICY_VIOLATIONS_PATH="${ARTIFACT_ROOT}policy_violations.json"

if [ ! -f "$CONTRACT_POLICY_PATH" ]; then
  echo "contract-policy.json not found, skipping policy check"
  echo '{"violations":[]}' > "$POLICY_VIOLATIONS_PATH"
else
  FILE_COUNT=$(git diff --name-only | wc -l | tr -d '[:space:]')
  MAX_FILES=$(jq '.max_files_changed' "$CONTRACT_POLICY_PATH")

  VIOLS='[]'

  # Check 1: file count limit
  if [ "$FILE_COUNT" -gt "$MAX_FILES" ]; then
    VIOLS=$(printf '%s' "$VIOLS" | jq --arg v "TOO_MANY_FILES: $FILE_COUNT changed, policy max is $MAX_FILES" '. + [$v]')
  fi

  # Check 2: dangerous bash patterns in diff content
  DIFF=$(git diff HEAD 2>/dev/null || true)
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if printf '%s' "$DIFF" | grep -qE "$pat" 2>/dev/null; then
      VIOLS=$(printf '%s' "$VIOLS" | jq --arg v "DENIED_PATTERN in diff: $pat" '. + [$v]')
    fi
  done < <(jq -r '.bash_deny_patterns[]' "$CONTRACT_POLICY_PATH")

  printf '%s' "$VIOLS" | jq '{violations: .}' > "$POLICY_VIOLATIONS_PATH"
  VIOL_COUNT=$(printf '%s' "$VIOLS" | jq 'length')

  if [ "$VIOL_COUNT" -gt 0 ]; then
    echo "POLICY VIOLATIONS ($VIOL_COUNT):"
    printf '%s' "$VIOLS" | jq -r '.[]' | sed 's/^/  - /'
    echo "AUTO_BLOCK"
  else
    echo "Policy check: PASS ($FILE_COUNT files, max $MAX_FILES)"
  fi
fi
```

If output contains `AUTO_BLOCK`, **STOP**. Do not proceed to Phase 3.

### Step 2.4.6: Scope existence gate

Use the Bash tool to verify all non-glob `inScope` paths exist after the engineer ran. This catches the failure class where files were promised but never created:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"

MISSING_SCOPE=""
while IFS= read -r scoped; do
  scoped=$(printf '%s' "$scoped" | sed 's/ (.*$//')
  [ -z "$scoped" ] && continue
  case "$scoped" in
    *'*'*|*'?'*|*'['*) continue ;;
  esac
  if [ ! -e "$scoped" ]; then
    MISSING_SCOPE="$MISSING_SCOPE\n  $scoped"
  fi
done < <(jq -r '.inScope[]' "$CONTRACT_PATH")
if [ -n "$MISSING_SCOPE" ]; then
  echo "SCOPE MISSING: expected inScope paths do not exist:$MISSING_SCOPE"
  exit 1
else
  echo "Scope existence: PASS (all inScope paths present)"
fi
```

If scope existence fails, **STOP**. Do not proceed to Phase 3.

### Step 2.5: Boundary verification (receipt chain)

Use the Bash tool to run deterministic boundary verification. This runs AFTER the engineer completes and verifies AC evidence, scope integrity, and artifact hashes. The boundary verifier generates the execute receipt — the engineer does NOT write its own receipt.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_ENGINEER_PATH="${ARTIFACT_ROOT}contract-engineer.json"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
SNAPSHOT_PATH="${ARTIFACT_ROOT}snapshots/execute-attempt-01.json"
_SIGNUM_BOUNDARY=""
for _d in \
  "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
  "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
  "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
  [ -f "${_d}/lib/boundary-verifier.sh" ] || continue
  _SIGNUM_BOUNDARY="${_d}/lib/boundary-verifier.sh"
  break
done
if [ -z "$_SIGNUM_BOUNDARY" ]; then
  echo "WARNING: boundary-verifier.sh not found — skipping receipt chain verification"
else
  bash "$_SIGNUM_BOUNDARY" execute \
    --workspace-root "$PWD" \
    --signum-dir "$ARTIFACT_ROOT" \
    --contract "$CONTRACT_ENGINEER_PATH" \
    --contract-full "$CONTRACT_PATH" \
    --execution-context "$EXECUTION_CONTEXT_PATH" \
    --snapshot "$SNAPSHOT_PATH"
fi
```

If boundary verifier exits non-zero, **STOP**. Do not proceed to Phase 3.

### Step 2.6: Transition verification (receipt chain)

Use the Bash tool to verify the execute → audit transition gate. This checks receipt integrity, contract hash chain, artifact hashes, and AC evidence completeness.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_ENGINEER_PATH="${ARTIFACT_ROOT}contract-engineer.json"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
SNAPSHOT_PATH="${ARTIFACT_ROOT}snapshots/execute-attempt-01.json"
_SIGNUM_TRANSITION=""
for _d in \
  "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
  "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
  "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
  [ -f "${_d}/lib/transition-verifier.sh" ] || continue
  _SIGNUM_TRANSITION="${_d}/lib/transition-verifier.sh"
  break
done
if [ -z "$_SIGNUM_TRANSITION" ]; then
  echo "WARNING: transition-verifier.sh not found — skipping transition gate"
else
  bash "$_SIGNUM_TRANSITION" execute audit \
    --workspace-root "$PWD" \
    --signum-dir "$ARTIFACT_ROOT" \
    --contract "$CONTRACT_ENGINEER_PATH" \
    --contract-full "$CONTRACT_PATH" \
    --snapshot "$SNAPSHOT_PATH"
fi
```

If transition verifier exits non-zero, **STOP**. Do not proceed to Phase 3.

---

## Phase 3: AUDIT

**Goal:** Verify the change from multiple independent angles.

### Risk-Proportional Ceremony

Read the contract's `riskLevel` and apply the matching ceremony profile. Steps marked "skip" MUST be skipped entirely (no agent launches, no CLI calls).

| Step | Low | Medium | High |
|------|-----|--------|------|
| 3.0.5 Repo-contract invariants | run | run | run |
| 3.1 Mechanic | run | run | run |
| 3.1.5 Holdout validation | skip (0 required) | run (≥2 required) | run (≥5 required) |
| 3.2 Prepare review prompts | skip | run | run |
| 3.2.5 Launch reviews | Claude only | Claude + available externals | Claude + Codex + Gemini (all 3) |
| 3.3–3.3.5 Collect + parse | Claude only | all launched | all launched |
| 3.5 Synthesizer | run | run | run |

**Budget targets:** Low <2 min, <$0.20 | Medium 3-5 min | High 5-10 min, full panel.

**Single-model graceful degradation:** If external CLIs are not installed (not failed — genuinely absent), the synthesizer allows AUTO_OK with single Claude review for low and medium risk. High risk always requires multi-model or HUMAN_REVIEW.

Use the Bash tool to read the risk level and save it for conditional checks:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
RISK_LEVEL=$(jq -r '.riskLevel' "$CONTRACT_PATH")
echo "RISK_LEVEL=$RISK_LEVEL"
```

Save `RISK_LEVEL` for use in all subsequent steps.

### Step 3.0.5: Repo-contract invariant check

If `repo-contract.json` and `repo_contract_baseline.json` under the canonical artifact root both exist, re-run invariants and detect regressions:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REPO_CONTRACT_BASELINE_PATH="${ARTIFACT_ROOT}repo_contract_baseline.json"
REPO_CONTRACT_VIOLATIONS_PATH="${ARTIFACT_ROOT}repo_contract_violations.json"

if [ -f "repo-contract.json" ] && [ -f "$REPO_CONTRACT_BASELINE_PATH" ]; then
  python3 - "$REPO_CONTRACT_BASELINE_PATH" "$REPO_CONTRACT_VIOLATIONS_PATH" <<'PY'
import json
import subprocess
import sys

baseline_path = sys.argv[1]
violations_path = sys.argv[2]
with open('repo-contract.json') as f:
    rc = json.load(f)
with open(baseline_path) as f:
    baseline = json.load(f)
regressions = []
results = {}
for inv in rc.get('invariants', []):
    iid = inv['id']
    r = subprocess.run(inv['verify'], shell=True, capture_output=True, text=True)
    now_passed = r.returncode == 0
    was_passing = baseline.get(iid, {}).get('passed', True)
    regressed = was_passing and not now_passed
    results[iid] = {
        'description': inv['description'],
        'severity': inv['severity'],
        'verify': inv['verify'],
        'exit_code': r.returncode,
        'passed': now_passed,
        'was_passing': was_passing,
        'regressed': regressed,
    }
    if regressed:
        regressions.append(f'{iid} ({inv["severity"]}): {inv["description"]}')
with open(violations_path, 'w') as f:
    json.dump({'invariants': results, 'regressions': regressions}, f, indent=2)
if regressions:
    print('INVARIANT REGRESSIONS:')
    for reg in regressions:
        print(f'  - {reg}')
    print('AUTO_BLOCK')
else:
    total = len(results)
    passed = sum(1 for v in results.values() if v['passed'])
    print(f'Repo-contract: PASS ({passed}/{total} invariants holding)')
PY
fi
```

If output contains `AUTO_BLOCK`, **STOP**. Invariant regressions are critical failures regardless of task-level AC results. Do not proceed to Step 3.1.

### Step 3.1: Mechanic (bash, zero LLM)

Run full project checks and compare with baseline. Use the Bash tool:

```bash
# Resolve mechanic-parser.sh from known trusted Signum install roots only.
# SIGNUM_PLUGIN_DIR env var is intentionally excluded to prevent environment
# hijacking — only fixed install paths are trusted.
# Home directory is resolved from the account database, not $HOME, to prevent
# environment-variable override attacks.
_REAL_HOME=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || python3 -c "import pwd,os; print(pwd.getpwuid(os.getuid()).pw_dir)" 2>/dev/null || echo "$HOME")
_SIGNUM_MECHANIC=""
for _d in \
  "${_REAL_HOME}/.claude/plugins/signum/platforms/claude-code" \
  "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
  "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
  [ -f "${_d}/lib/mechanic-parser.sh" ] || continue
  _SIGNUM_MECHANIC="${_d}/lib/mechanic-parser.sh"
  break
done
if [ -z "$_SIGNUM_MECHANIC" ]; then
  echo "ERROR: mechanic-parser.sh not found in Signum plugin directories" >&2
  exit 1
fi
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
BASELINE_PATH="${ARTIFACT_ROOT}baseline.json"
bash "$_SIGNUM_MECHANIC" "$BASELINE_PATH"
```

If any check has a NEW regression, continue to reviews — mechanic regression influences the final decision but does not block the audit.

### Step 3.1.3: Policy scanner (bash, zero LLM cost)

Run the deterministic policy scanner on `combined.patch` under the canonical artifact root. This step scans addition lines only for security, unsafe, and dependency patterns. Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"

# Resolve policy-scanner.sh from known trusted Signum install roots only.
# SIGNUM_PLUGIN_DIR env var is intentionally excluded to prevent environment
# hijacking — only fixed install paths derived from $HOME are trusted.
_SIGNUM_SCANNER=""
for _d in \
  "${HOME}/.claude/plugins/signum/platforms/claude-code" \
  "${HOME}/.local/share/emporium/signum/platforms/claude-code" \
  "${HOME}/.nex/plugins/signum/platforms/claude-code"; do
  [ -f "${_d}/lib/policy-scanner.sh" ] || continue
  _SIGNUM_SCANNER="${_d}/lib/policy-scanner.sh"
  break
done
if [ -z "$_SIGNUM_SCANNER" ]; then
  echo "ERROR: policy-scanner.sh not found in Signum plugin directories" >&2
  exit 1
fi
bash "$_SIGNUM_SCANNER" "$COMBINED_PATCH_PATH"
```

This writes `policy_scan.json` under the canonical artifact root with fields: `scannedAt`, `patchFile`, `findings` (array), and `summaryCounts` ({critical, major, minor, total}).

Check for CRITICAL findings:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
POLICY_SCAN_PATH="${ARTIFACT_ROOT}policy_scan.json"
POLICY_CRITICAL=$(jq -r '.summaryCounts.critical // 0' "$POLICY_SCAN_PATH")
echo "Policy scan: critical=$POLICY_CRITICAL findings total=$(jq -r '.summaryCounts.total' "$POLICY_SCAN_PATH")"
```

If `POLICY_CRITICAL` is greater than 0, the synthesizer will AUTO_BLOCK. Continue to reviews — the synthesizer reads `policy_scan.json` and applies the block rule deterministically.

### Step 3.1.5: Holdout validation

**Skip if `RISK_LEVEL` is `low`.** Write an empty holdout report under the canonical artifact root and proceed to Step 3.2.

Otherwise, run holdout verification using the typed DSL runner. Supports both new format (`acceptanceCriteria` with `visibility: "holdout"`) and legacy `holdoutScenarios`:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"

if [ "$RISK_LEVEL" = "low" ]; then
  echo '{"total":0,"passed":0,"failed":0,"errors":0,"results":[]}' > "$HOLDOUT_REPORT_PATH"
  echo "Holdout validation skipped (low risk)"
else
# Count holdouts: new format (visibility=holdout) + legacy (holdoutScenarios)
HOLDOUT_ACS=$(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' "$CONTRACT_PATH")
LEGACY_HOLDOUTS=$(jq '.holdoutScenarios // [] | length' "$CONTRACT_PATH")
TOTAL_HOLDOUTS=$((HOLDOUT_ACS + LEGACY_HOLDOUTS))

if [ "$TOTAL_HOLDOUTS" -gt 0 ]; then
  PASS=0; FAIL=0; ERRORS=0
  RESULTS="[]"

  # New format: AC with visibility=holdout
  for i in $(seq 0 $((HOLDOUT_ACS - 1))); do
    ID=$(jq -r "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].id" "$CONTRACT_PATH")
    DESC=$(jq -r "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].description" "$CONTRACT_PATH")

    VERIFY_FILE=$(mktemp)
    jq "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].verify" "$CONTRACT_PATH" > "$VERIFY_FILE"

    if ! bash lib/dsl-runner.sh validate "$VERIFY_FILE" > /dev/null 2>&1; then
      ERRORS=$((ERRORS + 1))
      RESULTS=$(echo "$RESULTS" | jq --arg id "$ID" --arg desc "$DESC" \
        '. + [{"id": $id, "description": $desc, "status": "ERROR", "error": "DSL validation failed"}]')
      echo "HOLDOUT ERROR: $DESC (invalid DSL)"
    else
      REPORT=$(bash lib/dsl-runner.sh run "$VERIFY_FILE" 2>&1) || true
      STATUS=$(echo "$REPORT" | jq -r '.status // "ERROR"')
      ERROR=$(echo "$REPORT" | jq -r '.error // empty')

      if [ "$STATUS" = "PASS" ]; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
        echo "HOLDOUT FAIL: $DESC${ERROR:+ ($ERROR)}"
      fi
      RESULTS=$(echo "$RESULTS" | jq --arg id "$ID" --arg desc "$DESC" --arg st "$STATUS" --arg err "$ERROR" \
        '. + [{"id": $id, "description": $desc, "status": $st, "error": (if $err == "" then null else $err end)}]')
    fi
    rm -f "$VERIFY_FILE"
  done

  # Legacy format: holdoutScenarios (backward compat)
  for i in $(seq 0 $((LEGACY_HOLDOUTS - 1))); do
    ID=$(jq -r ".holdoutScenarios[$i].id // \"HO$((i+1))\"" "$CONTRACT_PATH")
    DESC=$(jq -r ".holdoutScenarios[$i].description" "$CONTRACT_PATH")
    HAS_STEPS=$(jq ".holdoutScenarios[$i].verify | has(\"steps\")" "$CONTRACT_PATH")
    if [ "$HAS_STEPS" = "true" ]; then
      VERIFY_FILE=$(mktemp)
      jq ".holdoutScenarios[$i].verify" "$CONTRACT_PATH" > "$VERIFY_FILE"
      if bash lib/dsl-runner.sh validate "$VERIFY_FILE" > /dev/null 2>&1; then
        REPORT=$(bash lib/dsl-runner.sh run "$VERIFY_FILE" 2>&1) || true
        STATUS=$(echo "$REPORT" | jq -r '.status // "ERROR"')
      else
        STATUS="ERROR"
      fi
      rm -f "$VERIFY_FILE"
    else
      STATUS="ERROR"
      echo "HOLDOUT SKIP: $DESC (legacy shell format — migrate to DSL)"
    fi

    if [ "$STATUS" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
    RESULTS=$(echo "$RESULTS" | jq --arg id "$ID" --arg desc "$DESC" --arg st "$STATUS" \
      '. + [{"id": $id, "description": $desc, "status": $st}]')
  done

  echo "$RESULTS" | jq --argjson pass "$PASS" --argjson fail "$FAIL" --argjson err "$ERRORS" \
    '{total: ($pass + $fail + $err), passed: $pass, failed: $fail, errors: $err, results: .}' \
    > "$HOLDOUT_REPORT_PATH"
  echo "Holdout: $PASS passed, $FAIL failed, $ERRORS errors"
else
  echo '{"total":0,"passed":0,"failed":0,"errors":0,"results":[]}' > "$HOLDOUT_REPORT_PATH"
  echo "No holdout scenarios"
fi
fi
```

If any holdout fails, continue to reviews but synthesizer treats it as regression signal.

### Step 3.2.0: Gather review context

Run a single Bash block to build `review_context.json` under the canonical artifact root. This file provides git history for changed files and issue references extracted from commit messages and is used later to enrich the Claude reviewer prompt.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
REVIEW_CONTEXT_PATH="${ARTIFACT_ROOT}review_context.json"

python3 - "$PATCH_PATH" "$REVIEW_CONTEXT_PATH" << 'PYEOF'
import json, os, re, subprocess, sys

patch_path = sys.argv[1]
review_context_path = sys.argv[2]

# --- git_history: one entry per file changed in combined.patch ---
git_history = []
if os.path.exists(patch_path):
    with open(patch_path) as f:
        patch = f.read()
    files = re.findall(r'^\+\+\+ b/(.+)$', patch, re.MULTILINE)
    seen = set()
    for filepath in files:
        if filepath in seen:
            continue
        seen.add(filepath)
        try:
            result = subprocess.run(
                ['git', 'log', '-1', '--format=%h\x1f%s\x1f%ad', '--date=short', '--', filepath],
                capture_output=True, text=True
            )
            line = result.stdout.strip()
            if line:
                sha, subject, date = line.split('\x1f', 2)
                git_history.append({'file': filepath, 'last_commit_sha': sha, 'subject': subject, 'date': date})
            else:
                git_history.append({'file': filepath, 'last_commit_sha': '', 'subject': '', 'date': ''})
        except Exception:
            git_history.append({'file': filepath, 'last_commit_sha': '', 'subject': '', 'date': ''})
# If patch absent or empty, git_history stays []

# --- issue_refs: extract issue IDs from recent commit messages ---
issue_refs = []
gh_available = False
try:
    r = subprocess.run(['which', 'gh'], capture_output=True)
    gh_available = r.returncode == 0
except Exception:
    pass

if git_history:
    shas = [e['last_commit_sha'] for e in git_history if e['last_commit_sha']]
    seen_ids = set()
    for sha in shas:
        try:
            r = subprocess.run(['git', 'log', '-1', '--format=%B', sha], capture_output=True, text=True)
            msg = r.stdout
            ids = re.findall(r'#(\d+)', msg)
            for issue_id in ids:
                if issue_id in seen_ids:
                    continue
                seen_ids.add(issue_id)
                title_or_null = None
                tracker = 'unknown'
                if gh_available:
                    try:
                        gr = subprocess.run(
                            ['gh', 'issue', 'view', issue_id, '--json', 'title', '-q', '.title'],
                            capture_output=True, text=True, timeout=10
                        )
                        if gr.returncode == 0 and gr.stdout.strip():
                            title_or_null = gr.stdout.strip()
                            tracker = 'github'
                    except Exception:
                        pass
                issue_refs.append({'id': issue_id, 'title_or_null': title_or_null, 'tracker': tracker})
        except Exception:
            pass

# --- project_intent: read project.intent.md if present ---
project_intent = None
for candidate in ['project.intent.md', os.path.join(os.getcwd(), 'project.intent.md')]:
    if os.path.exists(candidate):
        with open(candidate) as f:
            project_intent = f.read()
        break

result = {
    'git_history': git_history,
    'issue_refs': issue_refs,
    'project_intent': project_intent,
}
with open(review_context_path, 'w') as f:
    json.dump(result, f, indent=2)
print(f"review_context.json written: {len(git_history)} file(s), {len(issue_refs)} issue ref(s), intent={'yes' if project_intent else 'null'}")
PYEOF
```

If the patch does not exist or contains no file paths, `git_history` and `issue_refs` will be empty arrays (no crash). If `gh` is unavailable, `issue_refs` entries have `tracker: "unknown"` and `title_or_null: null`.

### Step 3.2: Prepare prompts for all reviewers

**If `RISK_LEVEL` is `low`:** skip this step entirely (no external prompts needed). Set `CODEX_AVAILABLE=false` and `GEMINI_AVAILABLE=false`, then proceed directly to Step 3.2.5 (Claude-only).

Otherwise, in a single Bash block, check both codex and gemini availability, build both prompts (security-focused for codex, performance-focused for gemini), and save them under the canonical artifact root as `review_prompt_codex.txt` and `review_prompt_gemini.txt`:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
DELTA_PATCH_PATH="${ARTIFACT_ROOT}iteration_delta.patch"
REVIEW_PROMPT_CODEX_PATH="${ARTIFACT_ROOT}review_prompt_codex.txt"
REVIEW_PROMPT_GEMINI_PATH="${ARTIFACT_ROOT}review_prompt_gemini.txt"

which codex > /dev/null 2>&1 && CODEX_AVAILABLE=true || CODEX_AVAILABLE=false
which gemini > /dev/null 2>&1 && GEMINI_AVAILABLE=true || GEMINI_AVAILABLE=false

if [ "$CODEX_AVAILABLE" = "true" ]; then
  python3 - "$CONTRACT_PATH" "$PATCH_PATH" "$DELTA_PATCH_PATH" "lib/prompts/review-template-security.md" <<'PY' > "$REVIEW_PROMPT_CODEX_PATH"
import json
import os
import sys

contract_path, patch_path, delta_path, template_path = sys.argv[1:]
goal = json.load(open(contract_path))['goal']
diff = open(patch_path).read()
delta = open(delta_path).read() if os.path.exists(delta_path) else ''
tmpl = open(template_path).read()
print(tmpl.replace('{goal}', goal).replace('{diff}', diff).replace('{iteration_delta}', delta))
PY
  echo "codex: AVAILABLE, prompt written"
else
  echo "codex: UNAVAILABLE"
fi

if [ "$GEMINI_AVAILABLE" = "true" ]; then
  python3 - "$CONTRACT_PATH" "$PATCH_PATH" "$DELTA_PATCH_PATH" "lib/prompts/review-template-performance.md" <<'PY' > "$REVIEW_PROMPT_GEMINI_PATH"
import json
import os
import sys

contract_path, patch_path, delta_path, template_path = sys.argv[1:]
goal = json.load(open(contract_path))['goal']
diff = open(patch_path).read()
delta = open(delta_path).read() if os.path.exists(delta_path) else ''
tmpl = open(template_path).read()
print(tmpl.replace('{goal}', goal).replace('{diff}', diff).replace('{iteration_delta}', delta))
PY
  echo "gemini: AVAILABLE, prompt written"
else
  echo "gemini: UNAVAILABLE"
fi

echo "CODEX_AVAILABLE=$CODEX_AVAILABLE GEMINI_AVAILABLE=$GEMINI_AVAILABLE"
```

Save CODEX_AVAILABLE and GEMINI_AVAILABLE for use in the next step.

### Step 3.2.5: Launch reviews

Before choosing the risk-proportional review launch path, ensure the canonical reviews directory exists. This applies to low-risk foreground Claude reviews and medium/high parallel reviews:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
mkdir -p "$REVIEWS_DIR"
echo "REVIEWS_DIR=$REVIEWS_DIR"
```

**Risk-proportional launch:**
- **Low risk:** Launch Claude reviewer ONLY (foreground, not background). Write UNAVAILABLE stubs for codex and gemini immediately. Skip to Step 3.3 (no TaskOutput wait needed since Claude ran foreground, but still verify claude.json output).
- **Medium/High risk:** Use a single message with multiple tool use blocks to launch all available reviewers simultaneously. Do NOT wait between launches.

For medium/high risk, launch the reviewer-claude Agent with `run_in_background: true`, the Codex Bash with `run_in_background: true`, and the Gemini Bash with `run_in_background: true` — all in the same message:

**Claude (Agent tool, `run_in_background: true`):**

Before launching the Claude reviewer Agent, read `review_context.json` under the canonical artifact root and serialize it to a string. Then construct the agent prompt as follows (inject the review_context JSON content inline, not as a file path):

```
The canonical artifact root for this review is `.signum/contracts/<activeContractId>/`.
Read `contract.json`, `combined.patch`, and `mechanic_report.json` from that canonical artifact root.
Also read `iteration_delta.patch` from that same root if it exists.
The review_context for this review is: <REVIEW_CONTEXT_JSON>
Follow lib/prompts/review-template.md and write your review to `reviews/claude.json` under that same canonical artifact root.
Use the review_context above to fill in the {review_context} placeholder in the template.
Write ONLY the JSON object, no markers, no markdown.
```

Replace `<REVIEW_CONTEXT_JSON>` with the full JSON content of `review_context.json` from the canonical artifact root read in the previous step.

**Codex (Bash tool, `run_in_background: true`, only if CODEX_AVAILABLE):**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
REVIEW_PROMPT_CODEX_PATH="${ARTIFACT_ROOT}review_prompt_codex.txt"
CODEX_STDOUT_PATH="${REVIEWS_DIR}/codex_stdout.txt"
CODEX_EXIT_PATH="${REVIEWS_DIR}/codex_exit_code.txt"
CODEX_RAW_PATH="${REVIEWS_DIR}/codex_raw.txt"
PROMPT=$(cat "$REVIEW_PROMPT_CODEX_PATH")
OUT=$(mktemp)
CODEX_MODEL_FLAG=""
[ -n "$SIGNUM_CODEX_MODEL" ] && CODEX_MODEL_FLAG="--model $SIGNUM_CODEX_MODEL"
CODEX_PROFILE_FLAG=""
[ -n "$SIGNUM_CODEX_PROFILE" ] && CODEX_PROFILE_FLAG="-p $SIGNUM_CODEX_PROFILE"
mkdir -p "$REVIEWS_DIR"
codex exec --ephemeral -C "$PWD" $CODEX_PROFILE_FLAG $CODEX_MODEL_FLAG --output-last-message "$OUT" "$PROMPT" \
  > "$CODEX_STDOUT_PATH" 2>&1
echo $? > "$CODEX_EXIT_PATH"
cp "$OUT" "$CODEX_RAW_PATH" 2>/dev/null || \
  cp "$CODEX_STDOUT_PATH" "$CODEX_RAW_PATH"
rm -f "$OUT"
echo "CODEX_DONE"
```

**Gemini (Bash tool, `run_in_background: true`, only if GEMINI_AVAILABLE):**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
REVIEW_PROMPT_GEMINI_PATH="${ARTIFACT_ROOT}review_prompt_gemini.txt"
GEMINI_RAW_PATH="${REVIEWS_DIR}/gemini_raw.txt"
GEMINI_EXIT_PATH="${REVIEWS_DIR}/gemini_exit_code.txt"
PROMPT=$(cat "$REVIEW_PROMPT_GEMINI_PATH")
GEMINI_MODEL_FLAG=""
[ -n "$SIGNUM_GEMINI_MODEL" ] && GEMINI_MODEL_FLAG="--model $SIGNUM_GEMINI_MODEL"
mkdir -p "$REVIEWS_DIR"
gemini $GEMINI_MODEL_FLAG -p "$PROMPT" > "$GEMINI_RAW_PATH" 2>&1
echo $? > "$GEMINI_EXIT_PATH"
echo "GEMINI_DONE"
```

Save the background task IDs: CLAUDE_TASK_ID, CODEX_TASK_ID, GEMINI_TASK_ID. Do NOT wait for any of them before launching the others. Then proceed to Step 3.3 below.

### Step 3.3: Collect all 3 results

Use the TaskOutput tool with `block: true` to wait for CLAUDE_TASK_ID. Then use the TaskOutput tool with `block: true` to wait for CODEX_TASK_ID (if codex was launched). Then use the TaskOutput tool with `block: true` to wait for GEMINI_TASK_ID (if gemini was launched).

After all complete (or if they were never launched), verify the claude output:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
mkdir -p "$REVIEWS_DIR"
CLAUDE_REVIEW_PATH="${REVIEWS_DIR}/claude.json"
test -f "$CLAUDE_REVIEW_PATH" && jq -e '.verdict' "$CLAUDE_REVIEW_PATH" > /dev/null \
  && echo "claude review OK" || echo "WARNING: claude.json missing or invalid"
```

### Step 3.3.5: Parse codex and gemini outputs

After collection, parse codex output and parse gemini output.

If CODEX_AVAILABLE: check exit code first, then attempt 3-level parsing of `reviews/codex_raw.txt` under the canonical artifact root:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
CODEX_EXIT_PATH="${REVIEWS_DIR}/codex_exit_code.txt"
CODEX_STDOUT_PATH="${REVIEWS_DIR}/codex_stdout.txt"
CODEX_RAW_PATH="${REVIEWS_DIR}/codex_raw.txt"
CODEX_JSON_PATH="${REVIEWS_DIR}/codex.json"
CODEX_EXTRACTED_PATH="${ARTIFACT_ROOT}codex_extracted.json"
CODEX_EXIT=$(cat "$CODEX_EXIT_PATH" 2>/dev/null || echo "1")
if [ "$CODEX_EXIT" != "0" ]; then
  # Classify failure reason (transient = retry-worthy, permanent = skip)
  RAW=$(head -c 2000 "$CODEX_STDOUT_PATH" 2>/dev/null)
  FAILURE_REASON="unknown"
  ERROR_TYPE="unknown"
  if [ "$CODEX_EXIT" = "124" ]; then
    FAILURE_REASON="timeout"; ERROR_TYPE="transient"
  elif echo "$RAW" | grep -qi "rate.limit\|429\|too many"; then
    FAILURE_REASON="rate_limit"; ERROR_TYPE="transient"
  elif echo "$RAW" | grep -qi "auth\|token\|unauthorized\|401\|403"; then
    FAILURE_REASON="auth_expired"; ERROR_TYPE="permanent"
  elif echo "$RAW" | grep -qi "503\|529\|overloaded\|capacity"; then
    FAILURE_REASON="provider_overloaded"; ERROR_TYPE="transient"
  else
    FAILURE_REASON="adapter_crash"; ERROR_TYPE="permanent"
  fi
  jq -n --arg raw "$RAW" --arg code "$CODEX_EXIT" --arg reason "$FAILURE_REASON" --arg etype "$ERROR_TYPE" \
    '{"verdict":"UNAVAILABLE","findings":[],"concerns":[],"summary":("Codex invocation failed (exit " + $code + ")"),"available":false,"failure_reason":$reason,"error_type":$etype,"raw":$raw}' \
    > "$CODEX_JSON_PATH"
  echo "codex: invocation failed (exit $CODEX_EXIT), reason=$FAILURE_REASON ($ERROR_TYPE)"

# Level 1: valid JSON directly
elif jq -e '.verdict' "$CODEX_RAW_PATH" > /dev/null 2>&1; then
  cp "$CODEX_RAW_PATH" "$CODEX_JSON_PATH"
  echo "codex: parsed as direct JSON"

# Level 2: extract between markers
elif grep -q '###SIGNUM_REVIEW_START###' "$CODEX_RAW_PATH"; then
  sed -n '/###SIGNUM_REVIEW_START###/,/###SIGNUM_REVIEW_END###/p' "$CODEX_RAW_PATH" \
    | grep -v '###SIGNUM_REVIEW' > "$CODEX_EXTRACTED_PATH"
  if jq -e '.verdict' "$CODEX_EXTRACTED_PATH" > /dev/null 2>&1; then
    cp "$CODEX_EXTRACTED_PATH" "$CODEX_JSON_PATH"
    echo "codex: parsed via markers"
  else
    RAW=$(head -c 2000 "$CODEX_RAW_PATH")
    jq -n --arg raw "$RAW" \
      '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse codex output","parseOk":false,"raw":$raw}' \
      > "$CODEX_JSON_PATH"
    echo "codex: marker extraction failed, saved raw"
  fi

# Level 3: save raw, mark unparseable
else
  RAW=$(head -c 2000 "$CODEX_RAW_PATH")
  jq -n --arg raw "$RAW" \
    '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse codex output","parseOk":false,"raw":$raw}' \
    > "$CODEX_JSON_PATH"
  echo "codex: no markers found, saved raw"
fi
```

If CODEX_UNAVAILABLE:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
CODEX_JSON_PATH="${REVIEWS_DIR}/codex.json"
mkdir -p "$REVIEWS_DIR"
echo '{"verdict":"UNAVAILABLE","findings":[],"summary":"Codex CLI not installed","available":false}' \
  > "$CODEX_JSON_PATH"
```

Parse gemini output:

If GEMINI_AVAILABLE: check exit code first, then attempt 3-level parsing of `reviews/gemini_raw.txt` under the canonical artifact root:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
GEMINI_EXIT_PATH="${REVIEWS_DIR}/gemini_exit_code.txt"
GEMINI_RAW_PATH="${REVIEWS_DIR}/gemini_raw.txt"
GEMINI_JSON_PATH="${REVIEWS_DIR}/gemini.json"
GEMINI_STRIPPED_PATH="${ARTIFACT_ROOT}gemini_stripped.txt"
GEMINI_EXTRACTED_PATH="${ARTIFACT_ROOT}gemini_extracted.json"
GEMINI_EXIT=$(cat "$GEMINI_EXIT_PATH" 2>/dev/null || echo "1")
if [ "$GEMINI_EXIT" != "0" ]; then
  # Classify failure reason (transient = retry-worthy, permanent = skip)
  RAW=$(head -c 2000 "$GEMINI_RAW_PATH" 2>/dev/null)
  FAILURE_REASON="unknown"
  ERROR_TYPE="unknown"
  if [ "$GEMINI_EXIT" = "124" ]; then
    FAILURE_REASON="timeout"; ERROR_TYPE="transient"
  elif echo "$RAW" | grep -qi "rate.limit\|429\|too many"; then
    FAILURE_REASON="rate_limit"; ERROR_TYPE="transient"
  elif echo "$RAW" | grep -qi "auth\|token\|unauthorized\|401\|403"; then
    FAILURE_REASON="auth_expired"; ERROR_TYPE="permanent"
  elif echo "$RAW" | grep -qi "503\|529\|overloaded\|capacity"; then
    FAILURE_REASON="provider_overloaded"; ERROR_TYPE="transient"
  else
    FAILURE_REASON="adapter_crash"; ERROR_TYPE="permanent"
  fi
  jq -n --arg raw "$RAW" --arg code "$GEMINI_EXIT" --arg reason "$FAILURE_REASON" --arg etype "$ERROR_TYPE" \
    '{"verdict":"UNAVAILABLE","findings":[],"concerns":[],"summary":("Gemini invocation failed (exit " + $code + ")"),"available":false,"failure_reason":$reason,"error_type":$etype,"raw":$raw}' \
    > "$GEMINI_JSON_PATH"
  echo "gemini: invocation failed (exit $GEMINI_EXIT), reason=$FAILURE_REASON ($ERROR_TYPE)"

# Level 0.5: strip markdown code fences (```json ... ```) if present
elif sed -n '1{/^```/d}; ${/^```/d}; p' "$GEMINI_RAW_PATH" | sed 's/^```json$//' | sed 's/^```$//' > "$GEMINI_STRIPPED_PATH" \
  && jq -e '.verdict' "$GEMINI_STRIPPED_PATH" > /dev/null 2>&1; then
  cp "$GEMINI_STRIPPED_PATH" "$GEMINI_JSON_PATH"
  rm -f "$GEMINI_STRIPPED_PATH"
  echo "gemini: parsed after stripping markdown fences"

# Level 1: valid JSON directly
elif jq -e '.verdict' "$GEMINI_RAW_PATH" > /dev/null 2>&1; then
  cp "$GEMINI_RAW_PATH" "$GEMINI_JSON_PATH"
  echo "gemini: parsed as direct JSON"

elif grep -q '###SIGNUM_REVIEW_START###' "$GEMINI_RAW_PATH"; then
  sed -n '/###SIGNUM_REVIEW_START###/,/###SIGNUM_REVIEW_END###/p' "$GEMINI_RAW_PATH" \
    | grep -v '###SIGNUM_REVIEW' > "$GEMINI_EXTRACTED_PATH"
  if jq -e '.verdict' "$GEMINI_EXTRACTED_PATH" > /dev/null 2>&1; then
    cp "$GEMINI_EXTRACTED_PATH" "$GEMINI_JSON_PATH"
    echo "gemini: parsed via markers"
  else
    RAW=$(head -c 2000 "$GEMINI_RAW_PATH")
    jq -n --arg raw "$RAW" \
      '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse gemini output","parseOk":false,"raw":$raw}' \
      > "$GEMINI_JSON_PATH"
    echo "gemini: marker extraction failed, saved raw"
  fi

else
  RAW=$(head -c 2000 "$GEMINI_RAW_PATH")
  jq -n --arg raw "$RAW" \
    '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse gemini output","parseOk":false,"raw":$raw}' \
    > "$GEMINI_JSON_PATH"
  echo "gemini: no markers found, saved raw"
fi
```

If GEMINI_UNAVAILABLE:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
GEMINI_JSON_PATH="${REVIEWS_DIR}/gemini.json"
mkdir -p "$REVIEWS_DIR"
echo '{"verdict":"UNAVAILABLE","findings":[],"summary":"Gemini CLI not installed","available":false}' \
  > "$GEMINI_JSON_PATH"
```

### Step 3.5: Synthesizer (agent)

Use the Agent tool to launch the "synthesizer" agent with this prompt:

```
The canonical artifact root for this synthesis is `.signum/contracts/<activeContractId>/`.
Read `mechanic_report.json`, `reviews/claude.json`, `reviews/codex.json`, `reviews/gemini.json`, `holdout_report.json`, and `execute_log.json` from that canonical artifact root.
Apply deterministic synthesis rules, compute confidence scores, and write `audit_summary.json` to that same canonical artifact root.
```

After it finishes, read and display the audit summary:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
test -f "$AUDIT_SUMMARY_PATH" || { echo "ERROR: audit_summary.json not found"; exit 1; }

jq -r '"=== AUDIT SUMMARY ===",
       "Mechanic: " + (.mechanic // "unknown"),
       "Regressions: " + (if .mechanic == "regression" then "YES" else "none" end),
       "Claude verdict: " + .reviews.claude.verdict,
       "Codex verdict:  " + .reviews.codex.verdict,
       "Gemini verdict: " + .reviews.gemini.verdict,
       "Available reviews: " + (.availableReviews | tostring) + "/3",
       "Holdout: " + ((.holdout.passed // 0) | tostring) + "/" + ((.holdout.total // 0) | tostring) + " passed",
       "Consensus: " + .consensus,
       "Confidence: " + ((.confidence.overall // 0) | tostring) + "%",
       "DECISION: " + .decision,
       "Reasoning: " + .reasoning'   "$AUDIT_SUMMARY_PATH"
```

### Step 3.6: Iterative AUDIT Loop

After synthesizer produces the audit summary, check if iterative repair is needed.

Read the iteration config:

```bash
MAX_ITERATIONS=${SIGNUM_AUDIT_MAX_ITERATIONS:-20}
CURRENT_ITERATION=1
BEST_SCORE=0
BEST_ITERATION=0
NO_IMPROVE_COUNT=0
echo "Iterative AUDIT config: max_iterations=$MAX_ITERATIONS"
```

Check the audit summary decision and findings:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
AUDIT_DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
HAS_MAJOR=$(jq '[.reviews[].findings[]? | select(.severity == "MAJOR" or .severity == "CRITICAL")] | length' "$AUDIT_SUMMARY_PATH")
HAS_REGRESSIONS=$(jq -r '.mechanic' "$AUDIT_SUMMARY_PATH" | grep -q "regression" && echo "true" || echo "false")
HOLDOUT_FAILURES=$(jq -r '.holdout.failed // 0' "$AUDIT_SUMMARY_PATH")

# Compute iteration score from audit_summary findings (synthesizer emits the score field in iterative mode)
_CRITICALS=$(jq '[.reviews[].findings[]? | select(.severity == "CRITICAL")] | length' "$AUDIT_SUMMARY_PATH")
_MAJORS=$(jq '[.reviews[].findings[]? | select(.severity == "MAJOR")] | length' "$AUDIT_SUMMARY_PATH")
_MINORS=$(jq '[.reviews[].findings[]? | select(.severity == "MINOR")] | length' "$AUDIT_SUMMARY_PATH")
_MECH_REGRESSIONS=$(jq 'if .hasRegressions then 1 else 0 end' "$MECHANIC_REPORT_PATH")
_HOLDOUT_FAILURES=$(jq '.failed // 0' "$HOLDOUT_REPORT_PATH" 2>/dev/null || echo 0)
ITERATION_SCORE=$(( -(_CRITICALS * 1000) - (_MECH_REGRESSIONS * 500) - (_HOLDOUT_FAILURES * 200) - (_MAJORS * 50) - (_MINORS * 1) ))

echo "Pass 1: decision=$AUDIT_DECISION major_findings=$HAS_MAJOR regressions=$HAS_REGRESSIONS holdout_failures=$HOLDOUT_FAILURES score=$ITERATION_SCORE"
```

**If `AUDIT_DECISION` is `AUTO_OK`, or if there are no MAJOR/CRITICAL findings AND no mechanic regressions AND no holdout failures → proceed directly to Phase 4 (PACK).**

Otherwise, enter the iterative repair loop:

#### Step 3.6.1: Initialize iteration tracking

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
PASS1_DIR="${ARTIFACT_ROOT}iterations/01"
PASS1_REVIEWS_DIR="${PASS1_DIR}/reviews"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
AUDIT_ITERATION_LOG_PATH="${ARTIFACT_ROOT}audit_iteration_log.json"

# Store pass 1 artifacts
mkdir -p "$PASS1_REVIEWS_DIR"
cp "$COMBINED_PATCH_PATH" "$PASS1_DIR/"
cp "$MECHANIC_REPORT_PATH" "$PASS1_DIR/"
cp "$HOLDOUT_REPORT_PATH" "$PASS1_DIR/" 2>/dev/null || true
cp "$EXECUTE_LOG_PATH" "$PASS1_DIR/" 2>/dev/null || true
cp "$REVIEWS_DIR/"*.json "$PASS1_REVIEWS_DIR/" 2>/dev/null || true
cp "$AUDIT_SUMMARY_PATH" "$PASS1_DIR/"

# Initialize iteration log
BEST_SCORE=$ITERATION_SCORE
BEST_ITERATION=1
PASS1_FINDINGS=$(jq '[.reviews[].findings[]? | {fingerprint: .fingerprint, severity: .severity, category: .category, file: .file, line: .line}] | unique_by(.fingerprint // (.file + ":" + (.line | tostring) + ":" + .category))' "$AUDIT_SUMMARY_PATH")
PASS1_FINDINGS_COUNT=$(jq '{
  critical: [.reviews[].findings[]? | select(.severity == "CRITICAL")] | length,
  major: [.reviews[].findings[]? | select(.severity == "MAJOR")] | length,
  minor: [.reviews[].findings[]? | select(.severity == "MINOR")] | length
}' "$AUDIT_SUMMARY_PATH")
MECH_REG=$(jq -r '.hasRegressions' "$MECHANIC_REPORT_PATH" 2>/dev/null || echo "false")
HOLDOUT_FAIL=$(jq '.failed // 0' "$HOLDOUT_REPORT_PATH" 2>/dev/null || echo 0)
jq -n --argjson score "$ITERATION_SCORE" --argjson findings "$PASS1_FINDINGS" --argjson findingsCount "$PASS1_FINDINGS_COUNT"   --arg mechReg "$MECH_REG" --argjson holdoutFail "$HOLDOUT_FAIL"   '[{"pass": 1, "score": $score, "decision": "'"$AUDIT_DECISION"'", "findingsCount": $findingsCount, "canonicalFindings": $findings, "mechanicRegressions": ($mechReg == "true"), "holdoutFailures": $holdoutFail}]'   > "$AUDIT_ITERATION_LOG_PATH"

echo "Iteration 1 stored. Best score: $BEST_SCORE"
```

#### Step 3.6.2: Repair loop

For each iteration from 2 to MAX_ITERATIONS:

**Check entry conditions:**

```bash
# Skip if already clean
if [ "$AUDIT_DECISION" = "AUTO_OK" ]; then
  echo "Clean result at iteration $CURRENT_ITERATION. Exiting loop."
  break
fi

# Early stop: 2 consecutive non-improving iterations
if [ "$NO_IMPROVE_COUNT" -ge 2 ]; then
  echo "Early stop: no improvement for 2 consecutive iterations."
  break
fi
```

**Rollback to best candidate if current is worse:**

```bash
SKIP_ITERATION=false
if [ "$ITERATION_SCORE" -lt "$BEST_SCORE" ] && [ "$CURRENT_ITERATION" -gt 1 ]; then
  echo "Current score ($ITERATION_SCORE) worse than best ($BEST_SCORE at iteration $BEST_ITERATION). Rolling back."
  source lib/contract-dir.sh 2>/dev/null || true
  ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
  REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
  EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
  COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
  ITERATION_DELTA_PATH="${ARTIFACT_ROOT}iteration_delta.patch"
  MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
  HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
  EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
  AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
  # Rollback: revert files from current patch (if exists) or best iteration's stored patch
  BASE=$(jq -r '.base_commit' "$EXECUTION_CONTEXT_PATH")
  ROLLBACK_PATCH="$COMBINED_PATCH_PATH"
  [ ! -f "$ROLLBACK_PATCH" ] && ROLLBACK_PATCH="${ARTIFACT_ROOT}iterations/$(printf '%02d' $BEST_ITERATION)/combined.patch"
  PATCH_FILES=$(grep '^diff --git' "$ROLLBACK_PATCH" 2>/dev/null | sed 's|^diff --git a/||; s| b/.*||' | sort -u)
  for f in $PATCH_FILES; do
    git checkout "$BASE" -- "$f" 2>/dev/null || rm -f "$f" 2>/dev/null || true
  done
  if git apply "${ARTIFACT_ROOT}iterations/$(printf '%02d' $BEST_ITERATION)/combined.patch"; then
    # Sync canonical working copies from best iteration
    BEST_DIR="${ARTIFACT_ROOT}iterations/$(printf '%02d' $BEST_ITERATION)"
    cp "${BEST_DIR}/combined.patch" "$COMBINED_PATCH_PATH" 2>/dev/null || true
    cp "${BEST_DIR}/iteration_delta.patch" "$ITERATION_DELTA_PATH" 2>/dev/null || reset_canonical_active_artifact "iteration_delta.patch"
    cp "${BEST_DIR}/mechanic_report.json" "$MECHANIC_REPORT_PATH" 2>/dev/null || true
    cp "${BEST_DIR}/holdout_report.json" "$HOLDOUT_REPORT_PATH" 2>/dev/null || true
    cp "${BEST_DIR}/execute_log.json" "$EXECUTE_LOG_PATH" 2>/dev/null || true
    rm -f "$REVIEWS_DIR/"*.json
    cp "${BEST_DIR}/reviews/"*.json "$REVIEWS_DIR/" 2>/dev/null || true
    cp "${BEST_DIR}/audit_summary.json" "$AUDIT_SUMMARY_PATH" 2>/dev/null || true
  else
    echo "ROLLBACK_FAILED: git apply failed for iteration $BEST_ITERATION - forcing early stop"
    NO_IMPROVE_COUNT=99
    SKIP_ITERATION=true
  fi
fi
# If rollback failed, skip repair engineer and audit re-run. The early stop condition
# (NO_IMPROVE_COUNT=99) will terminate the loop on the next entry condition check.
```

**If `SKIP_ITERATION` is `true`, skip the repair engineer launch and all remaining steps in this iteration — proceed directly back to "Check entry conditions", which will trigger early stop due to `NO_IMPROVE_COUNT=99`.**

**Build repair brief:**

Use the Bash tool to construct `repair_brief.json` under the canonical artifact root from the current audit summary (which now reflects the best candidate after any rollback):

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
REPAIR_BRIEF_PATH="${ARTIFACT_ROOT}repair_brief.json"
ITER_NUM=$((CURRENT_ITERATION + 1))

# Extract MAJOR+ findings from all reviewers
FINDINGS=$(jq '[.reviews | to_entries[] | .value.findings[]? | select(.severity == "MAJOR" or .severity == "CRITICAL") | {fingerprint: .fingerprint, severity: .severity, category: .category, file: .file, line: .line, comment: .comment, evidence: .evidence}]' "$AUDIT_SUMMARY_PATH")

# Sanitize holdout summary (category only, no details)
HOLDOUT_SUMMARY=""
if [ -f "$HOLDOUT_REPORT_PATH" ]; then
  HOLDOUT_FAILED=$(jq '.failed // 0' "$HOLDOUT_REPORT_PATH")
  if [ "$HOLDOUT_FAILED" -gt 0 ]; then
    # Extract categories via keyword matching on descriptions
    HOLDOUT_CATS=$(jq -r '[.results[] | select(.status != "PASS") | .description | ascii_downcase |
      if test("boundary|edge case|limit") then "boundary input"
      elif test("error|exception|fail") then "error handling"
      elif test("concurrent|race|parallel") then "concurrency"
      elif test("empty|null|missing") then "null/empty input"
      else "unspecified" end] | unique | join(", ")' "$HOLDOUT_REPORT_PATH")
    HOLDOUT_SUMMARY="${HOLDOUT_FAILED} holdout(s) failed (categories: ${HOLDOUT_CATS})"
  fi
fi

# Build mechanic regression summary and typed findings
MECH_SUMMARY=""
MECH_FINDINGS='[]'
MECH_REG=$(jq -r '.hasRegressions' "$MECHANIC_REPORT_PATH")
if [ "$MECH_REG" = "true" ]; then
  MECH_SUMMARY=$(jq -r '
    [if .lint.regression then "lint regression" else empty end,
     if .typecheck.regression then "typecheck regression" else empty end,
     if .tests.regression then "test regression (" + (.tests.newFailures | length | tostring) + " new failures)" else empty end
    ] | join(", ")' "$MECHANIC_REPORT_PATH")
  # Extract typed per-file findings from regression checks only
  MECH_FINDINGS=$(jq '[
    .findings[]? |
    . as $f |
    (.check_id) as $cid |
    # Find the check entry to get category and regression flag
    ([ (if . then . else null end) ] | first) as $_ |
    $f
  ] | if length == 0 then [] else . end' "$MECHANIC_REPORT_PATH" 2>/dev/null || echo '[]')
  # Filter to only regression checks
  REGRESSION_IDS=$(jq -r '[.checks[]? | select(.regression == true) | .id] | join(" ")' "$MECHANIC_REPORT_PATH" 2>/dev/null || echo "")
  if [ -n "$REGRESSION_IDS" ]; then
    MECH_FINDINGS=$(jq '
      (.checks // [] | map({(.id): .category}) | add // {}) as $cat_map |
      (.checks // [] | [.[] | select(.regression == true) | .id]) as $reg_ids |
      [.findings[]? | select(.check_id as $cid | $reg_ids | index($cid) != null) |
        # Normalize file path: reject absolute paths and path traversal attempts
        . as $entry |
        ($entry.file // "") as $raw_file |
        (if ($raw_file | startswith("/")) or ($raw_file | test("(^|/)\.\.(/|$)"))
         then ""
         else $raw_file end) as $safe_file |
        {check_id: $entry.check_id, category: ($cat_map[$entry.check_id] // "unknown"), file: $safe_file, line: $entry.line, column: $entry.column, code: $entry.code, message: $entry.message, origin: $entry.origin}]'       "$MECHANIC_REPORT_PATH" 2>/dev/null || echo '[]')
  else
    MECH_FINDINGS='[]'
  fi
fi

jq -n   --argjson iteration "$ITER_NUM"   --argjson findings "$FINDINGS"   --arg holdout_summary "$HOLDOUT_SUMMARY"   --arg mechanic_summary "$MECH_SUMMARY"   --argjson mechanic_findings "$MECH_FINDINGS"   '{
    iteration: $iteration,
    deterministicFailures: {
      mechanic: (if $mechanic_summary != "" then $mechanic_summary else null end),
      holdout: (if $holdout_summary != "" then $holdout_summary else null end)
    },
    reviewFindings: $findings,
    mechanicFindings: (if ($mechanic_findings | length) > 0 then $mechanic_findings else [] end),
    constraints: [
      "Fix ONLY the listed findings",
      "Minimal diff - no unrelated refactors",
      "Do not break already-passing acceptance criteria",
      "Re-run visible AC verifies after fix"
    ]
  }' > "$REPAIR_BRIEF_PATH"

echo "Repair brief built: $(jq '.reviewFindings | length' "$REPAIR_BRIEF_PATH") findings, $(jq '.mechanicFindings | length' "$REPAIR_BRIEF_PATH") mechanic findings"
```

**Capture pre-repair snapshot (receipt chain):**

Before launching repair engineers, capture a fresh workspace snapshot for this attempt. Each attempt needs its own snapshot because `base_tree_hash` must bind to the actual starting state of this repair.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"

# Re-resolve snapshot-tree.sh (each Bash tool call is a fresh shell)
_SIGNUM_SNAPSHOT=""
for _d in \
  "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
  "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
  "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
  [ -f "${_d}/lib/snapshot-tree.sh" ] || continue
  _SIGNUM_SNAPSHOT="${_d}/lib/snapshot-tree.sh"
  break
done
ATTEMPT_PAD=$(printf '%02d' "$((CURRENT_ITERATION + 1))")
if [ -n "$_SIGNUM_SNAPSHOT" ]; then
  bash "$_SIGNUM_SNAPSHOT" "execute-attempt-${ATTEMPT_PAD}" --workspace-root "$PWD" --signum-dir "$ARTIFACT_ROOT"
  echo "Pre-repair snapshot captured: execute-attempt-${ATTEMPT_PAD}"
fi
```

**Clear stale engineer artifacts before launching repair:**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"

# Save current best combined.patch for worktree seeding BEFORE deleting stale artifacts
_SEED_PATCH=""
if [ -f "$COMBINED_PATCH_PATH" ]; then
  _SEED_PATCH=$(mktemp /tmp/signum_seed_XXXXXX.patch)
  cp "$COMBINED_PATCH_PATH" "$_SEED_PATCH"
fi

# Remove stale artifacts from the canonical active root only.
source lib/contract-dir.sh
reset_canonical_active_artifact "combined.patch"
reset_canonical_active_artifact "execute_log.json"
reset_canonical_active_artifact "iteration_delta.patch"
```

**Launch repair engineer (parallel lanes):**

Set up two isolated git worktrees and run both engineers in parallel. The two strategies are:

- **Lane A**: Fix with minimal targeted changes. Patch only the specific lines flagged in findings.
- **Lane B**: Fix by addressing the root cause. May touch more files if the findings share a common underlying issue.

If worktree creation fails for either lane, fall back to single-lane behavior (the original single-engineer dispatch) without aborting the iteration.

Each lane works in an isolated git worktree seeded from `base_commit` + current best `combined.patch`. Worktree paths live under `iterations/NN/lanes/` inside the active contract artifact root.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
ITERATIONS_DIR="${ARTIFACT_ROOT}iterations"
ITER_PAD=$(printf '%02d' $ITER_NUM)
BASE_COMMIT=$(jq -r '.base_commit' "$EXECUTION_CONTEXT_PATH")
LANE_PATHS=( "${ITERATIONS_DIR}/${ITER_PAD}/lanes/A" "${ITERATIONS_DIR}/${ITER_PAD}/lanes/B" )
mkdir -p "${LANE_PATHS[0]}" "${LANE_PATHS[1]}"

# _prune_lanes: remove both worktrees; safe to call multiple times
_prune_lanes() {
  for _lp in "${LANE_PATHS[@]}"; do git worktree remove --force "$_lp" 2>/dev/null || true; done
}

# Trap ensures cleanup on exit even if the iteration is interrupted
_LANE_CLEANUP_DONE=false
trap 'if [ "$_LANE_CLEANUP_DONE" = "false" ]; then _prune_lanes; _LANE_CLEANUP_DONE=true; fi' EXIT

# Try to create both worktrees; if either fails, set WORKTREE_OK=false for fallback to single-lane
WORKTREE_OK=true
for _lp in "${LANE_PATHS[@]}"; do
  if [ "$WORKTREE_OK" = "true" ] && ! git worktree add "$_lp" "$BASE_COMMIT" 2>/dev/null; then
    echo "LANE_FALLBACK: worktree creation failed for $_lp — falling back to single-lane"
    _prune_lanes
    WORKTREE_OK=false
  fi
done

# Apply current best combined.patch to each worktree to seed from current best state
if [ "$WORKTREE_OK" = "true" ] && [ -n "$_SEED_PATCH" ] && [ -f "$_SEED_PATCH" ]; then
  for _lp in "${LANE_PATHS[@]}"; do
    git -C "$_lp" apply --index "$_SEED_PATCH" 2>/dev/null || true
  done
  rm -f "$_SEED_PATCH"
fi
```

If `WORKTREE_OK` is `false`, fall back to single-lane: use the Agent tool to launch the "engineer" agent with the original prompt (no strategy hint), writing `combined.patch` and `execute_log.json` under the active contract artifact root, then skip ahead to "After engineer completes, validate execute success".

If `WORKTREE_OK` is `true`, launch both lane engineers in parallel using the Agent tool.

For the engineer working in `${LANE_PATHS[0]}`, use this prompt (strategy: minimal targeted changes):

```
STRATEGY HINT: Fix with minimal targeted changes. Patch only the specific lines flagged in findings.
The canonical artifact root in this lane is `.signum/contracts/<activeContractId>/`.
Read `contract-engineer.json`, `baseline.json`, and `repair_brief.json` from that canonical artifact root.
Fix ONLY the issues listed in the repair brief. Do not refactor, do not add features.
After fixing, run the visible AC verifies to confirm you didn't break them.
Write ${LANE_PATHS[0]}/combined.patch and ${LANE_PATHS[0]}/execute_log.json.
IMPORTANT: Work in ${LANE_PATHS[0]}
```

For the engineer working in `${LANE_PATHS[1]}`, use this prompt (strategy: root cause):

```
STRATEGY HINT: Fix by addressing the root cause. May touch more files if the findings share a common underlying issue.
The canonical artifact root in this lane is `.signum/contracts/<activeContractId>/`.
Read `contract-engineer.json`, `baseline.json`, and `repair_brief.json` from that canonical artifact root.
Fix ONLY the issues listed in the repair brief. Do not refactor, do not add features.
After fixing, run the visible AC verifies to confirm you didn't break them.
Write ${LANE_PATHS[1]}/combined.patch and ${LANE_PATHS[1]}/execute_log.json.
IMPORTANT: Work in ${LANE_PATHS[1]}
```

After both engineers complete, run mechanic (`lib/mechanic-parser.sh`) and holdout validation independently for each lane, writing results to `${LANE_PATHS[0]}/mechanic_report.json`, `${LANE_PATHS[0]}/holdout_report.json`, `${LANE_PATHS[1]}/mechanic_report.json`, and `${LANE_PATHS[1]}/holdout_report.json`.

**Select winner by iteration score:**

Compute the iteration score for each lane using the existing formula: `-(CRITICALS*1000) - (MECH_REGRESSIONS*500) - (HOLDOUT_FAILURES*200) - (MAJORS*50) - (MINORS*1)`. The lane with the higher score wins. On a tie, the minimal-changes lane (A) is preferred.

```bash
_lane_score() {
  local lane_dir="$1"
  local mech_reg holdout_fail
  mech_reg=$(jq 'if .hasRegressions then 1 else 0 end' "$lane_dir/mechanic_report.json" 2>/dev/null || echo 0)
  holdout_fail=$(jq '.failed // 0' "$lane_dir/holdout_report.json" 2>/dev/null || echo 0)
  echo $(( -(mech_reg*500) - (holdout_fail*200) ))
}

SCORE_A=$(_lane_score "${LANE_PATHS[0]}")
SCORE_B=$(_lane_score "${LANE_PATHS[1]}")
LANE_SELECTED_DIR="${ITERATIONS_DIR}/${ITER_PAD}/lanes"

if [ "$SCORE_A" -ge "$SCORE_B" ]; then
  WINNER_LANE="A"; RUNNER_UP_LANE="B"
  WINNER_SCORE=$SCORE_A; RUNNER_UP_SCORE=$SCORE_B
  WINNER_REASON="score_a=$SCORE_A >= score_b=$SCORE_B; minimal-changes preferred on tie"
else
  WINNER_LANE="B"; RUNNER_UP_LANE="A"
  WINNER_SCORE=$SCORE_B; RUNNER_UP_SCORE=$SCORE_A
  WINNER_REASON="score_b=$SCORE_B > score_a=$SCORE_A"
fi

jq -n \
  --arg winner "$WINNER_LANE" \
  --arg runner_up "$RUNNER_UP_LANE" \
  --argjson winner_score "$WINNER_SCORE" \
  --argjson runner_up_score "$RUNNER_UP_SCORE" \
  --arg reason "$WINNER_REASON" \
  '{winner: $winner, runner_up: $runner_up, winner_score: $winner_score, runner_up_score: $runner_up_score, reason: $reason}' \
  > "$LANE_SELECTED_DIR/selected_lane.json"

echo "Winner: lane $WINNER_LANE (score $WINNER_SCORE); loser: lane $RUNNER_UP_LANE (score $RUNNER_UP_SCORE)"
```

**Run full review panel (Claude + Codex + Gemini) on winner only.**

If the winner receives a MAJOR or CRITICAL finding after the panel, also send the runner-up lane through the full review panel before declaring the iteration result. After the runner-up panel completes, re-score; if it now beats the winner, promote the runner-up and update the lane selection record.

**Copy winner artifacts to iteration root:**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
if [ "$WINNER_LANE" = "A" ]; then WINNER_DIR="${LANE_PATHS[0]}"; else WINNER_DIR="${LANE_PATHS[1]}"; fi
cp "$WINNER_DIR/combined.patch" "$COMBINED_PATCH_PATH"
cp "$WINNER_DIR/execute_log.json" "$EXECUTE_LOG_PATH" 2>/dev/null || true
cp "$WINNER_DIR/mechanic_report.json" "$MECHANIC_REPORT_PATH" 2>/dev/null || true
cp "$WINNER_DIR/holdout_report.json" "$HOLDOUT_REPORT_PATH" 2>/dev/null || true
mkdir -p "$REVIEWS_DIR"
cp "$WINNER_DIR/reviews/"*.json "$REVIEWS_DIR/" 2>/dev/null || true
cp "$WINNER_DIR/audit_summary.json" "$AUDIT_SUMMARY_PATH" 2>/dev/null || true
```

**Run boundary verification on winner BEFORE pruning worktrees (receipt chain):**

Boundary verification must run while the winner worktree still exists — it needs the live workspace to verify file hashes, scope integrity, and AC evidence. Pruning worktrees before verification would cause the verifier to run against stale main checkout.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
SNAPSHOTS_DIR="${ARTIFACT_ROOT}snapshots"
RECEIPTS_DIR="${ARTIFACT_ROOT}receipts"
RUNS_DIR="${ARTIFACT_ROOT}runs"
WINNER_SIGNUM_DIR="${WINNER_DIR}/.signum"
WINNER_ACTIVE_CONTRACT_ID=$(jq -r '.activeContractId // empty' "${WINNER_SIGNUM_DIR}/contracts/index.json" 2>/dev/null || true)
if [ -z "$WINNER_ACTIVE_CONTRACT_ID" ]; then
  WINNER_ACTIVE_CONTRACT_ID="$(get_active_contract 2>/dev/null || true)"
fi
if [ -n "$WINNER_ACTIVE_CONTRACT_ID" ]; then
  WINNER_ARTIFACT_ROOT="${WINNER_SIGNUM_DIR}/contracts/${WINNER_ACTIVE_CONTRACT_ID}/"
else
  WINNER_ARTIFACT_ROOT="${WINNER_SIGNUM_DIR}/"
fi

# Re-resolve boundary-verifier.sh and transition-verifier.sh (fresh shell)
_SIGNUM_BOUNDARY=""
_SIGNUM_TRANSITION=""
for _d in \
  "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
  "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
  "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
  [ -z "$_SIGNUM_BOUNDARY" ] && [ -f "${_d}/lib/boundary-verifier.sh" ] && \
    _SIGNUM_BOUNDARY="${_d}/lib/boundary-verifier.sh"
  [ -z "$_SIGNUM_TRANSITION" ] && [ -f "${_d}/lib/transition-verifier.sh" ] && \
    _SIGNUM_TRANSITION="${_d}/lib/transition-verifier.sh"
done

RECEIPT_CHAIN_OK=true
if [ -n "$_SIGNUM_BOUNDARY" ]; then
  ATTEMPT_PAD=$(printf '%02d' "$((CURRENT_ITERATION + 1))")
  if ! bash "$_SIGNUM_BOUNDARY" execute \
    --workspace-root "$WINNER_DIR" \
    --signum-dir "$WINNER_SIGNUM_DIR" \
    --contract "${WINNER_ARTIFACT_ROOT}contract-engineer.json" \
    --contract-full "${WINNER_ARTIFACT_ROOT}contract.json" \
    --snapshot "${SNAPSHOTS_DIR}/execute-attempt-${ATTEMPT_PAD}.json"; then
    echo "BOUNDARY_BLOCK: repair attempt $((CURRENT_ITERATION + 1)) failed boundary verification"
    RECEIPT_CHAIN_OK=false
  fi
  # Copy receipt from winner worktree into the canonical artifact root.
  _CURRENT_RUN_ID=$(jq -r '.run_id // empty' "$EXECUTION_CONTEXT_PATH")
  mkdir -p "$RECEIPTS_DIR" "$RUNS_DIR/$_CURRENT_RUN_ID"
  cp "${WINNER_ARTIFACT_ROOT}receipts/execute.json" "$RECEIPTS_DIR/execute.json" 2>/dev/null || true
  if [ -d "${WINNER_ARTIFACT_ROOT}runs/$_CURRENT_RUN_ID" ]; then
    cp "${WINNER_ARTIFACT_ROOT}runs/$_CURRENT_RUN_ID/execute-"*.json \
      "$RUNS_DIR/$_CURRENT_RUN_ID/" 2>/dev/null || true
  fi
fi
if [ "$RECEIPT_CHAIN_OK" = "true" ] && [ -n "$_SIGNUM_TRANSITION" ]; then
  ATTEMPT_PAD=$(printf '%02d' "$((CURRENT_ITERATION + 1))")
  if ! bash "$_SIGNUM_TRANSITION" execute audit \
    --snapshot "${SNAPSHOTS_DIR}/execute-attempt-${ATTEMPT_PAD}.json"; then
    echo "TRANSITION_BLOCK: repair attempt $((CURRENT_ITERATION + 1)) failed transition gate"
    RECEIPT_CHAIN_OK=false
  fi
fi
```

**Clean up worktrees after boundary verification:**

```bash
_prune_lanes
_LANE_CLEANUP_DONE=true
```

If `RECEIPT_CHAIN_OK` is `false`, **STOP** the repair iteration. Do not proceed to audit — boundary enforcement is a hard gate, not an advisory.

**After engineer completes, validate execute success before re-running audit:**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
ITERATION_DELTA_PATH="${ARTIFACT_ROOT}iteration_delta.patch"

# Execute success gate: verify engineer produced NEW artifacts (stale ones were cleared above)
if [ ! -f "$EXECUTE_LOG_PATH" ]; then
  echo "REPAIR_SKIP: execute_log.json missing after repair engineer - skipping iteration $ITER_NUM"
  CURRENT_ITERATION=$ITER_NUM
  continue
fi
REPAIR_STATUS=$(jq -r '.status // "unknown"' "$EXECUTE_LOG_PATH")
if [ "$REPAIR_STATUS" != "SUCCESS" ]; then
  echo "REPAIR_SKIP: execute_log.json status=$REPAIR_STATUS (not SUCCESS) - skipping iteration $ITER_NUM"
  CURRENT_ITERATION=$ITER_NUM
  continue
fi
if [ ! -f "$COMBINED_PATCH_PATH" ]; then
  echo "REPAIR_SKIP: combined.patch missing after repair engineer - skipping iteration $ITER_NUM"
  CURRENT_ITERATION=$ITER_NUM
  continue
fi
echo "Repair engineer succeeded for iteration $ITER_NUM - proceeding to audit"

# Compute iteration delta by diffing the two stored patches (best candidate vs current)
# The engineer already wrote combined.patch; we diff it against the best iteration's patch
BEST_PATCH="${ARTIFACT_ROOT}iterations/$(printf '%02d' $BEST_ITERATION)/combined.patch"
if [ -f "$BEST_PATCH" ]; then
  # Delta = lines in current patch that differ from best candidate's patch
  # Use diff on the applied file states, not on patch text
  # Simpler: extract file lists from both patches and diff only changed files
  diff -u "$BEST_PATCH" "$COMBINED_PATCH_PATH" > "$ITERATION_DELTA_PATH" 2>/dev/null || true
else
  # No best patch to compare against (shouldn't happen after pass 1)
  cp "$COMBINED_PATCH_PATH" "$ITERATION_DELTA_PATH" 2>/dev/null || true
fi
DELTA_SIZE=$(wc -c < "$ITERATION_DELTA_PATH" 2>/dev/null || echo 0)
FULL_SIZE=$(wc -c < "$COMBINED_PATCH_PATH" 2>/dev/null || echo 0)
echo "Delta: $DELTA_SIZE bytes, Full: $FULL_SIZE bytes"

if [ "$DELTA_SIZE" -eq 0 ]; then
  echo "Delta empty - marking as non-improving"
  NO_IMPROVE_COUNT=$((NO_IMPROVE_COUNT + 1))
  CURRENT_ITERATION=$ITER_NUM
  continue
fi

if [ "$FULL_SIZE" -gt 0 ] && [ $((DELTA_SIZE * 100 / FULL_SIZE)) -gt 80 ]; then
  echo "Delta >80% of full patch - full-diff-only review for this iteration"
  reset_canonical_active_artifact "iteration_delta.patch"
fi
```

**Re-run the full audit subpipeline:**

Re-run Steps 2.4 (scope gate), 2.4.5 (policy compliance if applicable), 2.4.6 (scope existence gate), 2.5 (boundary verification), 2.6 (transition verification), 3.0.5 (repo-contract invariants), 3.1 (mechanic), 3.1.3 (policy scanner), 3.1.5 (holdout validation), 3.2-3.3.5 (reviews — risk-proportional), and 3.5 (synthesizer).

Pass `currentIteration` to the synthesizer prompt:

```
The canonical artifact root for this synthesis is `.signum/contracts/<activeContractId>/`.
Read `mechanic_report.json`, `reviews/claude.json`, `reviews/codex.json`, `reviews/gemini.json`, `holdout_report.json`, `execute_log.json`, and `audit_iteration_log.json` from that canonical artifact root.
Current iteration: <N>.
Apply deterministic synthesis rules, compute confidence and iteration scores, and write `audit_summary.json` to that same canonical artifact root.
```

**After synthesizer, store iteration artifacts and update tracking:**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
ITER_DIR="${ARTIFACT_ROOT}iterations/$(printf '%02d' $ITER_NUM)"
ITER_REVIEWS_DIR="${ITER_DIR}/reviews"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
ITERATION_DELTA_PATH="${ARTIFACT_ROOT}iteration_delta.patch"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
REPAIR_BRIEF_PATH="${ARTIFACT_ROOT}repair_brief.json"
AUDIT_ITERATION_LOG_PATH="${ARTIFACT_ROOT}audit_iteration_log.json"
mkdir -p "$ITER_REVIEWS_DIR"
cp "$COMBINED_PATCH_PATH" "$ITER_DIR/"
cp "$ITERATION_DELTA_PATH" "$ITER_DIR/" 2>/dev/null || true
cp "$MECHANIC_REPORT_PATH" "$ITER_DIR/"
cp "$HOLDOUT_REPORT_PATH" "$ITER_DIR/" 2>/dev/null || true
cp "$EXECUTE_LOG_PATH" "$ITER_DIR/" 2>/dev/null || true
cp "$REVIEWS_DIR/"*.json "$ITER_REVIEWS_DIR/" 2>/dev/null || true
cp "$AUDIT_SUMMARY_PATH" "$ITER_DIR/"
cp "$REPAIR_BRIEF_PATH" "$ITER_DIR/"

# Read new score
NEW_SCORE=$(jq -r '.iterationScore // 0' "$AUDIT_SUMMARY_PATH")
NEW_DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")

# Extract deduplicated findings with fingerprints for cross-iteration comparison
NEW_FINDINGS=$(jq '[.reviews[].findings[]? | {fingerprint: .fingerprint, severity: .severity, category: .category, file: .file, line: .line}] | unique_by(.fingerprint // (.file + ":" + (.line | tostring) + ":" + .category))' "$AUDIT_SUMMARY_PATH")
NEW_FINDINGS_COUNT=$(jq '{
  critical: [.reviews[].findings[]? | select(.severity == "CRITICAL")] | length,
  major: [.reviews[].findings[]? | select(.severity == "MAJOR")] | length,
  minor: [.reviews[].findings[]? | select(.severity == "MINOR")] | length
}' "$AUDIT_SUMMARY_PATH")

# Update iteration log
MECH_REG=$(jq -r '.hasRegressions' "$MECHANIC_REPORT_PATH" 2>/dev/null || echo "false")
HOLDOUT_FAIL=$(jq '.failed // 0' "$HOLDOUT_REPORT_PATH" 2>/dev/null || echo 0)
jq --argjson score "$NEW_SCORE" --arg decision "$NEW_DECISION" --argjson pass "$ITER_NUM" --argjson findings "$NEW_FINDINGS" --argjson findingsCount "$NEW_FINDINGS_COUNT"   --arg mechReg "$MECH_REG" --argjson holdoutFail "$HOLDOUT_FAIL"   '. + [{"pass": $pass, "score": $score, "decision": $decision, "findingsCount": $findingsCount, "canonicalFindings": $findings, "mechanicRegressions": ($mechReg == "true"), "holdoutFailures": $holdoutFail}]'   "$AUDIT_ITERATION_LOG_PATH" > "${AUDIT_ITERATION_LOG_PATH}.tmp"   && mv "${AUDIT_ITERATION_LOG_PATH}.tmp" "$AUDIT_ITERATION_LOG_PATH"

# Update best tracking
if [ "$NEW_SCORE" -gt "$BEST_SCORE" ] || [ "$NEW_SCORE" -eq "$BEST_SCORE" -a "$ITER_NUM" -le "$BEST_ITERATION" ]; then
  BEST_SCORE=$NEW_SCORE
  BEST_ITERATION=$ITER_NUM
  NO_IMPROVE_COUNT=0
  echo "New best: iteration $BEST_ITERATION (score $BEST_SCORE)"
else
  NO_IMPROVE_COUNT=$((NO_IMPROVE_COUNT + 1))
  echo "No improvement ($NO_IMPROVE_COUNT consecutive). Best remains iteration $BEST_ITERATION (score $BEST_SCORE)"
fi

CURRENT_ITERATION=$ITER_NUM
AUDIT_DECISION=$NEW_DECISION
ITERATION_SCORE=$NEW_SCORE

echo "Iteration $ITER_NUM: decision=$NEW_DECISION score=$NEW_SCORE best=$BEST_ITERATION"
```

**Repeat** from "Check entry conditions" until loop exits.

#### Step 3.6.3: Finalize iterative AUDIT

After loop exits, ensure the best candidate is active:

```bash
# CURRENT_ITERATION tracks the loop counter (including skipped iterations).
# The log length tracks actual completed iterations with audit results.
# ITERATIONS_USED is set to CURRENT_ITERATION for reporting the loop count;
# PACK uses the log's .pass field for data lookups, so sparse logs are handled correctly.
ITERATIONS_USED=$CURRENT_ITERATION

RESTORE_FAILED=false
if [ "$BEST_ITERATION" -ne "$CURRENT_ITERATION" ]; then
echo "Restoring best candidate from iteration $BEST_ITERATION"
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
ITERATION_DELTA_PATH="${ARTIFACT_ROOT}iteration_delta.patch"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
# Rollback using stored patch: revert only files listed in current iteration's combined.patch
BASE=$(jq -r '.base_commit' "$EXECUTION_CONTEXT_PATH")
PATCH_FILES=$(grep '^diff --git' "$COMBINED_PATCH_PATH" | sed 's|^diff --git a/||; s| b/.*||' | sort -u)
for f in $PATCH_FILES; do
  git checkout "$BASE" -- "$f" 2>/dev/null || rm -f "$f" 2>/dev/null || true
done
# Always sync audit artifacts from best iteration so PACK reads consistent data
BEST_DIR="${ARTIFACT_ROOT}iterations/$(printf '%02d' $BEST_ITERATION)"
cp "${BEST_DIR}/combined.patch" "$COMBINED_PATCH_PATH"
cp "${BEST_DIR}/iteration_delta.patch" "$ITERATION_DELTA_PATH" 2>/dev/null || reset_canonical_active_artifact "iteration_delta.patch"
cp "${BEST_DIR}/mechanic_report.json" "$MECHANIC_REPORT_PATH"
cp "${BEST_DIR}/holdout_report.json" "$HOLDOUT_REPORT_PATH" 2>/dev/null || true
cp "${BEST_DIR}/execute_log.json" "$EXECUTE_LOG_PATH" 2>/dev/null || true
rm -f "$REVIEWS_DIR/"*.json
cp "${BEST_DIR}/reviews/"*.json "$REVIEWS_DIR/" 2>/dev/null || true
cp "${BEST_DIR}/audit_summary.json" "$AUDIT_SUMMARY_PATH"

if ! git apply "${ARTIFACT_ROOT}iterations/$(printf '%02d' $BEST_ITERATION)/combined.patch"; then
    echo "ERROR: Failed to apply best candidate patch - forcing HUMAN_REVIEW"
    RESTORE_FAILED=true
    FINAL_DECISION="HUMAN_REVIEW"
    # Override decision in the already-synced audit_summary
    jq '.decision = "HUMAN_REVIEW" | .terminalReason = "final restore of best candidate patch failed"'       "$AUDIT_SUMMARY_PATH" > "${AUDIT_SUMMARY_PATH}.tmp"       && mv "${AUDIT_SUMMARY_PATH}.tmp" "$AUDIT_SUMMARY_PATH"
  fi
fi

# Determine terminal decision from best candidate
if [ "$RESTORE_FAILED" != "true" ]; then
  FINAL_DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
fi
EARLY_STOP=$( [ "$NO_IMPROVE_COUNT" -ge 2 ] && echo "true" || echo "false" )
EARLY_STOP_REASON=""
[ "$EARLY_STOP" = "true" ] && EARLY_STOP_REASON="no improvement for 2 consecutive iterations"
[ "$CURRENT_ITERATION" -ge "$MAX_ITERATIONS" ] && EARLY_STOP="true" && EARLY_STOP_REASON="max iterations reached"

# Write iteration metadata unconditionally so PACK always has correct fields
jq --argjson iters_used "$ITERATIONS_USED"    --argjson iters_max "$MAX_ITERATIONS"    --argjson best "$BEST_ITERATION"    --arg early_stop "$EARLY_STOP"    --arg early_stop_reason "$EARLY_STOP_REASON"    '. + {
     iterationsUsed: $iters_used,
     iterationsMax: $iters_max,
     bestIteration: $best,
     earlyStop: ($early_stop == "true"),
     earlyStopReason: (if $early_stop_reason != "" then $early_stop_reason else null end)
   }' "$AUDIT_SUMMARY_PATH" > "${AUDIT_SUMMARY_PATH}.tmp"    && mv "${AUDIT_SUMMARY_PATH}.tmp" "$AUDIT_SUMMARY_PATH"

if [ "$RESTORE_FAILED" != "true" ]; then
  # Terminal override based on remaining findings in best candidate
  REMAINING_CRITICAL=$(jq '[.reviews[].findings[]? | select(.severity == "CRITICAL")] | length' "$AUDIT_SUMMARY_PATH")
  REMAINING_MAJOR=$(jq '[.reviews[].findings[]? | select(.severity == "MAJOR")] | length' "$AUDIT_SUMMARY_PATH")
  REMAINING_MINOR=$(jq '[.reviews[].findings[]? | select(.severity == "MINOR")] | length' "$AUDIT_SUMMARY_PATH")

  BEST_MECH_REGRESSIONS=$(jq -r '.hasRegressions' "$MECHANIC_REPORT_PATH" 2>/dev/null || echo "false")
  BEST_HOLDOUT_FAILED=$(jq '.failed // 0' "$HOLDOUT_REPORT_PATH" 2>/dev/null || echo 0)

  if [ "$REMAINING_CRITICAL" -gt 0 ]; then
    FINAL_DECISION="AUTO_BLOCK"
    REMAINING_SEV="CRITICAL"
    TERMINAL_REASON="$REMAINING_MAJOR MAJOR + $REMAINING_CRITICAL CRITICAL findings persist after $ITERATIONS_USED iterations"
  elif [ "$REMAINING_MAJOR" -gt 0 ]; then
    FINAL_DECISION="HUMAN_REVIEW"
    REMAINING_SEV="MAJOR"
    TERMINAL_REASON="$REMAINING_MAJOR MAJOR + $REMAINING_CRITICAL CRITICAL findings persist after $ITERATIONS_USED iterations"
  elif [ "$BEST_MECH_REGRESSIONS" = "true" ] || [ "$BEST_HOLDOUT_FAILED" -gt 0 ]; then
    FINAL_DECISION="HUMAN_REVIEW"
    REMAINING_SEV="MAJOR"
    TERMINAL_REASON="mechanic regressions and/or holdout failures persist (mapped to MAJOR)"
  elif [ "$REMAINING_MINOR" -gt 0 ]; then
    FINAL_DECISION="AUTO_OK"
    REMAINING_SEV="MINOR"
    TERMINAL_REASON=""
  else
    FINAL_DECISION="AUTO_OK"
    REMAINING_SEV="none"
    TERMINAL_REASON=""
  fi

  # Update audit_summary with decision metadata
  jq --arg remaining_sev "$REMAINING_SEV"      --arg final_decision "$FINAL_DECISION"      --arg terminal_reason "$TERMINAL_REASON"      '. + {
       decision: $final_decision,
       terminalReason: (if $final_decision != "AUTO_OK" then $terminal_reason else null end),
       remainingSeverity: $remaining_sev
     }' "$AUDIT_SUMMARY_PATH" > "${AUDIT_SUMMARY_PATH}.tmp"      && mv "${AUDIT_SUMMARY_PATH}.tmp" "$AUDIT_SUMMARY_PATH"
fi

echo "=== ITERATIVE AUDIT COMPLETE ==="
echo "Iterations: $ITERATIONS_USED/$MAX_ITERATIONS (best: $BEST_ITERATION)"
echo "Early stop: $EARLY_STOP ${EARLY_STOP_REASON:+($EARLY_STOP_REASON)}"
echo "Final decision: $FINAL_DECISION (remaining: $REMAINING_SEV)"
```

Display the final audit summary (same display as after Step 3.5).

Proceed to Phase 4: PACK.

---

## Phase 4: PACK

**Goal:** Bundle all artifacts into a self-contained, verifiable proof package (schema v4.8) with embedded artifact contents.

### Step 4.0: Transition contract status to completed

Transition the contract status from `active` to `completed` and record the `completedAt` timestamp:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_TMP_PATH="${CONTRACT_PATH%.json}-tmp.json"
COMPLETED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg ts "$COMPLETED_TS" \
  '.status = "completed" | .timestamps.completedAt = $ts' \
  "$CONTRACT_PATH" > "$CONTRACT_TMP_PATH" && \
  mv "$CONTRACT_TMP_PATH" "$CONTRACT_PATH"
echo "Contract status: active → completed at $COMPLETED_TS"
```

### Step 4.1: Collect metadata and build proofpack

Use the Bash tool:

```bash
# Cross-platform sha256 helper
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  echo "ERROR: no sha256 tool found"; exit 1
fi

hash_file() {
  local f="$1"
  [ -f "$f" ] || { echo "missing"; return; }
  $HASH_CMD "$f" | awk '{print $1}'
}

file_size() {
  local f="$1"
  [ -f "$f" ] || { echo "0"; return; }
  wc -c < "$f" | tr -d ' '
}

source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
BASELINE_PATH="${ARTIFACT_ROOT}baseline.json"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
POLICY_SCAN_PATH="${ARTIFACT_ROOT}policy_scan.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
APPROVAL_PATH="${ARTIFACT_ROOT}approval.json"
PROOFPACK_PATH="${ARTIFACT_ROOT}proofpack.json"
ANTI_ENTROPY_PATH="${ARTIFACT_ROOT}anti_entropy_report.json"
CONTRACT_HASH_PATH="${ARTIFACT_ROOT}contract-hash.txt"
EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
AUDIT_ITERATION_LOG_PATH="${ARTIFACT_ROOT}audit_iteration_log.json"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
RECEIPTS_EXEC_PATH="${ARTIFACT_ROOT}receipts/execute.json"

# Metadata
DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
GOAL=$(jq -r '.goal' "$CONTRACT_PATH")
RISK=$(jq -r '.riskLevel' "$CONTRACT_PATH")
ATTEMPTS=$(jq -r '.totalAttempts' "$EXECUTE_LOG_PATH" 2>/dev/null || echo "unknown")
MECHANIC=$(jq -r '.mechanic' "$AUDIT_SUMMARY_PATH")
CONFIDENCE=$(jq -r '.confidence.overall // 0' "$AUDIT_SUMMARY_PATH")
RUN_DATE=$(date +%Y-%m-%dT%H:%M:%SZ)
RUN_RANDOM=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
RUN_ID="signum-$(date +%Y-%m-%d)-${RUN_RANDOM}"

# Audit chain
CONTRACT_HASH=$(grep 'contract_sha256:' "$CONTRACT_HASH_PATH" 2>/dev/null | awk '{print $2}' || echo "unavailable")
APPROVED_AT=$(grep 'approved_at:' "$CONTRACT_HASH_PATH" 2>/dev/null | awk '{print $2}' || echo "unavailable")
BASE_COMMIT=$(jq -r '.base_commit // "unavailable"' "$EXECUTION_CONTEXT_PATH" 2>/dev/null || echo "unavailable")

# Contract redaction: strip holdoutScenarios, save to temp file
REDACTED_CONTRACT=$(mktemp /tmp/signum-contract-redacted.XXXXXX.json)
python3 - "$CONTRACT_PATH" <<'PY' > "$REDACTED_CONTRACT"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
data.pop('holdoutScenarios', None)
json.dump(data, sys.stdout)
PY

CONTRACT_SHA256=$(hash_file "$REDACTED_CONTRACT")
CONTRACT_FULL_SHA256=$(hash_file "$CONTRACT_PATH")

# Envelope builder: embeds file content if <=102400 bytes, else omits
# JSON files (.json) are embedded as objects, text files as strings
build_envelope() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo '{"content":null,"sha256":null,"sizeBytes":0,"status":"error","omitReason":"file not found"}'
    return
  fi
  local sha
  sha=$(hash_file "$path")
  local size
  size=$(file_size "$path")
  if [ "$size" -le 102400 ]; then
    local content
    if [[ "$path" == *.json ]]; then
      content=$(cat "$path")
    else
      content=$(jq -Rs . < "$path")
    fi
    printf '{"content":%s,"sha256":"%s","sizeBytes":%s,"status":"present"}' \
      "$content" "$sha" "$size"
  else
    printf '{"content":null,"sha256":"%s","sizeBytes":%s,"status":"omitted","omitReason":"size exceeds 100 KiB"}' \
      "$sha" "$size"
  fi
}

# Contract envelope (special: has both sha256 of redacted and fullSha256 of original)
CONTRACT_SIZE=$(file_size "$REDACTED_CONTRACT")
if [ "$CONTRACT_SIZE" -le 102400 ]; then
  CONTRACT_CONTENT=$(cat "$REDACTED_CONTRACT")
  CONTRACT_ENV=$(printf '{"content":%s,"sha256":"%s","fullSha256":"%s","sizeBytes":%s,"status":"present"}' \
    "$CONTRACT_CONTENT" "$CONTRACT_SHA256" "$CONTRACT_FULL_SHA256" "$CONTRACT_SIZE")
else
  CONTRACT_ENV=$(printf '{"content":null,"sha256":"%s","fullSha256":"%s","sizeBytes":%s,"status":"omitted","omitReason":"size exceeds 100 KiB"}' \
    "$CONTRACT_SHA256" "$CONTRACT_FULL_SHA256" "$CONTRACT_SIZE")
fi

# Diff embedding
DIFF_ENV=$(build_envelope "$COMBINED_PATCH_PATH")

# Baseline envelope (optional artifact)
BASELINE_ENV=$(build_envelope "$BASELINE_PATH")

# Execute log envelope
EXECUTE_ENV=$(build_envelope "$EXECUTE_LOG_PATH")

# Mechanic and holdout envelopes
MECHANIC_ENV=$(build_envelope "$MECHANIC_REPORT_PATH")
HOLDOUT_ENV=$(build_envelope "$HOLDOUT_REPORT_PATH")

# Policy scan envelope — written to temp file so jq reads content directly,
# avoiding shell variable limits on large reports.
POLICY_SCAN_ENV_TMP=$(mktemp)
trap 'rm -f "$POLICY_SCAN_ENV_TMP"' EXIT
build_envelope "$POLICY_SCAN_PATH" > "$POLICY_SCAN_ENV_TMP"

# Audit summary envelope
AUDIT_ENV=$(build_envelope "$AUDIT_SUMMARY_PATH")

# Approval envelope
APPROVAL_ENV=$(build_envelope "$APPROVAL_PATH")

# Dynamic reviews: enumerate canonical reviews/*.json
REVIEWS_JSON='{'
first=1
for review_file in "$REVIEWS_DIR"/*.json; do
  [ -f "$review_file" ] || continue
  provider=$(basename "$review_file" .json)
  env_json=$(build_envelope "$review_file")
  if [ "$first" -eq 1 ]; then
    REVIEWS_JSON="${REVIEWS_JSON}\"${provider}\":${env_json}"
    first=0
  else
    REVIEWS_JSON="${REVIEWS_JSON},\"${provider}\":${env_json}"
  fi
done
REVIEWS_JSON="${REVIEWS_JSON}}"

# Detect contract source
if [ -n "${SIGNUM_CONTRACT_PATH:-}" ]; then
  CONTRACT_SOURCE="file"
else
  CONTRACT_SOURCE="interactive"
fi

# Detect CI context
CI_CONTEXT="null"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  CI_PROVIDER="github-actions"
  CI_RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  CI_PR_NUMBER=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null || true)
  CI_TRIGGER="${GITHUB_EVENT_NAME:-unknown}"
  CI_CONTEXT=$(jq -n \
    --arg provider "$CI_PROVIDER" \
    --arg runUrl "$CI_RUN_URL" \
    --arg trigger "$CI_TRIGGER" \
    '{provider: $provider, runUrl: $runUrl, triggerEvent: $trigger}')
  [ -n "$CI_PR_NUMBER" ] && CI_CONTEXT=$(echo "$CI_CONTEXT" | jq --argjson pr "$CI_PR_NUMBER" '. + {prNumber: $pr}')
fi

# Baseline comparison: find previous proofpack if exists
BASELINE_COMP="null"
PREV_PROOFPACK=$(ls -t .signum/contracts/*/proofpack.json 2>/dev/null | head -1 || true)
if [ -n "$PREV_PROOFPACK" ] && [ -f "$PREV_PROOFPACK" ]; then
  PREV_RUN_ID=$(jq -r '.runId // empty' "$PREV_PROOFPACK" 2>/dev/null || true)
  PREV_DECISION=$(jq -r '.decision // empty' "$PREV_PROOFPACK" 2>/dev/null || true)
  PREV_CONFIDENCE=$(jq -r '.confidence.overall // 0' "$PREV_PROOFPACK" 2>/dev/null || echo 0)
  CONF_DELTA=$(echo "$CONFIDENCE - $PREV_CONFIDENCE" | bc 2>/dev/null || echo 0)
  if [ -n "$PREV_RUN_ID" ]; then
    BASELINE_COMP=$(jq -n \
      --arg prevId "$PREV_RUN_ID" \
      --arg prevDec "$PREV_DECISION" \
      --argjson prevConf "$PREV_CONFIDENCE" \
      --argjson delta "$CONF_DELTA" \
      '{previousRunId: $prevId, previousDecision: $prevDec, previousConfidence: $prevConf, confidenceDelta: $delta}')
  fi
fi

# Extract contractId for lineage
PACK_CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")

# Read iteration metadata for iterativeAudit section
ITERATIONS_USED_PACK=$(jq -r '.iterationsUsed // 1' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo 1)
BEST_ITERATION_PACK=$(jq -r '.bestIteration // 1' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo 1)
ITERATIVE_AUDIT_JSON="null"
if [ "$ITERATIONS_USED_PACK" -gt 1 ] && [ -f "$AUDIT_ITERATION_LOG_PATH" ]; then
  # Read audit_summary metadata fields required by iterativeAudit schema
  PACK_ITERS_MAX=$(jq -r '.iterationsMax // 20' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo 20)
  PACK_EARLY_STOP=$(jq -r '.earlyStop // false' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo false)
  PACK_EARLY_STOP_REASON=$(jq -r '.earlyStopReason // ""' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "")
  PACK_TERMINAL_REASON=$(jq -r '.terminalReason // ""' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "")
  PACK_REMAINING_SEV=$(jq -r '.remainingSeverity // "none"' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "none")
  # Build resolvedFindings: findings present in pass 1 but absent in best pass (by fingerprint)
  # Use .pass field lookup instead of array index to handle sparse logs from skipped iterations
  PACK_RESOLVED=$(jq -n \
    --argjson log "$(cat "$AUDIT_ITERATION_LOG_PATH")" \
    --argjson best "$BEST_ITERATION_PACK" \
    '($log[0].canonicalFindings // []) as $first |
     (($log[] | select(.pass == $best)).canonicalFindings // []) as $last |
     ($last | map(.fingerprint // (.file + ":" + (.line|tostring) + ":" + .category))) as $lastFps |
     [$first[] | select((.fingerprint // (.file + ":" + (.line|tostring) + ":" + .category)) as $fp | $lastFps | index($fp) | not)]')
  # Build remainingFindings: findings present in the best pass
  # Use .pass field lookup instead of array index to handle sparse logs from skipped iterations
  PACK_REMAINING=$(jq --argjson best "$BEST_ITERATION_PACK" '(.[].pass as $p | select($p == $best) | .canonicalFindings) // []' "$AUDIT_ITERATION_LOG_PATH" 2>/dev/null || echo "[]")
  ITERATIVE_AUDIT_JSON=$(jq -n \
    --argjson iters_used "$ITERATIONS_USED_PACK" \
    --argjson iters_max "$PACK_ITERS_MAX" \
    --argjson best "$BEST_ITERATION_PACK" \
    --argjson early_stop "$PACK_EARLY_STOP" \
    --arg early_stop_reason "$PACK_EARLY_STOP_REASON" \
    --arg terminal_reason "$PACK_TERMINAL_REASON" \
    --arg remaining_sev "$PACK_REMAINING_SEV" \
    --argjson resolved "$PACK_RESOLVED" \
    --argjson remaining "$PACK_REMAINING" \
    --argjson log "$(cat "$AUDIT_ITERATION_LOG_PATH")" \
    '{iterationsUsed: $iters_used, iterationsMax: $iters_max, bestIteration: $best,
      earlyStop: $early_stop, earlyStopReason: $early_stop_reason,
      terminalReason: $terminal_reason, remainingSeverity: $remaining_sev,
      resolvedFindings: $resolved, remainingFindings: $remaining,
      auditIterations: $log}')
fi

# Receipt metadata (specpunk receipt v1 compatible fields)
PACK_STARTED_AT=$(jq -r '.started_at // empty' "$EXECUTE_LOG_PATH" 2>/dev/null || echo "$RUN_DATE")
PACK_DURATION_MS=$(jq -r '.duration_ms // 0' "$EXECUTE_LOG_PATH" 2>/dev/null || echo "0")
PACK_RISK_LEVEL=$(jq -r '.riskLevel // "low"' "$CONTRACT_PATH" 2>/dev/null || echo "low")
PACK_RELEASE_VERDICT=$(jq -r '.releaseVerdict // "HOLD"' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "HOLD")
PACK_AVAILABLE_REVIEWS=$(jq -r '.availableReviews // 0' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "0")

# Final assembly
jq -n \
  --arg schemaVersion "4.8" \
  --arg signumVersion "4.21.2" \
  --arg createdAt "$RUN_DATE" \
  --arg runId "$RUN_ID" \
  --arg contractId "$PACK_CONTRACT_ID" \
  --arg decision "$DECISION" \
  --arg summary "Goal: $GOAL | Risk: $RISK | Attempts: $ATTEMPTS | Mechanic: $MECHANIC | Confidence: ${CONFIDENCE}% | Decision: $DECISION" \
  --argjson confidence "$CONFIDENCE" \
  --arg contractHash "$CONTRACT_HASH" \
  --arg approvedAt "$APPROVED_AT" \
  --arg baseCommit "$BASE_COMMIT" \
  --argjson contractEnv "$CONTRACT_ENV" \
  --argjson diffEnv "$DIFF_ENV" \
  --argjson baselineEnv "$BASELINE_ENV" \
  --argjson executeEnv "$EXECUTE_ENV" \
  --argjson mechanicEnv "$MECHANIC_ENV" \
  --argjson holdoutEnv "$HOLDOUT_ENV" \
  --slurpfile policyScanEnv "$POLICY_SCAN_ENV_TMP" \
  --argjson auditEnv "$AUDIT_ENV" \
  --argjson approvalEnv "$APPROVAL_ENV" \
  --argjson reviewsEnv "$REVIEWS_JSON" \
  --arg contractSource "$CONTRACT_SOURCE" \
  --argjson ciContext "$CI_CONTEXT" \
  --argjson baselineComp "$BASELINE_COMP" \
  --argjson iterativeAuditJson "$ITERATIVE_AUDIT_JSON" \
  --arg startedAt "$PACK_STARTED_AT" \
  --argjson durationMs "$PACK_DURATION_MS" \
  --arg riskLevel "$PACK_RISK_LEVEL" \
  --arg releaseVerdict "$PACK_RELEASE_VERDICT" \
  --argjson availableReviews "$PACK_AVAILABLE_REVIEWS" \
  '{
    schemaVersion: $schemaVersion,
    signumVersion: $signumVersion,
    createdAt: $createdAt,
    runId: $runId,
    contractId: (if $contractId != "" then $contractId else null end),
    decision: $decision,
    releaseVerdict: $releaseVerdict,
    riskLevel: $riskLevel,
    summary: $summary,
    confidence: { overall: $confidence },
    timing: { startedAt: $startedAt, completedAt: $createdAt, durationMs: $durationMs },
    reviewCoverage: { availableReviews: $availableReviews },
    contractSource: $contractSource,
    auditChain: {
      contractSha256: $contractHash,
      approvedAt: $approvedAt,
      baseCommit: $baseCommit
    },
    contract: $contractEnv,
    diff: $diffEnv,
    baseline: $baselineEnv,
    executeLog: $executeEnv,
    approval: $approvalEnv,
    checks: {
      mechanic: $mechanicEnv,
      holdout: $holdoutEnv,
      policy_scan: $policyScanEnv[0],
      reviews: $reviewsEnv,
      auditSummary: $auditEnv
    }
  }
  | if $ciContext != null then . + {ciContext: $ciContext} else . end
  | if $baselineComp != null then . + {baselineComparison: $baselineComp} else . end
  | if $iterativeAuditJson != null then . + {iterativeAudit: $iterativeAuditJson} else . end
  ' > "$PROOFPACK_PATH"

# Removal evidence (v4.7): if contract has removals or cleanupObligations, build evidence
HAS_REMOVALS=$(jq 'if (.removals // [] | length) > 0 then "yes" else "no" end' "$CONTRACT_PATH")
HAS_OBLIGATIONS=$(jq 'if (.cleanupObligations // [] | length) > 0 then "yes" else "no" end' "$CONTRACT_PATH")
if [ "$HAS_REMOVALS" = '"yes"' ] || [ "$HAS_OBLIGATIONS" = '"yes"' ]; then
  REMOVAL_EV=$(python3 - "$CONTRACT_PATH" <<'PY'
import json
import os
import sys

contract = json.load(open(sys.argv[1]))
evidence = {'removals': [], 'obligations': []}
for rm in contract.get('removals', []):
    exists = os.path.exists(rm['path'])
    evidence['removals'].append({
        'id': rm['id'], 'path': rm['path'], 'type': rm.get('type', 'file'),
        'removed': not exists, 'orphanReferences': 0,
        'modulesYamlUpdated': rm.get('modulesYamlTransition', 'none') != 'none'
    })
for co in contract.get('cleanupObligations', []):
    evidence['obligations'].append({
        'id': co['id'], 'action': co.get('action', ''),
        'fulfilled': True, 'blocking': co.get('blocking', True)
    })
print(json.dumps(evidence))
PY
)
  jq --argjson re "$REMOVAL_EV" '. + {removalEvidence: $re}' \
    "$PROOFPACK_PATH" > "${PROOFPACK_PATH%.json}-tmp.json" \
    && mv "${PROOFPACK_PATH%.json}-tmp.json" "$PROOFPACK_PATH"
fi

# Cleanup temp files
rm -f "$REDACTED_CONTRACT"

# Append to proofpack index (hash-linked chain)
if [ -f lib/proofpack-index.sh ]; then
  source lib/proofpack-index.sh
  proofpack_index_append "$PROOFPACK_PATH" && echo "Proofpack indexed (chain hash linked)" || true
fi

# Advisory anti-entropy artifact (non-blocking, report-only)
if [ -f lib/pack-anti-entropy.sh ]; then
  bash lib/pack-anti-entropy.sh \
    --project-root . \
    --contract "$CONTRACT_PATH" \
    --proofpack "$PROOFPACK_PATH" \
    --output "$ANTI_ENTROPY_PATH" || true
fi

echo "Proofpack written: $RUN_ID (schema v4.8)"
```

### Step 4.2: Update contract status

Use the Bash tool to transition the contract to `completed`:

```bash
if [ -f lib/contract-dir.sh ]; then
  source lib/contract-dir.sh
  ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
  CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
  EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
  RECEIPTS_EXEC_PATH="${ARTIFACT_ROOT}receipts/execute.json"
  CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")
  if [ -n "$CONTRACT_ID" ]; then
    update_contract_status "$CONTRACT_ID" "completed"
    RUN_ID=$(jq -r '.run_id // empty' "$EXECUTION_CONTEXT_PATH" 2>/dev/null || true)
    if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
      RUN_ID=$(jq -r '.run_id // empty' "$RECEIPTS_EXEC_PATH" 2>/dev/null || true)
    fi
    # Verify durable canonical artifacts for this completed contract.
    verify_canonical_contract_artifacts "$CONTRACT_ID" \
      "contract.json" \
      "proofpack.json" \
      "anti_entropy_report.json" \
      "audit_summary.json" \
      "approval.json" \
      "execution_context.json" \
      "receipts" \
      "snapshots"
    if [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ]; then
      verify_canonical_contract_artifacts "$CONTRACT_ID" "runs/${RUN_ID}"
    fi
    echo "Contract $CONTRACT_ID → completed"
  fi
fi
```

---
## Final Output

Display to the user:

Use the Bash tool to list all produced artifacts:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
PROOFPACK_PATH="${ARTIFACT_ROOT}proofpack.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
DIFF_PATH="${ARTIFACT_ROOT}combined.patch"
ANTI_ENTROPY_PATH="${ARTIFACT_ROOT}anti_entropy_report.json"

echo "=== Canonical artifact root ==="
echo "$ARTIFACT_ROOT"
echo ""
echo "=== Artifacts ==="
if [ -d "$ARTIFACT_ROOT" ]; then
  (
    cd "$ARTIFACT_ROOT" &&
    find . -maxdepth 2 -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort
  )
else
  echo "WARNING: artifact root not found"
fi
echo ""
echo "Decision:   $(jq -r .decision "$PROOFPACK_PATH")"
echo "Confidence: $(jq -r '.confidence.overall' "$PROOFPACK_PATH")%"
echo "Run ID:     $(jq -r .runId "$PROOFPACK_PATH")"
if [ -f "$ANTI_ENTROPY_PATH" ]; then
  echo "Anti-entropy: $(jq -r '.status + \" — \" + .summary' "$ANTI_ENTROPY_PATH" 2>/dev/null || echo 'unknown')"
fi
```

Then display the appropriate next steps based on the decision:

- **AUTO_OK**: "Changes are verified. Review `combined.patch` under the canonical artifact root shown above and commit when ready."
- **AUTO_BLOCK**: "Issues found. Review `audit_summary.json` under the canonical artifact root shown above and fix before committing."
- **HUMAN_REVIEW**: "Audit inconclusive. Review `audit_summary.json` under the canonical artifact root shown above, then either: (1) refine acceptance criteria and re-run `/signum`, or (2) manually verify the flagged findings."

### Step 4.5: Finalize run (artifact cleanup)

After displaying results, finalize the current run to prevent stale artifacts from confusing subsequent invocations.

**Decision-based behavior:**

- **AUTO_OK** → auto-finalize (archive + purge working set). Zero-friction success path.
- **HUMAN_REVIEW** → ask the user: "Pipeline complete (HUMAN_REVIEW). Artifacts remain under the canonical artifact root shown above. Options: (1) archive — save to .signum/archive/ and clean working set, (2) keep — leave all artifacts for review, (3) delete — remove working set entirely." Default if no answer: keep.
- **AUTO_BLOCK** → ask the user: "Pipeline blocked (AUTO_BLOCK). Options: (1) keep — leave artifacts under the canonical artifact root for debugging (default), (2) delete — remove the working set." Default if no answer: keep.

**Finalize flow (archive + purge):**

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")

finalize_run() {
  ARCHIVE_TMP=$(mktemp -d .signum/archive-tmp.XXXXXX)
  archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_TMP"

  if [ ! -f "$ARCHIVE_TMP/contract.json" ] || [ ! -f "$ARCHIVE_TMP/proofpack.json" ]; then
    echo "ERROR: archive incomplete — keeping working set intact"
    rm -rf "$ARCHIVE_TMP"
    return 1
  fi

  if [ -n "$CONTRACT_ID" ]; then
    ARCHIVE_FINAL=".signum/archive/${CONTRACT_ID}"
    mkdir -p "$ARCHIVE_FINAL"
    cp -R "$ARCHIVE_TMP"/. "$ARCHIVE_FINAL"/
  fi
  rm -rf "$ARCHIVE_TMP"

  source lib/session-manager.sh 2>/dev/null || true
  if type session_append &>/dev/null; then
    GOAL=$(jq -r '.goal // "unknown"' "$CONTRACT_PATH" 2>/dev/null | head -c 120)
    if [ "$DECISION" = "AUTO_OK" ]; then
      session_append "success" "AUTO_OK: $GOAL"
    elif [ "$DECISION" = "AUTO_BLOCK" ]; then
      REASON=$(jq -r '.reasoning // "unknown"' "$AUDIT_SUMMARY_PATH" 2>/dev/null | head -c 120)
      session_append "failure" "AUTO_BLOCK ($REASON): $GOAL"
    elif [ "$DECISION" = "HUMAN_REVIEW" ]; then
      session_append "model_disagreement" "HUMAN_REVIEW: $GOAL"
    fi
    if jq -e '.reviews | to_entries[] | select(.value.findings[]? | .category == "scope")' "$AUDIT_SUMMARY_PATH" &>/dev/null; then
      session_append "scope_violation" "Scope issue detected in: $GOAL" 8
    fi
  fi

  clear_active_contract >/dev/null 2>&1 || true
  purge_root_working_set_views >/dev/null 2>&1 || true

  echo "Run finalized: archived to .signum/archive/$CONTRACT_ID/, working set cleaned"
}

if [ "$DECISION" = "AUTO_OK" ]; then
  finalize_run
fi
```

If `DECISION` is `AUTO_OK`, finalize runs automatically. For `HUMAN_REVIEW` or `AUTO_BLOCK`, wait for the user's choice (prompted above), then run one of the following bash blocks (each is self-contained — variables must be re-resolved since each Bash tool call gets a fresh shell):

**If user chooses "archive":**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")
ARCHIVE_TMP=$(mktemp -d .signum/archive-tmp.XXXXXX)
archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_TMP"
if [ ! -f "$ARCHIVE_TMP/contract.json" ] || [ ! -f "$ARCHIVE_TMP/proofpack.json" ]; then
  echo "ERROR: archive incomplete — keeping working set intact"
  rm -rf "$ARCHIVE_TMP"; exit 1
fi
if [ -n "$CONTRACT_ID" ]; then
  mkdir -p ".signum/archive/${CONTRACT_ID}"
  cp -R "$ARCHIVE_TMP"/. ".signum/archive/${CONTRACT_ID}/"
fi
rm -rf "$ARCHIVE_TMP"
clear_active_contract >/dev/null 2>&1 || true
purge_root_working_set_views >/dev/null 2>&1 || true
echo "Run finalized: archived to .signum/archive/$CONTRACT_ID/, working set cleaned"
```

**If user chooses "delete":**

```bash
source lib/contract-dir.sh 2>/dev/null || true
clear_active_contract >/dev/null 2>&1 || true
purge_root_working_set_views >/dev/null 2>&1 || true
echo "Working set deleted (no archive)"
```

**If user chooses "keep" or does not respond:** do nothing.

---

## Error Handling

- If any phase fails catastrophically (agent error, required file missing after agent run), **STOP** immediately and report: what phase failed, what file is missing, and what the user should do next.
- Mechanic check failures continue to audit — they influence the decision but do not block Phase 3.
- If codex or gemini times out (`exit 124`) or returns a non-zero exit code, mark as unavailable and continue.
- **Never silently swallow errors.** All bash exit codes must be checked. If jq fails to parse a file, report it explicitly.
- If the synthesizer produces an invalid audit_summary.json, stop Phase 4 and report the problem.
