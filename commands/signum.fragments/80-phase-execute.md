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

### Step 2.0.6: Codebase Awareness hint context

Use the Bash tool to derive optional Codebase Awareness context before launching the Engineer. Context generation stays non-blocking; reuse decision validation runs after the Engineer returns.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_ENGINEER_PATH="${ARTIFACT_ROOT}contract-engineer.json"

CODEBASE_INDEX_PATH=".signum/cache/codebase-index-v1.json"
STYLE_PROFILE_PATH=".signum/cache/style-profile-v1.json"
IMPLEMENTATION_CONTEXT_PATH="${ARTIFACT_ROOT}implementation_context.json"
REUSE_CANDIDATES_PATH="${ARTIFACT_ROOT}reuse_candidates.json"
REUSE_DECISION_PATH="${ARTIFACT_ROOT}reuse_decision.json"

_POLICY_CODEBASE_MODE=""
_POLICY_CODEBASE_MAX_CANDIDATES=""
if [ -f ".signum/policy.toml" ]; then
  _POLICY_VALUES=$(python3 - ".signum/policy.toml" <<'PY' 2>/dev/null || true
import re
import sys

mode = ""
max_candidates = ""
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
        value = value.strip().strip('"').strip("'")
        key = key.strip()
        if key == "mode":
            mode = value
        elif key == "max_candidates_in_prompt":
            max_candidates = value

print(f"{mode}\t{max_candidates}")
PY
)
  _POLICY_CODEBASE_MODE="${_POLICY_VALUES%%	*}"
  _POLICY_CODEBASE_MAX_CANDIDATES="${_POLICY_VALUES#*	}"
  [ "$_POLICY_CODEBASE_MAX_CANDIDATES" = "$_POLICY_VALUES" ] && _POLICY_CODEBASE_MAX_CANDIDATES=""
fi

CODEBASE_AWARENESS_MODE="${SIGNUM_CODEBASE_AWARENESS:-${_POLICY_CODEBASE_MODE:-off}}"
CODEBASE_MAX_CANDIDATES="${SIGNUM_CODEBASE_MAX_CANDIDATES:-${_POLICY_CODEBASE_MAX_CANDIDATES:-8}}"

case "$CODEBASE_AWARENESS_MODE" in
  off|hint|warn|gate)
    ;;
  *)
    echo "WARNING: invalid SIGNUM_CODEBASE_AWARENESS '$CODEBASE_AWARENESS_MODE'; using off"
    CODEBASE_AWARENESS_MODE="off"
    ;;
esac

case "$CODEBASE_MAX_CANDIDATES" in
  ''|0|*[!0-9]*)
    echo "WARNING: invalid SIGNUM_CODEBASE_MAX_CANDIDATES '$CODEBASE_MAX_CANDIDATES'; using 8"
    CODEBASE_MAX_CANDIDATES="8"
    ;;
esac

if [ "$CODEBASE_AWARENESS_MODE" = "off" ]; then
  echo "Codebase Awareness: off (skipping CODEBASE_RECON and REUSE_MATCH)"
else
  if [ "$CODEBASE_AWARENESS_MODE" = "warn" ] || [ "$CODEBASE_AWARENESS_MODE" = "gate" ]; then
    echo "NOTE: Codebase Awareness $CODEBASE_AWARENESS_MODE will validate $REUSE_DECISION_PATH after the Engineer returns."
  fi

  mkdir -p .signum/cache "$(dirname "$IMPLEMENTATION_CONTEXT_PATH")"

  echo "CODEBASE_RECON: writing $CODEBASE_INDEX_PATH and $STYLE_PROFILE_PATH"
  if python3 scripts/build_codebase_index.py \
    --project-root . \
    --output "$CODEBASE_INDEX_PATH" \
    --style-output "$STYLE_PROFILE_PATH"; then
    echo "CODEBASE_RECON: complete"
    _CODEBASE_RECON_OK=1
  else
    _CODEBASE_RECON_EXIT=$?
    echo "WARNING: CODEBASE_RECON failed with exit $_CODEBASE_RECON_EXIT; continuing EXECUTE without Codebase Awareness hints"
    _CODEBASE_RECON_OK=0
  fi

  if [ "$_CODEBASE_RECON_OK" -eq 1 ]; then
    _MATCHER_ARGS=(
      --project-root .
      --contract "$CONTRACT_PATH"
      --codebase-index "$CODEBASE_INDEX_PATH"
      --style-profile "$STYLE_PROFILE_PATH"
      --output "$REUSE_CANDIDATES_PATH"
      --implementation-context "$IMPLEMENTATION_CONTEXT_PATH"
      --max-candidates "$CODEBASE_MAX_CANDIDATES"
    )
    if [ -f "$CONTRACT_ENGINEER_PATH" ]; then
      _MATCHER_ARGS+=(--contract-engineer "$CONTRACT_ENGINEER_PATH")
    fi

    echo "REUSE_MATCH: writing $IMPLEMENTATION_CONTEXT_PATH and $REUSE_CANDIDATES_PATH"
    if python3 scripts/build_reuse_candidates.py "${_MATCHER_ARGS[@]}"; then
      echo "REUSE_MATCH: complete"
    else
      _REUSE_MATCH_EXIT=$?
      echo "WARNING: REUSE_MATCH failed with exit $_REUSE_MATCH_EXIT; continuing EXECUTE without Codebase Awareness hints"
    fi
  fi
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

### Step 2.1.5: Validate Codebase Awareness reuse decision

Use the Bash tool to validate `reuse_decision.json` after the Engineer returns and before checking execute status. `warn` mode emits warnings only; `gate` mode blocks on missing or invalid reuse decisions.

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
REUSE_CANDIDATES_PATH="${ARTIFACT_ROOT}reuse_candidates.json"
REUSE_DECISION_PATH="${ARTIFACT_ROOT}reuse_decision.json"

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

case "$CODEBASE_AWARENESS_MODE" in
  off)
    echo "Codebase Awareness reuse decision validation: off"
    ;;
  hint)
    if [ -f "$REUSE_DECISION_PATH" ]; then
      echo "REUSE_DECISION: validating optional $REUSE_DECISION_PATH"
      if python3 scripts/validate_reuse_decision.py \
        --contract "$CONTRACT_PATH" \
        --reuse-candidates "$REUSE_CANDIDATES_PATH" \
        --reuse-decision "$REUSE_DECISION_PATH" \
        --mode "$CODEBASE_AWARENESS_MODE"; then
        echo "REUSE_DECISION: valid"
      else
        _REUSE_DECISION_EXIT=$?
        echo "WARNING: optional REUSE_DECISION validation failed with exit $_REUSE_DECISION_EXIT; continuing because mode is hint"
      fi
    else
      echo "Codebase Awareness: hint mode and no reuse_decision.json found; skipping validation"
    fi
    ;;
  warn)
    echo "REUSE_DECISION: validating $REUSE_DECISION_PATH for warn mode"
    if python3 scripts/validate_reuse_decision.py \
      --contract "$CONTRACT_PATH" \
      --reuse-candidates "$REUSE_CANDIDATES_PATH" \
      --reuse-decision "$REUSE_DECISION_PATH" \
      --mode "$CODEBASE_AWARENESS_MODE"; then
      echo "REUSE_DECISION: valid"
    else
      _REUSE_DECISION_EXIT=$?
      echo "WARNING: REUSE_DECISION validation failed with exit $_REUSE_DECISION_EXIT; continuing because mode is warn"
    fi
    ;;
  gate)
    echo "REUSE_DECISION: validating $REUSE_DECISION_PATH for gate mode"
    if python3 scripts/validate_reuse_decision.py \
      --contract "$CONTRACT_PATH" \
      --reuse-candidates "$REUSE_CANDIDATES_PATH" \
      --reuse-decision "$REUSE_DECISION_PATH" \
      --mode "$CODEBASE_AWARENESS_MODE"; then
      echo "REUSE_DECISION: valid"
    else
      _REUSE_DECISION_EXIT=$?
      echo "ERROR: REUSE_DECISION validation failed with exit $_REUSE_DECISION_EXIT; Codebase Awareness gate mode blocks EXECUTE"
      exit "$_REUSE_DECISION_EXIT"
    fi
    ;;
esac
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
