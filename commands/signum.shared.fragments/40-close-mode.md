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

