---
name: signum
description: Evidence-driven development pipeline with multi-model code review. Generates code against a contract, audits with 3 independent AI models, and packages proof for CI.
arguments:
  - name: task
    description: What to build or fix (feature description)
    required: true
---

# Signum v4.1: Evidence-Driven Development Pipeline

You are the Signum orchestrator. You drive a 4-phase evidence-driven pipeline:

```
CONTRACT → EXECUTE → AUDIT → PACK
```

The user's task: `$ARGUMENTS`

## Explain Mode

If the user's task is exactly `explain` (case-insensitive), do NOT run the pipeline. Instead, output this JSON and stop:

```json
{
  "name": "Signum",
  "version": "4.1.0",
  "pipeline": ["CONTRACT", "EXECUTE", "AUDIT", "PACK"],
  "phases": {
    "CONTRACT": {
      "description": "Transform request into verifiable JSON contract",
      "steps": ["contractor agent", "spec quality gate (7 dimensions)", "prose checks", "multi-model spec validation", "clover reconstruction test", "human approval"],
      "duration": "~30s",
      "approvals": 1
    },
    "EXECUTE": {
      "description": "Implement code against contract with repair loop",
      "steps": ["baseline capture", "engineer agent (max 3 attempts)", "scope gate", "policy compliance"],
      "duration": "1-5 min",
      "approvals": 0
    },
    "AUDIT": {
      "description": "Multi-angle verification with regression detection",
      "steps": ["mechanic (lint/typecheck/tests vs baseline)", "holdout validation", "Claude semantic review", "Codex security review", "Gemini performance review", "synthesizer consensus"],
      "duration": "1-3 min (risk-proportional)",
      "approvals": 0
    },
    "PACK": {
      "description": "Bundle all artifacts into signed proofpack",
      "steps": ["collect metadata", "embed artifacts with SHA-256 envelopes", "write proofpack.json"],
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
  "artifacts": [".signum/contract.json", ".signum/combined.patch", ".signum/proofpack.json", ".signum/audit_summary.json"]
}
```

Do not proceed to Setup or any phase.

## Archive Mode

If the user's task starts with `archive` (case-insensitive), do NOT run the pipeline. Instead, archive a completed contract.

If a contract ID is provided (e.g., `archive sig-20260314-a1b2`), extract it from the user input. Otherwise, the active contract will be used.

Before running the Bash tool, parse the contract ID from the user's arguments (everything after `archive `). Pass it as `CONTRACT_ID_FROM_ARGS` environment variable. Use the Bash tool:

```bash
source lib/contract-dir.sh

# CONTRACT_ID_FROM_ARGS is set by the orchestrator from user input (may be empty)
CONTRACT_ID="${CONTRACT_ID_FROM_ARGS:-$(get_active_contract)}"
if [ -z "$CONTRACT_ID" ]; then
  echo "ERROR: No contract ID provided and no active contract found" >&2
  exit 1
fi

DIR=$(contract_dir "$CONTRACT_ID")
if [ ! -d "$DIR" ]; then
  echo "ERROR: Contract directory not found: $DIR" >&2
  exit 1
fi

# Create archive directory
ARCHIVE_DIR=".signum/archive/${CONTRACT_ID}/"
mkdir -p "$ARCHIVE_DIR"

# Copy essential artifacts (contract + proofpack)
cp "${DIR}contract.json" "$ARCHIVE_DIR" 2>/dev/null || true
cp "${DIR}proofpack.json" "$ARCHIVE_DIR" 2>/dev/null || true
cp "${DIR}approval.json" "$ARCHIVE_DIR" 2>/dev/null || true

# Copy audit summary if present
cp "${DIR}audit_summary.json" "$ARCHIVE_DIR" 2>/dev/null || true

# Purge intermediate artifacts (reviews, baseline, holdout, execute_log, prompts)
rm -rf "${DIR}reviews/" 2>/dev/null || true
rm -f "${DIR}baseline.json" "${DIR}execute_log.json" "${DIR}holdout_report.json" \
      "${DIR}mechanic_report.json" "${DIR}combined.patch" \
      "${DIR}contract-engineer.json" "${DIR}contract-policy.json" \
      "${DIR}policy_violations.json" "${DIR}spec_quality.json" \
      "${DIR}spec_validation.json" "${DIR}clover_report.json" \
      "${DIR}contract-hash.txt" "${DIR}execution_context.json" \
      "${DIR}review_prompt_codex.txt" "${DIR}review_prompt_gemini.txt" 2>/dev/null || true

# Update status in index.json
update_contract_status "$CONTRACT_ID" "archived"

# Log transition with timestamp
ARCHIVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg id "$CONTRACT_ID" --arg ts "$ARCHIVED_AT" \
  '.contracts = [.contracts[] |
    if .contractId == $id then . + {archivedAt: $ts} else . end]' \
  .signum/contracts/index.json > .signum/contracts/index.json.tmp \
  && mv .signum/contracts/index.json.tmp .signum/contracts/index.json

echo "Archived: $CONTRACT_ID → $ARCHIVE_DIR"
echo "Kept: contract.json, proofpack.json, approval.json, audit_summary.json"
echo "Purged: intermediates (reviews, baseline, patches, prompts)"
```

Do not proceed to Setup or any phase.

## Close Mode

If the user's task starts with `close` (case-insensitive), do NOT run the pipeline. Instead, mark a contract as closed (abandoned, no proofpack).

If a contract ID is provided (e.g., `close sig-20260314-a1b2`), extract it from user input. Otherwise, the active contract will be used.

Before running the Bash tool, parse the contract ID from the user's arguments (everything after `close `). Pass it as `CONTRACT_ID_FROM_ARGS` environment variable. Use the Bash tool:

```bash
source lib/contract-dir.sh

# CONTRACT_ID_FROM_ARGS is set by the orchestrator from user input (may be empty)
CONTRACT_ID="${CONTRACT_ID_FROM_ARGS:-$(get_active_contract)}"
if [ -z "$CONTRACT_ID" ]; then
  echo "ERROR: No contract ID provided and no active contract found" >&2
  exit 1
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

# Clear active contract if this was the active one
ACTIVE=$(get_active_contract)
if [ "$ACTIVE" = "$CONTRACT_ID" ]; then
  jq '.activeContractId = null' .signum/contracts/index.json > .signum/contracts/index.json.tmp \
    && mv .signum/contracts/index.json.tmp .signum/contracts/index.json
  echo "Cleared active contract (was $CONTRACT_ID)"
fi

echo "Closed: $CONTRACT_ID at $CLOSED_AT"
echo "No proofpack generated. Contract directory preserved for reference."
```

Do not proceed to Setup or any phase.

## Setup

Use the Bash tool to prepare the workspace:

```bash
mkdir -p .signum/reviews .signum/contracts
touch .gitignore
grep -q '^\.signum/$' .gitignore || echo '.signum/' >> .gitignore
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
echo "codex_model=${SIGNUM_CODEX_MODEL:-(cli default)} gemini_model=${SIGNUM_GEMINI_MODEL:-(cli default)}"
```

Save `SIGNUM_CODEX_MODEL` and `SIGNUM_GEMINI_MODEL` for use in all subsequent codex/gemini invocations.
If either is empty, do NOT pass `--model` — let the CLI use its built-in default.

Record `PROJECT_ROOT` as the current working directory (output of `pwd`).

Check for an existing contract:

```bash
test -f .signum/contract.json && echo "EXISTS" || echo "NONE"
```

If contract.json exists, ask the user: "A previous contract exists in .signum/contract.json. Resume from Phase 2, or restart from Phase 1 (discards existing contract)?"

Wait for the user's answer before continuing. If restart, delete the existing artifacts:

```bash
rm -f .signum/contract.json .signum/execute_log.json .signum/combined.patch \
       .signum/baseline.json .signum/mechanic_report.json \
       .signum/audit_summary.json .signum/proofpack.json \
       .signum/holdout_report.json \
       .signum/contract-engineer.json .signum/contract-policy.json \
       .signum/policy_violations.json \
       .signum/spec_quality.json .signum/spec_validation.json \
       .signum/repo_contract_baseline.json .signum/repo_contract_violations.json \
       .signum/contract-hash.txt .signum/execution_context.json \
       .signum/reviews/claude.json .signum/reviews/codex.json .signum/reviews/gemini.json \
       .signum/review_prompt_codex.txt .signum/review_prompt_gemini.txt \
       .signum/reviews/codex_raw.txt .signum/reviews/gemini_raw.txt \
       .signum/clover_report.json .signum/approval.json
```

---

## Phase 1: CONTRACT

**Goal:** Transform the user's request into a verifiable contract.

### Step 1.1: Launch Contractor

Use the Agent tool to launch the "contractor" agent with this prompt:

```
FEATURE_REQUEST: <the user's task from $ARGUMENTS>
PROJECT_ROOT: <output of pwd>

Scan the codebase, assess risk, and write .signum/contract.json.
```

### Step 1.2: Validate contract

Use the Bash tool to verify the contract was written and has required fields:

```bash
test -f .signum/contract.json || { echo "ERROR: contract.json not found"; exit 1; }
jq -e '.schemaVersion and .goal and .inScope and .acceptanceCriteria and .riskLevel' \
  .signum/contract.json > /dev/null && echo "VALID" || echo "INVALID"
```

If the file is missing or INVALID, stop and report: "Contractor agent failed to produce a valid contract.json. Check agent output for errors."

### Step 1.2.5: Initialize per-contract directory

After contractor creates contract.json, extract the contractId and set up an isolated directory for this contract's artifacts.

Use the Bash tool:

```bash
# Source the contract-dir module
source lib/contract-dir.sh

# Extract contractId from contract.json
CONTRACT_ID=$(jq -r '.contractId' .signum/contract.json)
if [ -z "$CONTRACT_ID" ] || [ "$CONTRACT_ID" = "null" ]; then
  echo "ERROR: contractId not found in contract.json"
  exit 1
fi
echo "contractId: $CONTRACT_ID"

# Create per-contract directory with reviews/ subdirectory
init_contract_dir "$CONTRACT_ID"

# Copy contract.json to per-contract directory (original stays in .signum/ as working copy)
CDIR=$(contract_dir "$CONTRACT_ID")
cp .signum/contract.json "${CDIR}contract.json"
echo "Archived contract.json to ${CDIR}contract.json"

# Register contract in index.json
register_contract "$CONTRACT_ID" "draft"
```

### Step 1.3: Check for open questions

Use the Bash tool:

```bash
# Check 1: requiredInputsProvided (contractor cannot resolve ambiguity from codebase alone)
REQ_OK=$(jq -r '.requiredInputsProvided // true' .signum/contract.json)
if [ "$REQ_OK" = "false" ]; then
  echo "HARD STOP: requiredInputsProvided=false"
  jq -r '"Contractor needs additional input:\n  - " + ((.openQuestions // []) | join("\n  - "))' .signum/contract.json
fi

# Check 2: open questions (ambiguities requiring user clarification)
jq -r 'if (.openQuestions | length) > 0 then "BLOCKED: " + (.openQuestions | join("\n  - ")) else "OK" end' \
  .signum/contract.json
```

If output contains `HARD STOP:` or starts with `BLOCKED:`, display the questions to the user and **STOP**. Do not proceed to Phase 2 until the user provides answers.

Do not proceed to Phase 2 until the user provides answers to every open question. When answers are received, re-launch the contractor agent with the original request plus the answers appended, and repeat Step 1.2–1.3.

### Step 1.3.5: Spec quality check

Use the Bash tool to score the contract on 7 dimensions. A score below 69 (grade D) means the contract is too vague for reliable autonomous execution.

```bash
GOAL=$(jq -r '.goal' .signum/contract.json)
AC_COUNT=$(jq '.acceptanceCriteria | length' .signum/contract.json)
AC_WITH_VERIFY=$(jq '[.acceptanceCriteria[] | select(.verify.type and .verify.value)] | length' .signum/contract.json)
INSCOPE_COUNT=$(jq '.inScope | length' .signum/contract.json)
HAS_OUTOFSCOPE=$(jq 'if (.outOfScope | length) > 0 then 1 else 0 end' .signum/contract.json)
HAS_ASSUMPTIONS=$(jq 'if (.assumptions | length) > 0 then 1 else 0 end' .signum/contract.json)
HAS_HOLDOUTS=$(jq 'if ((.holdoutScenarios // []) | length) > 0 then 1 else 0 end' .signum/contract.json)
REQ_OK=$(jq -r '.requiredInputsProvided // true' .signum/contract.json)
OPEN_Q=$(jq '(.openQuestions | length)' .signum/contract.json)

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
NEG_ACS=$(jq '[.acceptanceCriteria[] | select(.description | test("must not|should not|\\bnever\\b|\\bprevent|reject|fail|invalid"; "i"))] | length' .signum/contract.json)
[ "$NEG_ACS" -gt 0 ] && NEG_SCORE=$((NEG_SCORE + 10))

# Clarity (0-20): goal length + absence of vague phrases
GOAL_LEN=${#GOAL}
CLARITY=0
[ "$GOAL_LEN" -ge 20 ] && [ "$GOAL_LEN" -le 300 ] && CLARITY=$((CLARITY + 10))
VAGUE=$(echo "$GOAL" | grep -ci "works correctly\|as expected\|properly\|should work" 2>/dev/null || echo 0)
[ "$VAGUE" -eq 0 ] && CLARITY=$((CLARITY + 10))

# Boundary system (0-10): outOfScope + assumptions present
BOUNDARY=0
[ "$HAS_OUTOFSCOPE" -eq 1 ] && BOUNDARY=$((BOUNDARY + 5))
[ "$HAS_ASSUMPTIONS" -eq 1 ] && BOUNDARY=$((BOUNDARY + 5))

# NL Consistency (0-15): vague verb detection + terminology consistency + AC contradiction detection

# Sub-check 1: Vague verb detection (0-5)
# Synonym map for terminology consistency (endpoint/route, function/method, test/spec,
#   error/exception, config/configuration/settings, user/client, file/document)
ALL_AC_TEXT=$(jq -r '[.acceptanceCriteria[].description] | join(" ")' .signum/contract.json)
VAGUE_VERBS_PATTERN="handle|process|manage|support|ensure|implement|perform|utilize|leverage|facilitate"
VAGUE_VERBS_FOUND=$(echo "$ALL_AC_TEXT $GOAL" | grep -ciE "\b($VAGUE_VERBS_PATTERN)\b" 2>/dev/null || echo 0)
if [ "$VAGUE_VERBS_FOUND" -eq 0 ]; then VAGUE_VERB_PTS=5; else VAGUE_VERB_PTS=0; fi

# Sub-check 2: Terminology consistency (0-5)
# Check for SYNONYM pairs that indicate inconsistent terminology
# SYNONYM map: endpoint/route, function/method, test/spec, error/exception, config/configuration/settings, user/client, file/document
SYNONYM_INCONSISTENT=0
_check_synonyms() {
  local text="$1"
  local a="$2" b="$3"
  local has_a has_b
  has_a=$(echo "$text" | grep -ciw "$a" 2>/dev/null || echo 0)
  has_b=$(echo "$text" | grep -ciw "$b" 2>/dev/null || echo 0)
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
AC_TEXTS=$(jq -r '.acceptanceCriteria[].description' .signum/contract.json 2>/dev/null || echo "")
CONTRADICTION_FOUND=0
while IFS= read -r ac_line; do
  pos=$(echo "$ac_line" | grep -oi "must [a-z]*\|allow [a-z]*\|enable [a-z]*" 2>/dev/null | grep -vi "must not" | head -5)
  while IFS= read -r phrase; do
    [ -z "$phrase" ] && continue
    word=$(echo "$phrase" | awk '{print $2}')
    neg_count=$(echo "$AC_TEXTS" | grep -ci "must not $word\|prevent $word\|disallow $word\|disable $word" 2>/dev/null || echo 0)
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
  > .signum/spec_quality.json
```

#### Prose quality check (informational, non-blocking)

Use the Bash tool to run the prose quality gate on the contract. This check is **informational only** — the pipeline continues regardless of findings.

```bash
PROSE_REPORT=""
if [ -f lib/prose-check.sh ]; then
  PROSE_REPORT=$(lib/prose-check.sh .signum/contract.json 2>/dev/null || echo '{}')
  PROSE_TOTAL=$(echo "$PROSE_REPORT" | jq '.total_findings // 0')
  PROSE_PASS=$(echo "$PROSE_REPORT" | jq -r '.pass // "true"')
  echo "Prose quality: $PROSE_TOTAL finding(s), pass=$PROSE_PASS"

  # Merge prose_warnings into spec_quality.json (non-blocking)
  if [ -f .signum/spec_quality.json ]; then
    jq --argjson prose "$PROSE_REPORT" '. + {prose_warnings: $prose}' \
      .signum/spec_quality.json > .signum/spec_quality_tmp.json \
      && mv .signum/spec_quality_tmp.json .signum/spec_quality.json
  fi
fi
```

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
SPEC_CONTEXT=$(python3 -c "
import json
c = json.load(open('.signum/contract.json'))
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
")
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
codex exec --ephemeral -C "$PWD" -p fast $CODEX_MODEL_FLAG --output-last-message "$OUT" "$PROMPT" 2>"$ERR"
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

Write collected findings to `.signum/spec_validation.json`:

```bash
jq -n \
  --arg codex_out "$CODEX_SPEC_OUT" \
  --arg gemini_out "$GEMINI_SPEC_OUT" \
  --arg codex_avail "$CODEX_AVAIL" \
  --arg gemini_avail "$GEMINI_AVAIL" \
  '{
    codex: { available: ($codex_avail == "yes"), findings: $codex_out },
    gemini: { available: ($gemini_avail == "yes"), findings: $gemini_out }
  }' > .signum/spec_validation.json
echo "Spec validation written to .signum/spec_validation.json"
```

### Step 1.3.8: Clover reconstruction test

Verify that the acceptance criteria fully capture the goal's intent. Ask a model to reconstruct the goal from ONLY the ACs, then compare with the original.

Use the Agent tool to launch a general-purpose agent (model: sonnet) with this prompt:

```
You are given ONLY the acceptance criteria below. You have NOT seen the original goal.
Reconstruct what the goal/task likely was based solely on these ACs.

Acceptance criteria:
<ACs from .signum/contract.json — list each AC id + description, but do NOT include the goal>

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
ORIGINAL_GOAL=$(jq -r '.goal' .signum/contract.json)
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
    pass: ($confidence >= 0.7 and $gap_count <= 2)}' > .signum/clover_report.json

if [ "$(jq '.pass' .signum/clover_report.json)" = "false" ]; then
  echo "CLOVER WARNING: ACs may not fully capture the goal (confidence=$CONFIDENCE, gaps=$GAPS)"
  jq -r '.coverage_gaps[]' .signum/clover_report.json | sed 's/^/  - /'
  echo "Consider adding ACs to cover the gaps above."
else
  echo "Clover test: PASS (confidence=$CONFIDENCE)"
fi
```

Clover failure is informational — it does not block the pipeline. Display warnings in Step 1.4 if `pass` is false.

### Step 1.4: Display contract summary

Use the Bash tool to extract and display:

```bash
jq -r '"Goal: " + .goal,
       "Risk: " + .riskLevel,
       "In scope: " + (.inScope | join(", ")),
       "Acceptance criteria: " + (.acceptanceCriteria | length | tostring) + " defined",
       "Holdout scenarios: " + ((.holdoutScenarios // []) | length | tostring) + " defined"' \
  .signum/contract.json

QUALITY=$(jq -r '"Spec quality: " + (.total | tostring) + "/115 (grade " + .grade + ")"' \
  .signum/spec_quality.json 2>/dev/null || echo "Spec quality: not computed")
echo "$QUALITY"

# Show spec validation findings if available
if [ -f .signum/spec_validation.json ]; then
  CODEX_AVAIL=$(jq -r '.codex.available' .signum/spec_validation.json)
  GEMINI_AVAIL=$(jq -r '.gemini.available' .signum/spec_validation.json)
  if [ "$CODEX_AVAIL" = "true" ]; then
    echo ""
    echo "--- Codex spec review (ambiguities + assumptions) ---"
    jq -r '.codex.findings' .signum/spec_validation.json
  fi
  if [ "$GEMINI_AVAIL" = "true" ]; then
    echo ""
    echo "--- Gemini spec review (edge cases + failure modes) ---"
    jq -r '.gemini.findings' .signum/spec_validation.json
  fi
fi

# Show clover reconstruction test results if available
if [ -f .signum/clover_report.json ]; then
  CLOVER_PASS=$(jq -r '.pass' .signum/clover_report.json)
  CLOVER_CONF=$(jq -r '.confidence' .signum/clover_report.json)
  if [ "$CLOVER_PASS" = "true" ]; then
    echo "Clover test: PASS (confidence=$CLOVER_CONF)"
  else
    echo ""
    echo "--- Clover reconstruction WARNING ---"
    echo "ACs may not fully capture the goal (confidence=$CLOVER_CONF)"
    jq -r '.coverage_gaps[]' .signum/clover_report.json | sed 's/^/  - /'
  fi
fi
```

Also display any riskSignals if riskLevel is "high":

```bash
jq -r 'if .riskLevel == "high" then "Risk signals: " + (.riskSignals // [] | join(", ")) else empty end' \
  .signum/contract.json
```

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

If ALL items are answered "yes", write `.signum/approval.json`:

```bash
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
  }' > .signum/approval.json
echo "approval.json written at $APPROVAL_TS"
```

After writing approval.json, transition the contract status from `draft` to `active` and record the `activatedAt` timestamp:

```bash
ACTIVATED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg ts "$ACTIVATED_TS" \
  '.status = "active" | .timestamps.activatedAt = $ts' \
  .signum/contract.json > .signum/contract-tmp.json && \
  mv .signum/contract-tmp.json .signum/contract.json
echo "Contract status: draft → active at $ACTIVATED_TS"
```

### Step 1.4.5: Record approval timestamp (contract-hash.txt)

After the user confirms, anchor the approved contract with a SHA-256 hash and timestamp. This creates the root of the audit chain.

Use the Bash tool:

```bash
if command -v sha256sum >/dev/null 2>&1; then
  CONTRACT_HASH=$(sha256sum .signum/contract.json | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  CONTRACT_HASH=$(shasum -a 256 .signum/contract.json | awk '{print $1}')
else
  CONTRACT_HASH="unavailable"
fi

APPROVAL_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > .signum/contract-hash.txt <<EOF
contract_sha256: $CONTRACT_HASH
approved_at: $APPROVAL_TS
contract_file: .signum/contract.json
EOF

echo "Audit chain anchored: $CONTRACT_HASH at $APPROVAL_TS"
```

### Step 1.5: Prepare sanitized engineer contract

Use the Bash tool to create a contract stripped of holdout scenarios and holdout ACs (data-level isolation):

```bash
# Create engineer contract: remove holdouts + holdoutScenarios
jq '{
  schemaVersion, contractId, status, timestamps, goal, inScope, allowNewFilesUnder, outOfScope,
  acceptanceCriteria: [.acceptanceCriteria[] | select(.visibility != "holdout")],
  assumptions, openQuestions, riskLevel, riskSignals, requiredInputsProvided
} | with_entries(select(.value != null))' .signum/contract.json > .signum/contract-engineer.json

# Generate holdout manifest for committed spec
HOLDOUT_COUNT=$(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' .signum/contract.json)
if [ "$HOLDOUT_COUNT" -gt 0 ]; then
  HOLDOUT_HASH=$(jq -c '[.acceptanceCriteria[] | select(.visibility == "holdout")]' .signum/contract.json | shasum -a 256 | cut -c1-16)
  jq --argjson count "$HOLDOUT_COUNT" --arg hash "sha256:$HOLDOUT_HASH" \
    '. + {holdoutManifest: {count: $count, hash: $hash}}' .signum/contract-engineer.json > .signum/contract-engineer-tmp.json
  mv .signum/contract-engineer-tmp.json .signum/contract-engineer.json
fi

AC_VISIBLE=$(jq '[.acceptanceCriteria[] | select(.visibility != "holdout")] | length' .signum/contract.json)
echo "contract-engineer.json written ($AC_VISIBLE visible ACs, $HOLDOUT_COUNT holdouts redacted)"
```

After writing `contract-engineer.json`, validate holdout count against risk level:

```bash
RISK=$(jq -r '.riskLevel' .signum/contract.json)
HOLDOUT_COUNT=$(jq '([.acceptanceCriteria[] | select(.visibility == "holdout")] | length) + ((.holdoutScenarios // []) | length)' .signum/contract.json)

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
python3 -c "
import json
with open('.signum/contract.json') as f:
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
with open('.signum/contract-policy.json', 'w') as f:
    json.dump(policy, f, indent=2)
print(f'contract-policy.json written (risk={risk}, allowed_paths={len(in_scope)}, max_files={max_files})')
"
```

---

## Phase 2: EXECUTE

**Goal:** Implement code changes according to the contract.

### Step 2.0: Capture baseline (before any changes)

Use the Bash tool to record the current commit SHA (audit chain: this is where the Engineer starts from) and run project checks BEFORE the engineer touches anything:

```bash
# Record base commit for audit chain
BASE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
EXECUTE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "{\"base_commit\":\"$BASE_COMMIT\",\"started_at\":\"$EXECUTE_START\"}" > .signum/execution_context.json
echo "Execution context: base_commit=$BASE_COMMIT"

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
  '{ lint: $lint, typecheck: $type, tests: { exit_code: $test, failing: $failing } }' > .signum/baseline.json

echo "Baseline captured: lint=$BL_LINT_EXIT type=$BL_TYPE_EXIT test=$BL_TEST_EXIT"
```

If `repo-contract.json` exists in the project root, also capture invariant baseline:

```bash
if [ -f "repo-contract.json" ]; then
  python3 -c "
import json, subprocess
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
with open('.signum/repo_contract_baseline.json', 'w') as f:
    json.dump(results, f, indent=2)
total = len(results)
passed = sum(1 for v in results.values() if v['passed'])
print(f'Repo-contract baseline: {passed}/{total} invariants passing')
"
fi
```

### Step 2.1: Launch Engineer

Use the Agent tool to launch the "engineer" agent with this prompt:

```
Read .signum/contract-engineer.json and implement the required changes.
Read .signum/baseline.json for pre-existing check state.
Implement, run the repair loop (max 3 attempts), save artifacts.
Write .signum/combined.patch and .signum/execute_log.json.
```

### Step 2.2: Check result

Use the Bash tool:

```bash
test -f .signum/execute_log.json || { echo "ERROR: execute_log.json not found"; exit 1; }
STATUS=$(jq -r '.status' .signum/execute_log.json)
if [ "$STATUS" != "SUCCESS" ]; then
  echo "ERROR: Execute status is '$STATUS' (expected SUCCESS)"
  jq -r '"Attempt failures:",
         (.attempts[] | "  Attempt " + (.number | tostring) + ": " +
           (.checks | to_entries[] | select(.value.passed == false) |
             "  " + .key + " failed: " + (.value.error // "no error message")))' \
    .signum/execute_log.json 2>/dev/null || jq . .signum/execute_log.json
  exit 1
fi
```

If exit code is non-zero, report: "Engineer agent failed after all attempts. Fix the issues above and re-run /signum."

Verify the patch exists:

```bash
test -f .signum/combined.patch && wc -l .signum/combined.patch || echo "WARNING: combined.patch missing"
```

### Step 2.3: Display execution summary

Use the Bash tool:

```bash
jq -r '"Attempts used: " + (.totalAttempts | tostring) + "/" + (.maxAttempts | tostring),
       "Acceptance criteria passed: " +
         ([.attempts[-1].checks | to_entries[] | select(.value.passed == true)] | length | tostring)' \
  .signum/execute_log.json
```

### Step 2.4: Scope gate

Use the Bash tool to verify no out-of-scope files were modified:

```bash
# Get changed files from patch
CHANGED=$(git diff --name-only)
IN_SCOPE=$(jq -r '.inScope[]' .signum/contract.json)
ALLOW_NEW=$(jq -r '.allowNewFilesUnder // [] | .[]' .signum/contract.json)

VIOLATIONS=""
for file in $CHANGED; do
  match=0
  for pattern in $IN_SCOPE $ALLOW_NEW; do
    case "$file" in
      ${pattern}*) match=1; break ;;
    esac
  done
  [ $match -eq 0 ] && VIOLATIONS="$VIOLATIONS\n  $file"
done

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
if [ ! -f ".signum/contract-policy.json" ]; then
  echo "contract-policy.json not found, skipping policy check"
  echo '{"violations":[]}' > .signum/policy_violations.json
else
  FILE_COUNT=$(git diff --name-only | wc -l | tr -d '[:space:]')
  MAX_FILES=$(jq '.max_files_changed' .signum/contract-policy.json)

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
  done < <(jq -r '.bash_deny_patterns[]' .signum/contract-policy.json)

  printf '%s' "$VIOLS" | jq '{violations: .}' > .signum/policy_violations.json
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

Use the Bash tool to read the risk level and save it for conditional checks:

```bash
RISK_LEVEL=$(jq -r '.riskLevel' .signum/contract.json)
echo "RISK_LEVEL=$RISK_LEVEL"
```

Save `RISK_LEVEL` for use in all subsequent steps.

### Step 3.0.5: Repo-contract invariant check

If `repo-contract.json` and `.signum/repo_contract_baseline.json` both exist, re-run invariants and detect regressions:

```bash
if [ -f "repo-contract.json" ] && [ -f ".signum/repo_contract_baseline.json" ]; then
  python3 -c "
import json, subprocess
with open('repo-contract.json') as f:
    rc = json.load(f)
with open('.signum/repo_contract_baseline.json') as f:
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
        regressions.append(f'{iid} ({inv[\"severity\"]}): {inv[\"description\"]}')
with open('.signum/repo_contract_violations.json', 'w') as f:
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
"
fi
```

If output contains `AUTO_BLOCK`, **STOP**. Invariant regressions are critical failures regardless of task-level AC results. Do not proceed to Step 3.1.

### Step 3.1: Mechanic (bash, zero LLM)

Run full project checks and compare with baseline. Use the Bash tool:

```bash
# Lint
if [ -f "pyproject.toml" ] && grep -q "ruff" pyproject.toml 2>/dev/null; then
  LINT_OUT=$(ruff check . 2>&1); LINT_EXIT=$?
elif [ -f "package.json" ] && grep -q "eslint" package.json 2>/dev/null; then
  LINT_OUT=$(npx eslint . 2>&1); LINT_EXIT=$?
else
  LINT_OUT="no linter found, skipped"; LINT_EXIT=0
fi

# Typecheck
if [ -f "pyproject.toml" ] && grep -q "mypy" pyproject.toml 2>/dev/null; then
  TYPE_OUT=$(mypy . 2>&1); TYPE_EXIT=$?
elif [ -f "tsconfig.json" ]; then
  TYPE_OUT=$(npx tsc --noEmit 2>&1); TYPE_EXIT=$?
else
  TYPE_OUT="no typecheck found, skipped"; TYPE_EXIT=0
fi

# Read baseline
BL_LINT=$(jq -r '.lint' .signum/baseline.json)
BL_TYPE=$(jq -r '.typecheck' .signum/baseline.json)
BL_TEST=$(jq -r '.tests.exit_code // .tests' .signum/baseline.json)
BL_TEST_FAILING=$(jq -c '.tests.failing // []' .signum/baseline.json)

# Tests — capture per-test names for regression detection
if [ -f "pyproject.toml" ] && grep -q "pytest" pyproject.toml 2>/dev/null; then
  TEST_OUT=$(pytest --tb=short -q 2>&1); TEST_EXIT=$?
  TEST_FAILING=$(echo "$TEST_OUT" | grep -E '^FAILED ' | sed 's/^FAILED //' | sed 's/ - .*//' | jq -R . | jq -s .)
  [ -z "$TEST_FAILING" ] && TEST_FAILING='[]'
  NEW_FAILURES=$(jq -n --argjson curr "$TEST_FAILING" --argjson base "$BL_TEST_FAILING" \
    '[$curr[] | select(. as $t | $base | index($t) | not)]')
elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
  TEST_OUT=$(npm test 2>&1); TEST_EXIT=$?
  TEST_FAILING='[]'
  NEW_FAILURES='[]'
elif [ -f "Cargo.toml" ]; then
  TEST_OUT=$(cargo test 2>&1); TEST_EXIT=$?
  TEST_FAILING='[]'
  NEW_FAILURES='[]'
else
  TEST_OUT="no test runner found, skipped"; TEST_EXIT=0
  TEST_FAILING='[]'
  NEW_FAILURES='[]'
fi

# Write mechanic report with regression detection
jq -n \
  --arg lint_status "$([ $LINT_EXIT -eq 0 ] && echo pass || echo fail)" \
  --argjson lint_exit "$LINT_EXIT" \
  --arg type_status "$([ $TYPE_EXIT -eq 0 ] && echo pass || echo fail)" \
  --argjson type_exit "$TYPE_EXIT" \
  --arg test_status "$([ $TEST_EXIT -eq 0 ] && echo pass || echo fail)" \
  --argjson test_exit "$TEST_EXIT" \
  --argjson bl_lint "$BL_LINT" \
  --argjson bl_type "$BL_TYPE" \
  --argjson bl_test "$BL_TEST" \
  --argjson new_failures "$NEW_FAILURES" \
  --argjson test_failing "$TEST_FAILING" \
  '{
    lint:      { status: $lint_status, exitCode: $lint_exit, baseline: $bl_lint,
                 regression: (if $bl_lint == 0 and $lint_exit != 0 then true else false end) },
    typecheck: { status: $type_status, exitCode: $type_exit, baseline: $bl_type,
                 regression: (if $bl_type == 0 and $type_exit != 0 then true else false end) },
    tests:     { status: $test_status, exitCode: $test_exit, baseline: $bl_test,
                 failing: $test_failing, newFailures: $new_failures,
                 regression: (if ($new_failures | length) > 0 then true
                              elif $bl_test == 0 and $test_exit != 0 then true
                              else false end) },
    hasRegressions: (if ($new_failures | length) > 0 or
                        ($bl_lint == 0 and $lint_exit != 0) or
                        ($bl_type == 0 and $type_exit != 0) then true else false end)
  }' > .signum/mechanic_report.json

echo "Mechanic done. Lint=$LINT_EXIT(bl:$BL_LINT) Typecheck=$TYPE_EXIT(bl:$BL_TYPE) Tests=$TEST_EXIT(bl:$BL_TEST)"
```

If any check has a NEW regression, continue to reviews — mechanic regression influences the final decision but does not block the audit.

### Step 3.1.5: Holdout validation

**Skip if `RISK_LEVEL` is `low`.** Write an empty holdout report and proceed to Step 3.2.

Otherwise, run holdout verification using the typed DSL runner. Supports both new format (`acceptanceCriteria` with `visibility: "holdout"`) and legacy `holdoutScenarios`:

```bash
if [ "$RISK_LEVEL" = "low" ]; then
  echo '{"total":0,"passed":0,"failed":0,"errors":0,"results":[]}' > .signum/holdout_report.json
  echo "Holdout validation skipped (low risk)"
else
# Count holdouts: new format (visibility=holdout) + legacy (holdoutScenarios)
HOLDOUT_ACS=$(jq '[.acceptanceCriteria[] | select(.visibility == "holdout")] | length' .signum/contract.json)
LEGACY_HOLDOUTS=$(jq '.holdoutScenarios // [] | length' .signum/contract.json)
TOTAL_HOLDOUTS=$((HOLDOUT_ACS + LEGACY_HOLDOUTS))

if [ "$TOTAL_HOLDOUTS" -gt 0 ]; then
  PASS=0; FAIL=0; ERRORS=0
  RESULTS="[]"

  # New format: AC with visibility=holdout
  for i in $(seq 0 $((HOLDOUT_ACS - 1))); do
    ID=$(jq -r "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].id" .signum/contract.json)
    DESC=$(jq -r "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].description" .signum/contract.json)

    VERIFY_FILE=$(mktemp)
    jq "[.acceptanceCriteria[] | select(.visibility == \"holdout\")][$i].verify" .signum/contract.json > "$VERIFY_FILE"

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
    ID=$(jq -r ".holdoutScenarios[$i].id // \"HO$((i+1))\"" .signum/contract.json)
    DESC=$(jq -r ".holdoutScenarios[$i].description" .signum/contract.json)
    HAS_STEPS=$(jq ".holdoutScenarios[$i].verify | has(\"steps\")" .signum/contract.json)
    if [ "$HAS_STEPS" = "true" ]; then
      VERIFY_FILE=$(mktemp)
      jq ".holdoutScenarios[$i].verify" .signum/contract.json > "$VERIFY_FILE"
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
    > .signum/holdout_report.json
  echo "Holdout: $PASS passed, $FAIL failed, $ERRORS errors"
else
  echo '{"total":0,"passed":0,"failed":0,"errors":0,"results":[]}' > .signum/holdout_report.json
  echo "No holdout scenarios"
fi
fi
```

If any holdout fails, continue to reviews but synthesizer treats it as regression signal.

### Step 3.2: Prepare prompts for all reviewers

**If `RISK_LEVEL` is `low`:** skip this step entirely (no external prompts needed). Set `CODEX_AVAILABLE=false` and `GEMINI_AVAILABLE=false`, then proceed directly to Step 3.2.5 (Claude-only).

Otherwise, in a single Bash block, check both codex and gemini availability, build both prompts (security-focused for codex, performance-focused for gemini), and save as `.signum/review_prompt_codex.txt` and `.signum/review_prompt_gemini.txt`:

```bash
which codex > /dev/null 2>&1 && CODEX_AVAILABLE=true || CODEX_AVAILABLE=false
which gemini > /dev/null 2>&1 && GEMINI_AVAILABLE=true || GEMINI_AVAILABLE=false

if [ "$CODEX_AVAILABLE" = "true" ]; then
  python3 -c "
import json, sys
goal = json.load(open('.signum/contract.json'))['goal']
diff = open('.signum/combined.patch').read()
tmpl = open('lib/prompts/review-template-security.md').read()
print(tmpl.replace('{goal}', goal).replace('{diff}', diff))
" > .signum/review_prompt_codex.txt
  echo "codex: AVAILABLE, prompt written"
else
  echo "codex: UNAVAILABLE"
fi

if [ "$GEMINI_AVAILABLE" = "true" ]; then
  python3 -c "
import json, sys
goal = json.load(open('.signum/contract.json'))['goal']
diff = open('.signum/combined.patch').read()
tmpl = open('lib/prompts/review-template-performance.md').read()
print(tmpl.replace('{goal}', goal).replace('{diff}', diff))
" > .signum/review_prompt_gemini.txt
  echo "gemini: AVAILABLE, prompt written"
else
  echo "gemini: UNAVAILABLE"
fi

echo "CODEX_AVAILABLE=$CODEX_AVAILABLE GEMINI_AVAILABLE=$GEMINI_AVAILABLE"
```

Save CODEX_AVAILABLE and GEMINI_AVAILABLE for use in the next step.

### Step 3.2.5: Launch reviews

**Fresh-reviewer rule:** If the Engineer used more than 1 attempt (check `totalAttempts` in `.signum/execute_log.json`), use `model: "sonnet"` for the Claude reviewer agent instead of the default opus. This ensures a fresh perspective on retry code rather than the same model re-reviewing similar output.

**Risk-proportional launch:**
- **Low risk:** Launch Claude reviewer ONLY (foreground, not background). Write UNAVAILABLE stubs for codex and gemini immediately. Skip to Step 3.3 (no TaskOutput wait needed since Claude ran foreground, but still verify claude.json output).
- **Medium/High risk:** Use a single message with multiple tool use blocks to launch all available reviewers simultaneously. Do NOT wait between launches.

For medium/high risk, launch the reviewer-claude Agent with `run_in_background: true`, the Codex Bash with `run_in_background: true`, and the Gemini Bash with `run_in_background: true` — all in the same message:

**Claude (Agent tool, `run_in_background: true`):**

If Engineer used >1 attempt, add `model: "sonnet"` to the Agent tool call.

```
Read .signum/contract.json, .signum/combined.patch, and .signum/mechanic_report.json.
Follow lib/prompts/review-template.md and write your review to .signum/reviews/claude.json.
Write ONLY the JSON object, no markers, no markdown.
```

**Codex (Bash tool, `run_in_background: true`, only if CODEX_AVAILABLE):**

```bash
PROMPT=$(cat .signum/review_prompt_codex.txt)
OUT=$(mktemp)
CODEX_MODEL_FLAG=""
[ -n "$SIGNUM_CODEX_MODEL" ] && CODEX_MODEL_FLAG="--model $SIGNUM_CODEX_MODEL"
codex exec --ephemeral -C "$PWD" -p fast $CODEX_MODEL_FLAG --output-last-message "$OUT" "$PROMPT" \
  > .signum/reviews/codex_stdout.txt 2>&1
cp "$OUT" .signum/reviews/codex_raw.txt 2>/dev/null || \
  cp .signum/reviews/codex_stdout.txt .signum/reviews/codex_raw.txt
rm -f "$OUT"
echo "CODEX_DONE"
```

**Gemini (Bash tool, `run_in_background: true`, only if GEMINI_AVAILABLE):**

```bash
PROMPT=$(cat .signum/review_prompt_gemini.txt)
GEMINI_MODEL_FLAG=""
[ -n "$SIGNUM_GEMINI_MODEL" ] && GEMINI_MODEL_FLAG="--model $SIGNUM_GEMINI_MODEL"
gemini $GEMINI_MODEL_FLAG -p "$PROMPT" > .signum/reviews/gemini_raw.txt 2>&1
echo "GEMINI_DONE"
```

Save the background task IDs: CLAUDE_TASK_ID, CODEX_TASK_ID, GEMINI_TASK_ID. Do NOT wait for any of them before launching the others. Then proceed to Step 3.3 below.

### Step 3.3: Collect all 3 results

Use the TaskOutput tool with `block: true` to wait for CLAUDE_TASK_ID. Then use the TaskOutput tool with `block: true` to wait for CODEX_TASK_ID (if codex was launched). Then use the TaskOutput tool with `block: true` to wait for GEMINI_TASK_ID (if gemini was launched).

After all complete (or if they were never launched), verify the claude output:

```bash
test -f .signum/reviews/claude.json && jq -e '.verdict' .signum/reviews/claude.json > /dev/null \
  && echo "claude review OK" || echo "WARNING: claude.json missing or invalid"
```

### Step 3.3.5: Parse codex and gemini outputs

After collection, parse codex output and parse gemini output.

If CODEX_AVAILABLE: attempt 3-level parsing of `.signum/reviews/codex_raw.txt`:

```bash
# Level 1: valid JSON directly
if jq -e '.verdict' .signum/reviews/codex_raw.txt > /dev/null 2>&1; then
  cp .signum/reviews/codex_raw.txt .signum/reviews/codex.json
  echo "codex: parsed as direct JSON"

# Level 2: extract between markers
elif grep -q '###SIGNUM_REVIEW_START###' .signum/reviews/codex_raw.txt; then
  sed -n '/###SIGNUM_REVIEW_START###/,/###SIGNUM_REVIEW_END###/p' .signum/reviews/codex_raw.txt \
    | grep -v '###SIGNUM_REVIEW' > .signum/codex_extracted.json
  if jq -e '.verdict' .signum/codex_extracted.json > /dev/null 2>&1; then
    cp .signum/codex_extracted.json .signum/reviews/codex.json
    echo "codex: parsed via markers"
  else
    RAW=$(cat .signum/reviews/codex_raw.txt | head -c 2000)
    jq -n --arg raw "$RAW" \
      '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse codex output","parseOk":false,"raw":$raw}' \
      > .signum/reviews/codex.json
    echo "codex: marker extraction failed, saved raw"
  fi

# Level 3: save raw, mark unparseable
else
  RAW=$(cat .signum/reviews/codex_raw.txt | head -c 2000)
  jq -n --arg raw "$RAW" \
    '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse codex output","parseOk":false,"raw":$raw}' \
    > .signum/reviews/codex.json
  echo "codex: no markers found, saved raw"
fi
```

If CODEX_UNAVAILABLE:

```bash
echo '{"verdict":"UNAVAILABLE","findings":[],"summary":"Codex CLI not installed","available":false}' \
  > .signum/reviews/codex.json
```

If GEMINI_AVAILABLE: attempt 3-level parsing of `.signum/reviews/gemini_raw.txt`:

```bash
if jq -e '.verdict' .signum/reviews/gemini_raw.txt > /dev/null 2>&1; then
  cp .signum/reviews/gemini_raw.txt .signum/reviews/gemini.json
  echo "gemini: parsed as direct JSON"

elif grep -q '###SIGNUM_REVIEW_START###' .signum/reviews/gemini_raw.txt; then
  sed -n '/###SIGNUM_REVIEW_START###/,/###SIGNUM_REVIEW_END###/p' .signum/reviews/gemini_raw.txt \
    | grep -v '###SIGNUM_REVIEW' > .signum/gemini_extracted.json
  if jq -e '.verdict' .signum/gemini_extracted.json > /dev/null 2>&1; then
    cp .signum/gemini_extracted.json .signum/reviews/gemini.json
    echo "gemini: parsed via markers"
  else
    RAW=$(cat .signum/reviews/gemini_raw.txt | head -c 2000)
    jq -n --arg raw "$RAW" \
      '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse gemini output","parseOk":false,"raw":$raw}' \
      > .signum/reviews/gemini.json
    echo "gemini: marker extraction failed, saved raw"
  fi

else
  RAW=$(cat .signum/reviews/gemini_raw.txt | head -c 2000)
  jq -n --arg raw "$RAW" \
    '{"verdict":"CONDITIONAL","findings":[],"summary":"Could not parse gemini output","parseOk":false,"raw":$raw}' \
    > .signum/reviews/gemini.json
  echo "gemini: no markers found, saved raw"
fi
```

If GEMINI_UNAVAILABLE:

```bash
echo '{"verdict":"UNAVAILABLE","findings":[],"summary":"Gemini CLI not installed","available":false}' \
  > .signum/reviews/gemini.json
```

### Step 3.5: Synthesizer (agent)

Use the Agent tool to launch the "synthesizer" agent with this prompt:

```
Read .signum/mechanic_report.json, .signum/reviews/claude.json,
.signum/reviews/codex.json, .signum/reviews/gemini.json,
.signum/holdout_report.json, and .signum/execute_log.json.
Apply deterministic synthesis rules, compute confidence scores,
and write .signum/audit_summary.json.
```

After it finishes, read and display the audit summary:

```bash
test -f .signum/audit_summary.json || { echo "ERROR: audit_summary.json not found"; exit 1; }

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
       "Reasoning: " + .reasoning' \
  .signum/audit_summary.json
```

---

## Phase 4: PACK

**Goal:** Bundle all artifacts into a self-contained, verifiable proof package (schema v4.1) with embedded artifact contents.

### Step 4.0: Transition contract status to completed

Transition the contract status from `active` to `completed` and record the `completedAt` timestamp:

```bash
COMPLETED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg ts "$COMPLETED_TS" \
  '.status = "completed" | .timestamps.completedAt = $ts' \
  .signum/contract.json > .signum/contract-tmp.json && \
  mv .signum/contract-tmp.json .signum/contract.json
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

# Metadata
DECISION=$(jq -r '.decision' .signum/audit_summary.json)
GOAL=$(jq -r '.goal' .signum/contract.json)
RISK=$(jq -r '.riskLevel' .signum/contract.json)
ATTEMPTS=$(jq -r '.totalAttempts' .signum/execute_log.json 2>/dev/null || echo "unknown")
MECHANIC=$(jq -r '.mechanic' .signum/audit_summary.json)
CONFIDENCE=$(jq -r '.confidence.overall // 0' .signum/audit_summary.json)
RUN_DATE=$(date +%Y-%m-%dT%H:%M:%SZ)
RUN_RANDOM=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
RUN_ID="signum-$(date +%Y-%m-%d)-${RUN_RANDOM}"

# Audit chain
CONTRACT_HASH=$(grep 'contract_sha256:' .signum/contract-hash.txt 2>/dev/null | awk '{print $2}' || echo "unavailable")
APPROVED_AT=$(grep 'approved_at:' .signum/contract-hash.txt 2>/dev/null | awk '{print $2}' || echo "unavailable")
BASE_COMMIT=$(jq -r '.base_commit // "unavailable"' .signum/execution_context.json 2>/dev/null || echo "unavailable")

# Contract redaction: strip holdoutScenarios, save to temp file
REDACTED_CONTRACT=$(mktemp /tmp/signum-contract-redacted.XXXXXX.json)
python3 -c "
import json, sys
with open('.signum/contract.json') as f:
    data = json.load(f)
data.pop('holdoutScenarios', None)
json.dump(data, sys.stdout)
" > "$REDACTED_CONTRACT"

CONTRACT_SHA256=$(hash_file "$REDACTED_CONTRACT")
CONTRACT_FULL_SHA256=$(hash_file .signum/contract.json)

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
DIFF_ENV=$(build_envelope .signum/combined.patch)

# Baseline envelope (optional artifact)
BASELINE_ENV=$(build_envelope .signum/baseline.json)

# Execute log envelope
EXECUTE_ENV=$(build_envelope .signum/execute_log.json)

# Mechanic and holdout envelopes
MECHANIC_ENV=$(build_envelope .signum/mechanic_report.json)
HOLDOUT_ENV=$(build_envelope .signum/holdout_report.json)

# Audit summary envelope
AUDIT_ENV=$(build_envelope .signum/audit_summary.json)

# Approval envelope
APPROVAL_ENV=$(build_envelope .signum/approval.json)

# Dynamic reviews: enumerate .signum/reviews/*.json
REVIEWS_JSON='{'
first=1
for review_file in .signum/reviews/*.json; do
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
PACK_CONTRACT_ID=$(jq -r '.contractId // empty' .signum/contract.json)

# Final assembly
jq -n \
  --arg schemaVersion "4.1" \
  --arg signumVersion "4.1.0" \
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
  --argjson auditEnv "$AUDIT_ENV" \
  --argjson approvalEnv "$APPROVAL_ENV" \
  --argjson reviewsEnv "$REVIEWS_JSON" \
  --arg contractSource "$CONTRACT_SOURCE" \
  --argjson ciContext "$CI_CONTEXT" \
  --argjson baselineComp "$BASELINE_COMP" \
  '{
    schemaVersion: $schemaVersion,
    signumVersion: $signumVersion,
    createdAt: $createdAt,
    runId: $runId,
    contractId: (if $contractId != "" then $contractId else null end),
    decision: $decision,
    summary: $summary,
    confidence: { overall: $confidence },
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
      reviews: $reviewsEnv,
      auditSummary: $auditEnv
    }
  }
  | if $ciContext != null then . + {ciContext: $ciContext} else . end
  | if $baselineComp != null then . + {baselineComparison: $baselineComp} else . end
  ' > .signum/proofpack.json

# Cleanup temp files
rm -f "$REDACTED_CONTRACT"

echo "Proofpack written: $RUN_ID (schema v4.1)"
```

### Step 4.2: Update contract status

Use the Bash tool to transition the contract to `completed`:

```bash
if [ -f lib/contract-dir.sh ]; then
  source lib/contract-dir.sh
  CONTRACT_ID=$(jq -r '.contractId // empty' .signum/contract.json)
  if [ -n "$CONTRACT_ID" ]; then
    update_contract_status "$CONTRACT_ID" "completed"
    # Sync updated contract.json + proofpack to per-contract directory
    DIR=$(contract_dir "$CONTRACT_ID")
    cp .signum/contract.json "${DIR}" 2>/dev/null || true
    cp .signum/proofpack.json "${DIR}" 2>/dev/null || true
    echo "Contract $CONTRACT_ID → completed"
  fi
fi
```

---

## Final Output

Display to the user:

Use the Bash tool to list all produced artifacts:

```bash
echo "=== Artifacts in .signum/ ==="
ls -1 .signum/ .signum/reviews/ 2>/dev/null
echo ""
echo "Decision:   $(jq -r .decision .signum/proofpack.json)"
echo "Confidence: $(jq -r '.confidence.overall' .signum/proofpack.json)%"
echo "Run ID:     $(jq -r .runId   .signum/proofpack.json)"
```

Then display the appropriate next steps based on the decision:

- **AUTO_OK**: "Changes are verified. Review `.signum/combined.patch` and commit when ready."
- **AUTO_BLOCK**: "Issues found. Review `.signum/audit_summary.json` and fix before committing."
- **HUMAN_REVIEW**: "Audit inconclusive. Review `.signum/audit_summary.json`, then either: (1) refine acceptance criteria and re-run `/signum`, or (2) manually verify the flagged findings."

---

## Error Handling

- If any phase fails catastrophically (agent error, required file missing after agent run), **STOP** immediately and report: what phase failed, what file is missing, and what the user should do next.
- Mechanic check failures continue to audit — they influence the decision but do not block Phase 3.
- If codex or gemini times out (`exit 124`) or returns a non-zero exit code, mark as unavailable and continue.
- **Never silently swallow errors.** All bash exit codes must be checked. If jq fails to parse a file, report it explicitly.
- If the synthesizer produces an invalid audit_summary.json, stop Phase 4 and report the problem.
