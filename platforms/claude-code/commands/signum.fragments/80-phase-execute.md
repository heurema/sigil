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

# Set run_id for receipt chain and capture pre-execute snapshot
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
  echo "ERROR: snapshot-tree.sh not found in Signum plugin directories — receipt chain cannot be disabled" >&2
  exit 1
fi
bash "$_SIGNUM_SNAPSHOT" execute-attempt-01 --workspace-root "$PWD" --signum-dir "$ARTIFACT_ROOT"
echo "Pre-execute snapshot captured"
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

python3 - "$CONTRACT_PATH" <<'PY'
import json, subprocess
import sys

contract_path = sys.argv[1]
changed = subprocess.run(['git', 'diff', '--name-only'], capture_output=True, text=True).stdout.strip().split('\n')
changed = [f for f in changed if f]
with open(contract_path) as f:
    contract = json.load(f)
in_scope = contract.get('inScope', [])
allow_new = contract.get('allowNewFilesUnder', [])

violations = []
for file in changed:
    match = False
    # Exact match against inScope
    if file in in_scope:
        match = True
    else:
        # Prefix match against allowNewFilesUnder
        for prefix in allow_new:
            if file.startswith(prefix):
                match = True
                break
    if not match:
        violations.append(file)

if violations:
    print('SCOPE VIOLATION: files outside inScope modified:')
    for v in violations:
        print(f'  {v}')
    print('Pipeline stopped. Fix scope in contract or revert changes.')
    exit(1)
else:
    print(f'Scope check: PASS ({len(changed)} files, all within inScope)')
PY
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

Use the Bash tool to verify all non-glob `inScope` paths exist after the engineer ran. This catches the class of failure where files were promised but never created:

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
  echo "ERROR: boundary-verifier.sh not found in Signum plugin directories" >&2
  exit 1
fi
bash "$_SIGNUM_BOUNDARY" execute \
  --workspace-root "$PWD" \
  --signum-dir "$ARTIFACT_ROOT" \
  --contract "$CONTRACT_ENGINEER_PATH" \
  --contract-full "$CONTRACT_PATH" \
  --execution-context "$EXECUTION_CONTEXT_PATH" \
  --snapshot "$SNAPSHOT_PATH"
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
  echo "ERROR: transition-verifier.sh not found in Signum plugin directories" >&2
  exit 1
fi
bash "$_SIGNUM_TRANSITION" execute audit \
  --workspace-root "$PWD" \
  --signum-dir "$ARTIFACT_ROOT" \
  --contract "$CONTRACT_ENGINEER_PATH" \
  --contract-full "$CONTRACT_PATH" \
  --snapshot "$SNAPSHOT_PATH"
```

If transition verifier exits non-zero, **STOP**. Do not proceed to Phase 3.

---

