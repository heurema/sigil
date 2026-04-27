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

