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

