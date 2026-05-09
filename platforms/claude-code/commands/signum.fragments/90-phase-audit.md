## Phase 3: AUDIT

**Goal:** Verify the change from multiple independent angles.

### Risk-Proportional Ceremony

Read the contract's `riskLevel` and apply the matching ceremony profile. Steps marked "skip" MUST be skipped entirely (no agent launches, no CLI calls).

| Step | Low | Medium | High |
|------|-----|--------|------|
| 3.0.5 Repo-contract invariants | run | run | run |
| 3.1 Mechanic | run | run | run |
| 3.1.4 Reuse and duplication audit | conditional | conditional | conditional |
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

### Step 3.1.4: REUSE_AND_DUPLICATION_AUDIT

When Codebase Awareness is enabled, run the deterministic post-diff reuse/duplicate audit and write `duplicate_scan.json` under the active contract artifact root. This artifact remains evidence-only and does not contain final verdict vocabulary.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"

CODEBASE_INDEX_PATH=".signum/cache/codebase-index-v1.json"
STYLE_PROFILE_PATH=".signum/cache/style-profile-v1.json"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
IMPLEMENTATION_CONTEXT_PATH="${ARTIFACT_ROOT}implementation_context.json"
REUSE_CANDIDATES_PATH="${ARTIFACT_ROOT}reuse_candidates.json"
REUSE_DECISION_PATH="${ARTIFACT_ROOT}reuse_decision.json"
DUPLICATE_SCAN_PATH="${ARTIFACT_ROOT}duplicate_scan.json"

_POLICY_CODEBASE_MODE=""
if [ -f ".signum/policy.toml" ]; then
  _POLICY_CODEBASE_MODE=$(python3 - ".signum/policy.toml" <<'PY' 2>/dev/null || true
import re
import sys

mode = ""
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    text = ""

match = re.search(r"^\[codebase_awareness\]\s*(.*?)(?=^\[|\Z)", text, re.MULTILINE | re.DOTALL)
if match:
    for raw in match.group(1).splitlines():
        line = raw.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == "mode":
            mode = value.strip().strip('"').strip("'")

print(mode)
PY
)
fi

CODEBASE_AWARENESS_MODE="${SIGNUM_CODEBASE_AWARENESS:-${_POLICY_CODEBASE_MODE:-off}}"
case "$CODEBASE_AWARENESS_MODE" in
  off|hint|warn|gate)
    ;;
  *)
    echo "WARNING: invalid SIGNUM_CODEBASE_AWARENESS '$CODEBASE_AWARENESS_MODE'; using off"
    CODEBASE_AWARENESS_MODE="off"
    ;;
esac
export SIGNUM_CODEBASE_AWARENESS="$CODEBASE_AWARENESS_MODE"

if [ "$CODEBASE_AWARENESS_MODE" = "off" ]; then
  echo "REUSE_AND_DUPLICATION_AUDIT: skipped (Codebase Awareness off)"
else
  echo "REUSE_AND_DUPLICATION_AUDIT: mode=$CODEBASE_AWARENESS_MODE output=$DUPLICATE_SCAN_PATH"
  set +e
  python3 scripts/audit_codebase_reuse.py \
    --project-root . \
    --contract "$CONTRACT_PATH" \
    --patch "$COMBINED_PATCH_PATH" \
    --codebase-index "$CODEBASE_INDEX_PATH" \
    --reuse-candidates "$REUSE_CANDIDATES_PATH" \
    --reuse-decision "$REUSE_DECISION_PATH" \
    --output "$DUPLICATE_SCAN_PATH" \
    --style-profile "$STYLE_PROFILE_PATH" \
    --implementation-context "$IMPLEMENTATION_CONTEXT_PATH" \
    --mode "$CODEBASE_AWARENESS_MODE"
  _REUSE_DUPLICATION_AUDIT_STATUS=$?
  set -e

  if [ "$_REUSE_DUPLICATION_AUDIT_STATUS" -eq 0 ]; then
    echo "REUSE_AND_DUPLICATION_AUDIT: wrote $DUPLICATE_SCAN_PATH"
  elif [ "$CODEBASE_AWARENESS_MODE" = "gate" ]; then
    echo "ERROR: REUSE_AND_DUPLICATION_AUDIT failed in gate mode (exit=$_REUSE_DUPLICATION_AUDIT_STATUS, output=$DUPLICATE_SCAN_PATH)" >&2
    exit "$_REUSE_DUPLICATION_AUDIT_STATUS"
  else
    echo "WARNING: REUSE_AND_DUPLICATION_AUDIT failed in $CODEBASE_AWARENESS_MODE mode (exit=$_REUSE_DUPLICATION_AUDIT_STATUS, output=$DUPLICATE_SCAN_PATH); continuing AUDIT" >&2
  fi
fi
```

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
  # Crash → UNAVAILABLE (not CONDITIONAL)
  RAW=$(head -c 2000 "$CODEX_STDOUT_PATH" 2>/dev/null)
  jq -n --arg raw "$RAW" --arg code "$CODEX_EXIT" \
    '{"verdict":"UNAVAILABLE","findings":[],"summary":("Codex invocation failed (exit " + $code + ")"),"available":false,"raw":$raw}' \
    > "$CODEX_JSON_PATH"
  echo "codex: invocation failed (exit $CODEX_EXIT), marked UNAVAILABLE"

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
  # Crash → UNAVAILABLE (not CONDITIONAL)
  RAW=$(head -c 2000 "$GEMINI_RAW_PATH" 2>/dev/null)
  jq -n --arg raw "$RAW" --arg code "$GEMINI_EXIT" \
    '{"verdict":"UNAVAILABLE","findings":[],"summary":("Gemini invocation failed (exit " + $code + ")"),"available":false,"raw":$raw}' \
    > "$GEMINI_JSON_PATH"
  echo "gemini: invocation failed (exit $GEMINI_EXIT), marked UNAVAILABLE"

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

After it finishes, apply conservative Codebase Awareness verdict mapping to `audit_summary.json`, then read and display the audit summary:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
DUPLICATE_SCAN_PATH="${ARTIFACT_ROOT}duplicate_scan.json"
test -f "$AUDIT_SUMMARY_PATH" || { echo "ERROR: audit_summary.json not found"; exit 1; }

_POLICY_CODEBASE_MODE=""
if [ -f ".signum/policy.toml" ]; then
  _POLICY_CODEBASE_MODE=$(python3 - ".signum/policy.toml" <<'PY' 2>/dev/null || true
import re
import sys

mode = ""
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    text = ""

match = re.search(r"^\[codebase_awareness\]\s*(.*?)(?=^\[|\Z)", text, re.MULTILINE | re.DOTALL)
if match:
    for raw in match.group(1).splitlines():
        line = raw.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == "mode":
            mode = value.strip().strip('"').strip("'")

print(mode)
PY
)
fi

CODEBASE_AWARENESS_MODE="${SIGNUM_CODEBASE_AWARENESS:-${_POLICY_CODEBASE_MODE:-off}}"
case "$CODEBASE_AWARENESS_MODE" in
  off|hint|warn|gate)
    ;;
  *)
    echo "WARNING: invalid SIGNUM_CODEBASE_AWARENESS '$CODEBASE_AWARENESS_MODE'; using off"
    CODEBASE_AWARENESS_MODE="off"
    ;;
esac
python3 scripts/evaluate_codebase_awareness_audit.py \
  --audit-summary "$AUDIT_SUMMARY_PATH" \
  --duplicate-scan "$DUPLICATE_SCAN_PATH" \
  --mode "$CODEBASE_AWARENESS_MODE" \
  --output "$AUDIT_SUMMARY_PATH"

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

**Capture pre-repair snapshot (receipt chain):**

Before launching repair engineers, capture a fresh workspace snapshot for this attempt. Each attempt needs its own snapshot because `base_tree_hash` must bind to the actual starting state of this repair.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"

# Single-lane snapshot
if [ -z "$_SIGNUM_SNAPSHOT" ] || [ ! -f "$_SIGNUM_SNAPSHOT" ]; then
  _SIGNUM_SNAPSHOT=""
  for _d in \
    "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
    "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
    "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
    [ -f "${_d}/lib/snapshot-tree.sh" ] || continue
    _SIGNUM_SNAPSHOT="${_d}/lib/snapshot-tree.sh"
    break
  done
fi
ATTEMPT_PAD=$(printf '%02d' "$ITER_NUM")
if [ -n "$_SIGNUM_SNAPSHOT" ]; then
  bash "$_SIGNUM_SNAPSHOT" "execute-attempt-${ATTEMPT_PAD}" --workspace-root "$PWD" --signum-dir "$ARTIFACT_ROOT"
  echo "Pre-repair snapshot captured: execute-attempt-${ATTEMPT_PAD}"
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

# Re-resolve receipt chain scripts (variables may not persist across Bash tool calls)
if [ -z "${_SIGNUM_BOUNDARY:-}" ]; then
  for _d in \
    "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
    "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
    "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
    [ -f "${_d}/lib/boundary-verifier.sh" ] || continue
    _SIGNUM_BOUNDARY="${_d}/lib/boundary-verifier.sh"; break
  done
fi
if [ -z "${_SIGNUM_TRANSITION:-}" ]; then
  for _d in \
    "${_REAL_HOME:=$HOME}/.claude/plugins/signum/platforms/claude-code" \
    "${_REAL_HOME}/.local/share/emporium/signum/platforms/claude-code" \
    "${_REAL_HOME}/.nex/plugins/signum/platforms/claude-code"; do
    [ -f "${_d}/lib/transition-verifier.sh" ] || continue
    _SIGNUM_TRANSITION="${_d}/lib/transition-verifier.sh"; break
  done
fi
if [ -z "${_SIGNUM_BOUNDARY:-}" ] || [ -z "${_SIGNUM_TRANSITION:-}" ]; then
  echo "ERROR: receipt chain scripts not found — cannot proceed with repair verification" >&2
  exit 1
fi

RECEIPT_CHAIN_OK=true
if [ -n "${_SIGNUM_BOUNDARY:-}" ]; then
  ATTEMPT_PAD=$(printf '%02d' "$ITER_NUM")
  if ! bash "$_SIGNUM_BOUNDARY" execute \
    --workspace-root "$WINNER_DIR" \
    --signum-dir "$WINNER_SIGNUM_DIR" \
    --contract "${WINNER_ARTIFACT_ROOT}contract-engineer.json" \
    --contract-full "${WINNER_ARTIFACT_ROOT}contract.json" \
    --snapshot "${SNAPSHOTS_DIR}/execute-attempt-${ATTEMPT_PAD}.json"; then
    echo "BOUNDARY_BLOCK: repair attempt $ITER_NUM failed boundary verification"
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
if [ "$RECEIPT_CHAIN_OK" = "true" ] && [ -n "${_SIGNUM_TRANSITION:-}" ]; then
  ATTEMPT_PAD=$(printf '%02d' "$ITER_NUM")
  if ! bash "$_SIGNUM_TRANSITION" execute audit \
    --snapshot "${SNAPSHOTS_DIR}/execute-attempt-${ATTEMPT_PAD}.json"; then
    echo "TRANSITION_BLOCK: repair attempt $ITER_NUM failed transition gate"
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

Re-run Steps 2.4 (scope gate), 2.4.5 (policy compliance if applicable), 2.4.6 (scope existence gate), 2.5 (boundary verification), 2.6 (transition verification), 3.0.5 (repo-contract invariants), 3.1 (mechanic), 3.1.3 (policy scanner), 3.1.4 (reuse and duplication audit), 3.1.5 (holdout validation), 3.2-3.3.5 (reviews — risk-proportional), and 3.5 (synthesizer).

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
DUPLICATE_SCAN_PATH="${ARTIFACT_ROOT}duplicate_scan.json"

_POLICY_CODEBASE_MODE=""
if [ -f ".signum/policy.toml" ]; then
  _POLICY_CODEBASE_MODE=$(python3 - ".signum/policy.toml" <<'PY' 2>/dev/null || true
import re
import sys

mode = ""
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    text = ""

match = re.search(r"^\[codebase_awareness\]\s*(.*?)(?=^\[|\Z)", text, re.MULTILINE | re.DOTALL)
if match:
    for raw in match.group(1).splitlines():
        line = raw.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == "mode":
            mode = value.strip().strip('"').strip("'")

print(mode)
PY
)
fi

CODEBASE_AWARENESS_MODE="${SIGNUM_CODEBASE_AWARENESS:-${_POLICY_CODEBASE_MODE:-off}}"
case "$CODEBASE_AWARENESS_MODE" in
  off|hint|warn|gate)
    ;;
  *)
    echo "WARNING: invalid SIGNUM_CODEBASE_AWARENESS '$CODEBASE_AWARENESS_MODE'; using off"
    CODEBASE_AWARENESS_MODE="off"
    ;;
esac
python3 scripts/evaluate_codebase_awareness_audit.py \
  --audit-summary "$AUDIT_SUMMARY_PATH" \
  --duplicate-scan "$DUPLICATE_SCAN_PATH" \
  --mode "$CODEBASE_AWARENESS_MODE" \
  --output "$AUDIT_SUMMARY_PATH"

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

DUPLICATE_SCAN_PATH="${ARTIFACT_ROOT}duplicate_scan.json"
_POLICY_CODEBASE_MODE=""
if [ -f ".signum/policy.toml" ]; then
  _POLICY_CODEBASE_MODE=$(python3 - ".signum/policy.toml" <<'PY' 2>/dev/null || true
import re
import sys

mode = ""
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    text = ""

match = re.search(r"^\[codebase_awareness\]\s*(.*?)(?=^\[|\Z)", text, re.MULTILINE | re.DOTALL)
if match:
    for raw in match.group(1).splitlines():
        line = raw.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == "mode":
            mode = value.strip().strip('"').strip("'")

print(mode)
PY
)
fi

CODEBASE_AWARENESS_MODE="${SIGNUM_CODEBASE_AWARENESS:-${_POLICY_CODEBASE_MODE:-off}}"
case "$CODEBASE_AWARENESS_MODE" in
  off|hint|warn|gate)
    ;;
  *)
    echo "WARNING: invalid SIGNUM_CODEBASE_AWARENESS '$CODEBASE_AWARENESS_MODE'; using off"
    CODEBASE_AWARENESS_MODE="off"
    ;;
esac
python3 scripts/evaluate_codebase_awareness_audit.py \
  --audit-summary "$AUDIT_SUMMARY_PATH" \
  --duplicate-scan "$DUPLICATE_SCAN_PATH" \
  --mode "$CODEBASE_AWARENESS_MODE" \
  --output "$AUDIT_SUMMARY_PATH"
FINAL_DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")

echo "=== ITERATIVE AUDIT COMPLETE ==="
echo "Iterations: $ITERATIONS_USED/$MAX_ITERATIONS (best: $BEST_ITERATION)"
echo "Early stop: $EARLY_STOP ${EARLY_STOP_REASON:+($EARLY_STOP_REASON)}"
echo "Final decision: $FINAL_DECISION (remaining: $REMAINING_SEV)"
```

Display the final audit summary (same display as after Step 3.5).

Proceed to Phase 4: PACK.

---
