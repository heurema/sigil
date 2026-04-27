#!/usr/bin/env bash
# contract-dir.sh — per-contract directory management for Signum
# Functions: new_contract_id, contract_dir, init_contract_dir,
#            sync_contract_artifacts, register_contract, set_active_contract,
#            clear_active_contract, update_contract_status,
#            get_active_contract, get_contract_status,
#            describe_active_contract_state,
#            active_artifact_root, active_artifact_path,
#            reset_canonical_active_artifact,
#            verify_canonical_contract_artifacts,
#            link_active_artifact, ensure_active_artifact_dir,
#            remove_root_artifact_view, archive_contract_artifacts,
#            purge_root_working_set_views, reset_active_artifact,
#            promote_root_artifact_to_active, current_contract_dir
#
# Requires: jq, bash 4.0+, standard POSIX utils

# === Neutral/shared helpers ===

# _random_hex4
# Returns 4 lowercase hex chars.
_random_hex4() {
  if command -v od >/dev/null 2>&1; then
    od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    printf '%04x' "$((RANDOM % 65536))"
  fi
}

# new_contract_id
# Returns a canonical contract id for a new run.
new_contract_id() {
  printf 'sig-%s-%s\n' "$(date -u +%Y%m%d-%H%M)" "$(_random_hex4)"
}

# _relative_path <target> <from_dir>
# Returns a relative path from from_dir to target.
_relative_path() {
  local target="${1:-}"
  local from_dir="${2:-}"
  if [[ -z "$target" || -z "$from_dir" ]]; then
    echo "_relative_path: target and from_dir required" >&2
    return 1
  fi
  python3 - "$target" "$from_dir" <<'PY'
import os
import sys

target = sys.argv[1]
from_dir = sys.argv[2]
print(os.path.relpath(target, from_dir))
PY
}

# _realpath_or_self <path>
# Returns the normalized absolute path, resolving symlinks where possible.
_realpath_or_self() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    echo "_realpath_or_self: path required" >&2
    return 1
  fi
  python3 - "$path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

# _remove_artifact_path <path>
# Removes a file, symlink, or directory path without following symlinked dirs.
_remove_artifact_path() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    echo "_remove_artifact_path: path required" >&2
    return 1
  fi
  if [[ -L "$path" ]]; then
    rm -f "$path"
  elif [[ -d "$path" ]]; then
    rm -rf "$path"
  elif [[ -e "$path" ]]; then
    rm -f "$path"
  fi
}

# === Canonical contract artifact helpers ===

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
# Creates the directory structure for a contract's durable snapshot/history.
init_contract_dir() {
  local contract_id="${1:-}"
  if [[ -z "$contract_id" ]]; then
    echo "init_contract_dir: contractId required" >&2
    return 1
  fi
  local dir
  dir=$(contract_dir "$contract_id") || return 1
  mkdir -p "${dir}"
  echo "Initialized contract directory: ${dir}"
}

# verify_canonical_contract_artifacts <contractId> <path...>
# Canonical-only PACK finalization check. Reports artifact presence under the
# contract root without importing or materializing root compatibility views.
# Missing artifacts are non-fatal to preserve legacy sync's no-op behavior for
# missing root sources.
verify_canonical_contract_artifacts() {
  local contract_id="${1:-}"
  shift || true
  if [[ -z "$contract_id" ]]; then
    echo "verify_canonical_contract_artifacts: contractId required" >&2
    return 1
  fi
  if [[ "$#" -eq 0 ]]; then
    echo "verify_canonical_contract_artifacts: at least one artifact path required" >&2
    return 1
  fi

  local dir
  dir=$(contract_dir "$contract_id") || return 1
  mkdir -p "$dir"

  local rel path present=0 total=0
  local missing_paths=()
  for rel in "$@"; do
    if [[ -z "$rel" ]]; then
      continue
    fi
    if [[ "$rel" == /* || "$rel" == "." || "$rel" == ./* || "$rel" == *..* ]]; then
      echo "verify_canonical_contract_artifacts: invalid relative path" >&2
      return 1
    fi
    total=$((total + 1))
    path="${dir}${rel}"
    if [[ -e "$path" || -L "$path" ]]; then
      present=$((present + 1))
    else
      missing_paths+=("$rel")
    fi
  done

  if [[ "$total" -eq 0 ]]; then
    echo "verify_canonical_contract_artifacts: at least one non-empty artifact path required" >&2
    return 1
  fi

  echo "Verified ${present}/${total} canonical artifact(s) in ${dir}"
  if [[ "${#missing_paths[@]}" -gt 0 ]]; then
    printf 'Missing canonical artifact(s):'
    for rel in "${missing_paths[@]}"; do
      printf ' %s' "$rel"
    done
    printf '\n'
  fi
}

# === Legacy root artifact compatibility layer ===
# Compatibility/migration-only helpers below expose, import, or remove root
# .signum working-set views while preserving the canonical contract root.
# Do not use these helpers for new normal-runtime artifact writes.

# sync_contract_artifacts <contractId> <path...>
# LEGACY_ROOT_COMPAT: syncs selected root working-set views into the
# contract's durable directory, preserving relative subpaths.
sync_contract_artifacts() {
  local contract_id="${1:-}"
  shift || true
  if [[ -z "$contract_id" ]]; then
    echo "sync_contract_artifacts: contractId required" >&2
    return 1
  fi
  if [[ "$#" -eq 0 ]]; then
    echo "sync_contract_artifacts: at least one artifact path required" >&2
    return 1
  fi

  local dir
  dir=$(contract_dir "$contract_id") || return 1
  mkdir -p "$dir"

  local rel src dst src_real dst_real copied=0
  for rel in "$@"; do
    if [[ -z "$rel" ]]; then
      continue
    fi
    src=".signum/${rel}"
    if [[ ! -e "$src" ]]; then
      continue
    fi
    dst="${dir}${rel}"
    src_real=$(_realpath_or_self "$src")
    dst_real=$(_realpath_or_self "$dst")
    if [[ "$src_real" == "$dst_real" ]]; then
      continue
    fi
    if [[ -d "$src" ]]; then
      mkdir -p "$dst"
      cp -R "$src"/. "$dst"/
    else
      mkdir -p "$(dirname "$dst")"
      cp -R "$src" "$dst"
    fi
    copied=$((copied + 1))
  done

  echo "Synced ${copied} artifact(s) to ${dir}"
}

# === Canonical contract registry and active-root helpers ===

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
# Does not change activeContractId; callers must set that explicitly.
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

  # Extract goal, inScope, assumptions from contract.json if available
  local contract_file="${dir}contract.json"
  local goal_arg="" inscope_arg="" assumptions_arg=""
  if [[ -f "$contract_file" ]]; then
    goal_arg=$(jq -r '.goal // empty' "$contract_file" 2>/dev/null || true)
    inscope_arg=$(jq -c '.inScope // []' "$contract_file" 2>/dev/null || echo '[]')
    assumptions_arg=$(jq -c '[(.assumptions // [])[] | .text // .]' "$contract_file" 2>/dev/null || echo '[]')
  fi

  # Add or update entry
  jq --arg id "$contract_id" \
     --arg st "$contract_status" \
     --arg dir "$dir" \
     --arg ts "$created_at" \
     --arg goal "$goal_arg" \
     --argjson inscope "${inscope_arg:-[]}" \
     --argjson assumptions "${assumptions_arg:-[]}" \
     '
     if any(.contracts[]; .contractId == $id) then
       .contracts = [.contracts[] |
         if .contractId == $id then
           . + {status: $st, directory: $dir, goal: $goal, inScope: $inscope, assumptions: $assumptions}
         else . end]
     else
       .contracts += [{contractId: $id, status: $st, createdAt: $ts, directory: $dir, goal: $goal, inScope: $inscope, assumptions: $assumptions}]
     end
     ' "$index" > "${index}.tmp" && mv "${index}.tmp" "$index"

  echo "Registered contract ${contract_id} (status=${contract_status}) in ${index}"
}

# set_active_contract <contractId>
# Updates activeContractId for an already-registered contract.
set_active_contract() {
  local contract_id="${1:-}"
  if [[ -z "$contract_id" ]]; then
    echo "set_active_contract: contractId required" >&2
    return 1
  fi

  _ensure_index

  local index=".signum/contracts/index.json"
  local exists
  exists=$(jq --arg id "$contract_id" 'any(.contracts[]; .contractId == $id)' "$index")
  if [[ "$exists" != "true" ]]; then
    echo "set_active_contract: contractId '${contract_id}' not found in index" >&2
    return 1
  fi

  jq --arg id "$contract_id" '.activeContractId = $id' \
    "$index" > "${index}.tmp" && mv "${index}.tmp" "$index"

  echo "Set active contract to ${contract_id}"
}

# clear_active_contract
# Clears activeContractId in index.json.
clear_active_contract() {
  _ensure_index

  local index=".signum/contracts/index.json"
  jq '.activeContractId = null' \
    "$index" > "${index}.tmp" && mv "${index}.tmp" "$index"

  echo "Cleared active contract"
}

# _is_terminal_status <status>
# Returns success for statuses that must clear activeContractId immediately.
# `completed` intentionally stays active until an explicit archive/close/finalize step.
_is_terminal_status() {
  case "${1:-}" in
    archived|closed|superseded)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# _is_resumable_status <status>
# Returns success for statuses that may remain active/resumable.
_is_resumable_status() {
  case "${1:-}" in
    draft|active|approved|executing|auditing|human_review|blocked)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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

  local active
  active=$(jq -r '.activeContractId // empty' "$index")
  if [[ "$active" == "$contract_id" ]] && _is_terminal_status "$new_status"; then
    clear_active_contract >/dev/null
  fi

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

# get_contract_status <contractId>
# Reads and returns the status for a contract in index.json.
get_contract_status() {
  local contract_id="${1:-}"
  if [[ -z "$contract_id" ]]; then
    echo "get_contract_status: contractId required" >&2
    return 1
  fi

  local index=".signum/contracts/index.json"
  if [[ ! -f "$index" ]]; then
    echo "get_contract_status: index.json not found" >&2
    return 1
  fi

  local status
  status=$(jq -r --arg id "$contract_id" '.contracts[] | select(.contractId == $id) | .status // empty' "$index")
  if [[ -z "$status" ]]; then
    echo "get_contract_status: contractId '${contract_id}' not found in index" >&2
    return 1
  fi

  printf '%s\n' "$status"
}

# describe_active_contract_state
# Emits JSON describing the current active/resumable contract state.
describe_active_contract_state() {
  local state="NONE"
  local active=""
  local status=""
  local root=""

  active=$(get_active_contract 2>/dev/null || true)
  if [[ -n "$active" ]]; then
    status=$(get_contract_status "$active" 2>/dev/null || true)
    root=$(contract_dir "$active" 2>/dev/null || true)

    if [[ -z "$root" ]]; then
      clear_active_contract >/dev/null 2>&1 || true
      active=""
      status=""
    elif [[ -n "$status" ]] && ! _is_resumable_status "$status"; then
      clear_active_contract >/dev/null 2>&1 || true
      active=""
      status=""
      root=""
    elif [[ -f "${root}contract.json" && -f "${root}execution_context.json" ]]; then
      state="RESUMABLE"
    elif [[ -f "${root}contract.json" ]]; then
      state="CONTRACT_ONLY"
    else
      clear_active_contract >/dev/null 2>&1 || true
      active=""
      status=""
      root=""
    fi
  fi

  jq -n \
    --arg state "$state" \
    --arg contract_id "$active" \
    --arg status "$status" \
    --arg artifact_root "$root" \
    '{
      state: $state,
      contractId: (if $contract_id == "" then null else $contract_id end),
      status: (if $status == "" then null else $status end),
      artifactRoot: (if $artifact_root == "" then null else $artifact_root end)
    }'
}

# active_artifact_root
# Returns the canonical artifact root for the currently active contract.
active_artifact_root() {
  local active
  active=$(get_active_contract)
  if [[ -z "$active" ]]; then
    echo "active_artifact_root: no active contract in index.json" >&2
    return 1
  fi
  contract_dir "$active"
}

# active_artifact_path <relative_path>
# Returns the path for an artifact under the active contract root.
active_artifact_path() {
  local rel="${1:-}"
  if [[ -z "$rel" ]]; then
    echo "active_artifact_path: relative path required" >&2
    return 1
  fi
  local root
  root=$(active_artifact_root) || return 1
  printf '%s%s\n' "$root" "$rel"
}

# reset_canonical_active_artifact <relative_path> [file|dir]
# Canonical-only reset for an artifact under the active contract root.
# Does not touch root .signum/<artifact> compatibility views.
reset_canonical_active_artifact() {
  local rel="${1:-}"
  local kind="${2:-file}"
  if [[ -z "$rel" ]]; then
    echo "reset_canonical_active_artifact: relative path required" >&2
    return 1
  fi
  if [[ "$rel" == /* || "$rel" == "." || "$rel" == ./* || "$rel" == *..* ]]; then
    echo "reset_canonical_active_artifact: invalid relative path" >&2
    return 1
  fi

  case "$kind" in
    file|dir)
      ;;
    *)
      echo "reset_canonical_active_artifact: kind must be file or dir" >&2
      return 1
      ;;
  esac

  local active_path
  active_path=$(active_artifact_path "$rel") || return 1

  _remove_artifact_path "$active_path"

  case "$kind" in
    file)
      mkdir -p "$(dirname "$active_path")"
      ;;
    dir)
      mkdir -p "$active_path"
      ;;
  esac

  echo "Reset canonical active artifact: ${active_path} (${kind})"
}

# === Legacy root artifact compatibility layer (continued) ===

# remove_root_artifact_view <relative_path>
# LEGACY_ROOT_COMPAT: cleans only the root compatibility view for an artifact.
remove_root_artifact_view() {
  local rel="${1:-}"
  if [[ -z "$rel" ]]; then
    echo "remove_root_artifact_view: relative path required" >&2
    return 1
  fi

  local root_path=".signum/${rel}"
  _remove_artifact_path "$root_path"

  echo "Removed root artifact view: ${root_path}"
}

# === Canonical archive helpers ===

# archive_contract_artifacts <contractId> <archive_dir>
# Copies archive-worthy canonical artifacts for a contract into archive_dir.
archive_contract_artifacts() {
  local contract_id="${1:-}"
  local archive_dir="${2:-}"
  if [[ -z "$contract_id" || -z "$archive_dir" ]]; then
    echo "archive_contract_artifacts: contractId and archive_dir required" >&2
    return 1
  fi

  local dir
  dir=$(contract_dir "$contract_id") || return 1
  if [[ ! -d "$dir" ]]; then
    echo "archive_contract_artifacts: contract directory not found: ${dir}" >&2
    return 1
  fi

  mkdir -p "$archive_dir"

  local rel copied=0
  for rel in \
    contract.json \
    proofpack.json \
    approval.json \
    audit_summary.json \
    anti_entropy_report.json \
    execution_context.json \
    reconcile_report.json \
    retro.json; do
    if [[ -f "${dir}${rel}" ]]; then
      cp "${dir}${rel}" "$archive_dir/"
      copied=$((copied + 1))
    fi
  done

  for rel in receipts runs snapshots; do
    if [[ -d "${dir}${rel}" ]]; then
      mkdir -p "${archive_dir}/${rel}"
      cp -R "${dir}${rel}/." "${archive_dir}/${rel}/"
      copied=$((copied + 1))
    fi
  done

  echo "Archived ${copied} contract artifact(s) from ${dir} to ${archive_dir}"
}

# === Legacy root artifact compatibility layer (continued) ===

# purge_root_working_set_views
# LEGACY_ROOT_COMPAT: cleans the root compatibility surface for the active
# working set.
purge_root_working_set_views() {
  local rel
  for rel in \
    contract.json \
    contract-engineer.json \
    contract-policy.json \
    execute_log.json \
    combined.patch \
    iteration_delta.patch \
    baseline.json \
    mechanic_report.json \
    holdout_report.json \
    audit_summary.json \
    proofpack.json \
    approval.json \
    anti_entropy_report.json \
    policy_violations.json \
    policy_scan.json \
    spec_quality.json \
    spec_validation.json \
    repo_contract_baseline.json \
    repo_contract_violations.json \
    contract-hash.txt \
    execution_context.json \
    review_prompt_codex.txt \
    review_prompt_gemini.txt \
    review_context.json \
    clover_report.json \
    intent_check.json \
    audit_iteration_log.json \
    repair_brief.json \
    flaky_tests.json \
    reconcile_report.json \
    retro.json; do
    remove_root_artifact_view "$rel" >/dev/null 2>&1 || true
  done

  for rel in reviews iterations receipts runs snapshots; do
    remove_root_artifact_view "$rel" >/dev/null 2>&1 || true
  done

  echo "Purged root working set views"
}

# link_active_artifact <relative_path>
# LEGACY_ROOT_COMPAT: links a root compatibility view to the active contract
# artifact.
link_active_artifact() {
  local rel="${1:-}"
  if [[ -z "$rel" ]]; then
    echo "link_active_artifact: relative path required" >&2
    return 1
  fi

  local root_path=".signum/${rel}"
  local active_path
  active_path=$(active_artifact_path "$rel") || return 1

  mkdir -p "$(dirname "$root_path")" "$(dirname "$active_path")"

  if [[ -e "$root_path" || -L "$root_path" ]]; then
    remove_root_artifact_view "$rel" >/dev/null
  fi

  local link_target
  link_target=$(_relative_path "$active_path" "$(dirname "$root_path")")
  ln -s "$link_target" "$root_path"

  echo "Linked ${root_path} -> ${active_path}"
}

# ensure_active_artifact_dir <relative_path>
# LEGACY_ROOT_COMPAT: ensures a canonical directory exists, then exposes it
# through a root compatibility view.
ensure_active_artifact_dir() {
  local rel="${1:-}"
  if [[ -z "$rel" ]]; then
    echo "ensure_active_artifact_dir: relative path required" >&2
    return 1
  fi

  local active_path
  active_path=$(active_artifact_path "$rel") || return 1
  mkdir -p "$active_path"
  link_active_artifact "$rel" >/dev/null

  echo "Ensured active artifact dir: ${active_path}"
}

# reset_active_artifact <relative_path> [file|dir]
# LEGACY_ROOT_COMPAT: clears both the root compatibility view and the
# canonical active artifact. For dir artifacts, recreates only the canonical
# active directory.
reset_active_artifact() {
  local rel="${1:-}"
  local kind="${2:-file}"
  if [[ -z "$rel" ]]; then
    echo "reset_active_artifact: relative path required" >&2
    return 1
  fi

  local active_path
  active_path=$(active_artifact_path "$rel") || return 1

  remove_root_artifact_view "$rel" >/dev/null
  _remove_artifact_path "$active_path"

  case "$kind" in
    file)
      mkdir -p "$(dirname "$active_path")"
      ;;
    dir)
      mkdir -p "$active_path"
      ;;
    *)
      echo "reset_active_artifact: kind must be file or dir" >&2
      return 1
      ;;
  esac

  echo "Reset active artifact: ${active_path} (${kind})"
}

# promote_root_artifact_to_active <relative_path>
# LEGACY_ROOT_COMPAT: promotes an existing root artifact into the active
# contract dir. This one-time import helper does not recreate a root view.
promote_root_artifact_to_active() {
  local rel="${1:-}"
  if [[ -z "$rel" ]]; then
    echo "promote_root_artifact_to_active: relative path required" >&2
    return 1
  fi

  local root_path=".signum/${rel}"
  local active_path
  active_path=$(active_artifact_path "$rel") || return 1

  mkdir -p "$(dirname "$root_path")" "$(dirname "$active_path")"

  if [[ -L "$root_path" ]]; then
    rm -f "$root_path"
  elif [[ -d "$root_path" ]]; then
    mkdir -p "$active_path"
    cp -R "$root_path"/. "$active_path"/
    rm -rf "$root_path"
  elif [[ -e "$root_path" ]]; then
    if [[ -e "$active_path" ]]; then
      cp -f "$root_path" "$active_path"
      rm -f "$root_path"
    else
      mv "$root_path" "$active_path"
    fi
  fi

  echo "Promoted ${root_path} -> ${active_path}"
}

# current_contract_dir
# Backward-compatible alias for active_artifact_root.
current_contract_dir() {
  active_artifact_root
}
