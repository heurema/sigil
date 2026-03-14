#!/usr/bin/env bash
# contract-dir.sh — per-contract directory management for Signum
# Functions: contract_dir, init_contract_dir, register_contract,
#            update_contract_status, get_active_contract, current_contract_dir
#
# Requires: jq, bash 4.0+, standard POSIX utils

# contract_dir <contractId>
# Returns the path for a contract's isolated directory.
contract_dir() {
  local contract_id="${1:-}"
  if [[ -z "$contract_id" ]]; then
    echo "contract_dir: contractId required" >&2
    return 1
  fi
  # Reject path traversal characters
  if [[ "$contract_id" == */* || "$contract_id" == *..* ]]; then
    echo "contract_dir: invalid contractId (path traversal rejected)" >&2
    return 1
  fi
  echo ".signum/contracts/${contract_id}/"
}

# init_contract_dir <contractId>
# Creates the directory structure for a contract, including a reviews/ subdirectory.
init_contract_dir() {
  local contract_id="${1:-}"
  if [[ -z "$contract_id" ]]; then
    echo "init_contract_dir: contractId required" >&2
    return 1
  fi
  local dir
  dir=$(contract_dir "$contract_id")
  mkdir -p "${dir}reviews"
  echo "Initialized contract directory: ${dir}"
}

# _ensure_index
# Creates .signum/contracts/index.json if it does not exist.
_ensure_index() {
  local index=".signum/contracts/index.json"
  mkdir -p ".signum/contracts"
  if [[ ! -f "$index" ]]; then
    echo '{"activeContractId":null,"contracts":[]}' > "$index"
  fi
}

# register_contract <contractId> <contract_status>
# Adds or updates an entry in .signum/contracts/index.json.
# Sets activeContractId to this contract.
register_contract() {
  local contract_id="${1:-}"
  local contract_status="${2:-draft}"
  if [[ -z "$contract_id" ]]; then
    echo "register_contract: contractId required" >&2
    return 1
  fi

  _ensure_index

  local index=".signum/contracts/index.json"
  local dir
  dir=$(contract_dir "$contract_id")
  local created_at
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Add or update entry; also set activeContractId
  jq --arg id "$contract_id" \
     --arg st "$contract_status" \
     --arg dir "$dir" \
     --arg ts "$created_at" \
     '
     .activeContractId = $id |
     if any(.contracts[]; .contractId == $id) then
       .contracts = [.contracts[] |
         if .contractId == $id then
           . + {status: $st, directory: $dir}
         else . end]
     else
       .contracts += [{contractId: $id, status: $st, createdAt: $ts, directory: $dir}]
     end
     ' "$index" > "${index}.tmp" && mv "${index}.tmp" "$index"

  echo "Registered contract ${contract_id} (status=${contract_status}) in ${index}"
}

# update_contract_status <contractId> <newStatus>
# Modifies the status field for an existing contract in index.json.
update_contract_status() {
  local contract_id="${1:-}"
  local new_status="${2:-}"
  if [[ -z "$contract_id" || -z "$new_status" ]]; then
    echo "update_contract_status: contractId and newStatus required" >&2
    return 1
  fi

  local index=".signum/contracts/index.json"
  if [[ ! -f "$index" ]]; then
    echo "update_contract_status: index.json not found" >&2
    return 1
  fi

  # Check if contractId exists in index
  local exists
  exists=$(jq --arg id "$contract_id" 'any(.contracts[]; .contractId == $id)' "$index")
  if [[ "$exists" != "true" ]]; then
    echo "update_contract_status: contractId '${contract_id}' not found in index" >&2
    return 1
  fi

  jq --arg id "$contract_id" --arg st "$new_status" \
     '.contracts = [.contracts[] |
       if .contractId == $id then . + {status: $st} else . end]' \
     "$index" > "${index}.tmp" && mv "${index}.tmp" "$index"

  echo "Updated contract ${contract_id} status to ${new_status}"
}

# get_active_contract
# Reads and returns the activeContractId from index.json.
get_active_contract() {
  local index=".signum/contracts/index.json"
  if [[ ! -f "$index" ]]; then
    echo "get_active_contract: index.json not found" >&2
    return 1
  fi
  jq -r '.activeContractId // empty' "$index"
}

# current_contract_dir
# Returns the directory path for the currently active contract.
current_contract_dir() {
  local active
  active=$(get_active_contract)
  if [[ -z "$active" ]]; then
    echo "current_contract_dir: no active contract in index.json" >&2
    return 1
  fi
  contract_dir "$active"
}
