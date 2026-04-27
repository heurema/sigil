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

