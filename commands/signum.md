---
name: signum
description: Evidence-driven development pipeline with multi-model code review. Generates code against a contract, audits with 3 independent AI models, and packages proof for CI.
arguments:
  - name: task
    description: What to build or fix (feature description)
    required: true
---

# Signum v3: Evidence-Driven Development Pipeline

You are the Signum orchestrator. You drive a 4-phase evidence-driven pipeline:

```
CONTRACT → EXECUTE → AUDIT → PACK
```

The user's task: `$ARGUMENTS`

## Setup

Use the Bash tool to prepare the workspace:

```bash
mkdir -p .signum/reviews
touch .gitignore
grep -q '^\.signum/$' .gitignore || echo '.signum/' >> .gitignore
```

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
       .signum/reviews/claude.json .signum/reviews/codex.json .signum/reviews/gemini.json \
       .signum/review_prompt_codex.txt .signum/review_prompt_gemini.txt \
       .signum/reviews/codex_raw.txt .signum/reviews/gemini_raw.txt
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

### Step 1.3: Check for open questions

Use the Bash tool:

```bash
jq -r 'if (.openQuestions | length) > 0 then "BLOCKED: " + (.openQuestions | join("\n  - ")) else "OK" end' \
  .signum/contract.json
```

If output starts with `BLOCKED:`, display the open questions to the user exactly as listed, then **STOP**.

Do not proceed to Phase 2 until the user provides answers to every open question. When answers are received, re-launch the contractor agent with the original request plus the answers appended, and repeat Step 1.2–1.3.

### Step 1.4: Display contract summary

Use the Bash tool to extract and display:

```bash
jq -r '"Goal: " + .goal,
       "Risk: " + .riskLevel,
       "In scope: " + (.inScope | join(", ")),
       "Acceptance criteria: " + (.acceptanceCriteria | length | tostring) + " defined",
       "Holdout scenarios: " + ((.holdoutScenarios // []) | length | tostring) + " defined"' \
  .signum/contract.json
```

Also display any riskSignals if riskLevel is "high":

```bash
jq -r 'if .riskLevel == "high" then "Risk signals: " + (.riskSignals // [] | join(", ")) else empty end' \
  .signum/contract.json
```

**Ask the user to confirm before proceeding to Phase 2.** Display: "Contract ready. Proceed with implementation? (yes/no)"

Wait for confirmation. If the user says no, stop.

### Step 1.5: Prepare sanitized engineer contract

Use the Bash tool to create a contract stripped of holdout scenarios (data-level isolation):

```bash
# Create contract-engineer.json: full contract minus holdoutScenarios
# Engineer cannot see holdouts — not a prompt instruction, actual data removal
python3 -c "
import json
with open('.signum/contract.json') as f:
    c = json.load(f)
c.pop('holdoutScenarios', None)
with open('.signum/contract-engineer.json', 'w') as f:
    json.dump(c, f, indent=2)
ac_count = len(c.get('acceptanceCriteria', []))
print(f'contract-engineer.json written ({ac_count} ACs, holdouts removed)')
"
```

---

## Phase 2: EXECUTE

**Goal:** Implement code changes according to the contract.

### Step 2.0: Capture baseline (before any changes)

Use the Bash tool to run project checks BEFORE the engineer touches anything:

```bash
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

---

## Phase 3: AUDIT

**Goal:** Verify the change from multiple independent angles.

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

If contract has `holdoutScenarios`, run them now (Engineer never saw these):

```bash
HOLDOUTS=$(jq -r '.holdoutScenarios // [] | length' .signum/contract.json)
if [ "$HOLDOUTS" -gt 0 ]; then
  PASS=0; FAIL=0
  for i in $(seq 0 $((HOLDOUTS - 1))); do
    CMD=$(jq -r ".holdoutScenarios[$i].verify.value" .signum/contract.json)
    DESC=$(jq -r ".holdoutScenarios[$i].description" .signum/contract.json)
    if eval "$CMD" > /dev/null 2>&1; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "HOLDOUT FAIL: $DESC"
    fi
  done
  jq -n --argjson pass "$PASS" --argjson fail "$FAIL" \
    '{ total: ($pass + $fail), passed: $pass, failed: $fail }' > .signum/holdout_report.json
  echo "Holdout: $PASS passed, $FAIL failed"
else
  echo '{"total":0,"passed":0,"failed":0}' > .signum/holdout_report.json
  echo "No holdout scenarios"
fi
```

If any holdout fails, continue to reviews but synthesizer treats it as regression signal.

### Step 3.2: Reviewer-Claude (agent)

Use the Agent tool to launch the "reviewer-claude" agent with this prompt:

```
Read .signum/contract.json, .signum/combined.patch, and .signum/mechanic_report.json.
Follow lib/prompts/review-template.md and write your review to .signum/reviews/claude.json.
Write ONLY the JSON object, no markers, no markdown.
```

After it finishes, verify the output exists:

```bash
test -f .signum/reviews/claude.json && jq -e '.verdict' .signum/reviews/claude.json > /dev/null \
  && echo "claude review OK" || echo "WARNING: claude.json missing or invalid"
```

### Step 3.3: Reviewer-Codex (CLI, security-focused)

Use the Bash tool to check availability:

```bash
which codex > /dev/null 2>&1 && echo "AVAILABLE" || echo "UNAVAILABLE"
```

**If AVAILABLE:**

Build the security-focused review prompt:

```bash
python3 -c "
import json, sys
goal = json.load(open('.signum/contract.json'))['goal']
diff = open('.signum/combined.patch').read()
tmpl = open('lib/prompts/review-template-security.md').read()
print(tmpl.replace('{goal}', goal).replace('{diff}', diff))
" > .signum/review_prompt_codex.txt
```

Run codex and attempt 3-level parsing:

```bash
# Run codex (modern CLI: codex exec --ephemeral)
PROMPT=$(cat .signum/review_prompt_codex.txt)
OUT=$(mktemp)
codex exec --ephemeral -C "$PWD" -p fast --output-last-message "$OUT" "$PROMPT" \
  > .signum/reviews/codex_stdout.txt 2>&1 &
CODEX_PID=$!
( sleep 180; kill $CODEX_PID 2>/dev/null ) &
TIMER_PID=$!
wait $CODEX_PID 2>/dev/null
CODEX_EXIT=$?
kill $TIMER_PID 2>/dev/null; wait $TIMER_PID 2>/dev/null
# Copy last-message output (clean JSON) to raw file for subsequent parsing
cp "$OUT" .signum/reviews/codex_raw.txt 2>/dev/null || \
  cp .signum/reviews/codex_stdout.txt .signum/reviews/codex_raw.txt
rm -f "$OUT"

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

**If UNAVAILABLE:**

```bash
echo '{"verdict":"UNAVAILABLE","findings":[],"summary":"Codex CLI not installed","available":false}' \
  > .signum/reviews/codex.json
```

### Step 3.4: Reviewer-Gemini (CLI, performance-focused)

Use the Bash tool to check availability:

```bash
which gemini > /dev/null 2>&1 && echo "AVAILABLE" || echo "UNAVAILABLE"
```

**If AVAILABLE:**

Build the performance-focused review prompt:

```bash
python3 -c "
import json, sys
goal = json.load(open('.signum/contract.json'))['goal']
diff = open('.signum/combined.patch').read()
tmpl = open('lib/prompts/review-template-performance.md').read()
print(tmpl.replace('{goal}', goal).replace('{diff}', diff))
" > .signum/review_prompt_gemini.txt
```

Run gemini with same 3-level parsing:

```bash
PROMPT=$(cat .signum/review_prompt_gemini.txt)
gemini -p "$PROMPT" > .signum/reviews/gemini_raw.txt 2>&1 &
GEMINI_PID=$!
( sleep 180; kill $GEMINI_PID 2>/dev/null ) &
TIMER_PID=$!
wait $GEMINI_PID 2>/dev/null
GEMINI_EXIT=$?
kill $TIMER_PID 2>/dev/null; wait $TIMER_PID 2>/dev/null

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

**If UNAVAILABLE:**

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

**Goal:** Bundle all artifacts into a verifiable proof package.

### Step 4.1: Compute checksums

Use the Bash tool:

```bash
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  echo "ERROR: no sha256 tool found"; exit 1
fi

$HASH_CMD .signum/contract.json .signum/combined.patch \
          .signum/mechanic_report.json .signum/audit_summary.json 2>/dev/null \
  | awk '{print $2, $1}' | sort
```

### Step 4.2: Assemble proofpack.json

Use the Bash tool to build the full proofpack:

```bash
DECISION=$(jq -r '.decision' .signum/audit_summary.json)
GOAL=$(jq -r '.goal' .signum/contract.json)
RISK=$(jq -r '.riskLevel' .signum/contract.json)
ATTEMPTS=$(jq -r '.totalAttempts' .signum/execute_log.json 2>/dev/null || echo "unknown")
MECHANIC=$(jq -r '.mechanic' .signum/audit_summary.json)
CONFIDENCE=$(jq -r '.confidence.overall // 0' .signum/audit_summary.json)
RUN_DATE=$(date +%Y-%m-%d)
RUN_RANDOM=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
RUN_ID="signum-${RUN_DATE}-${RUN_RANDOM}"

# Cross-platform sha256
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  echo "ERROR: no sha256 tool found"; exit 1
fi

# Compute individual checksums
sum_contract=$($HASH_CMD .signum/contract.json 2>/dev/null | awk '{print "sha256:" $1}' || echo "sha256:missing")
sum_patch=$($HASH_CMD .signum/combined.patch 2>/dev/null | awk '{print "sha256:" $1}' || echo "sha256:missing")
sum_mechanic=$($HASH_CMD .signum/mechanic_report.json 2>/dev/null | awk '{print "sha256:" $1}' || echo "sha256:missing")
sum_audit=$($HASH_CMD .signum/audit_summary.json 2>/dev/null | awk '{print "sha256:" $1}' || echo "sha256:missing")

jq -n \
  --arg schema "3.0" \
  --arg runId "$RUN_ID" \
  --arg decision "$DECISION" \
  --arg summary "Goal: $GOAL | Risk: $RISK | Attempts: $ATTEMPTS | Mechanic: $MECHANIC | Confidence: ${CONFIDENCE}% | Decision: $DECISION" \
  --argjson confidence "$CONFIDENCE" \
  --arg sum_contract "$sum_contract" \
  --arg sum_patch "$sum_patch" \
  --arg sum_mechanic "$sum_mechanic" \
  --arg sum_audit "$sum_audit" \
  '{
    schemaVersion: $schema,
    runId: $runId,
    decision: $decision,
    contract: "contract.json",
    diff: "combined.patch",
    checks: {
      mechanic: "mechanic_report.json",
      reviews: {
        claude: "reviews/claude.json",
        codex:  "reviews/codex.json",
        gemini: "reviews/gemini.json"
      },
      audit_summary: "audit_summary.json"
    },
    checksums: {
      "contract.json":        $sum_contract,
      "combined.patch":       $sum_patch,
      "mechanic_report.json": $sum_mechanic,
      "audit_summary.json":   $sum_audit
    },
    confidence: { overall: $confidence },
    summary: $summary,
    executeLog: "execute_log.json"
  }' > .signum/proofpack.json

echo "Proofpack written: $RUN_ID"
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
