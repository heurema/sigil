#!/usr/bin/env bash
# transition-verifier.sh -- deterministic receipt-chain gate between Signum phases.
#
# Usage:
#   transition-verifier.sh <from_phase> <to_phase> [options]
#
# Options:
#   --workspace-root PATH
#   --signum-dir PATH           Signum artifact dir (default: active contract root from .signum/contracts/index.json, else .signum)
#   --contract PATH
#   --receipt PATH
#   --snapshot PATH
set -euo pipefail
export LC_ALL=C

FROM_PHASE="${1:-}"
TO_PHASE="${2:-}"
shift 2 || true

if [[ -z "$FROM_PHASE" || -z "$TO_PHASE" ]]; then
  echo "Usage: transition-verifier.sh <from_phase> <to_phase> [options]" >&2
  exit 1
fi

WORKSPACE_ROOT="$PWD"
SIGNUM_DIR=""
CONTRACT_ENGINEER=""
CONTRACT_FULL=""
RECEIPT_PATH=""
SNAPSHOT_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root)
      WORKSPACE_ROOT="$2"
      shift 2
      ;;
    --signum-dir)
      SIGNUM_DIR="$2"
      shift 2
      ;;
    --contract)
      CONTRACT_ENGINEER="$2"
      shift 2
      ;;
    --contract-full)
      CONTRACT_FULL="$2"
      shift 2
      ;;
    --receipt)
      RECEIPT_PATH="$2"
      shift 2
      ;;
    --snapshot)
      SNAPSHOT_JSON="$2"
      shift 2
      ;;
    *)
      echo "transition-verifier.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "transition-verifier.sh: jq not found" >&2
  exit 1
fi

resolve_default_signum_dir() {
  local workspace_root="$1"
  local index_path="$workspace_root/.signum/contracts/index.json"
  local active_id=""

  if [[ -f "$index_path" ]]; then
    active_id="$(jq -r '.activeContractId // empty' "$index_path" 2>/dev/null || true)"
    if [[ -n "$active_id" && -d "$workspace_root/.signum/contracts/$active_id" ]]; then
      printf '%s\n' "$workspace_root/.signum/contracts/$active_id"
      return 0
    fi
  fi

  printf '%s\n' "$workspace_root/.signum"
}

hash_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "transition-verifier.sh: no sha256 tool found" >&2
    exit 1
  fi
}

ABS_WORKSPACE=$(CDPATH= cd "$WORKSPACE_ROOT" && pwd)
if [[ -z "$SIGNUM_DIR" ]]; then
  SIGNUM_DIR="$(resolve_default_signum_dir "$ABS_WORKSPACE")"
fi
if [[ "$SIGNUM_DIR" = /* ]]; then
  ABS_SIGNUM_DIR="$SIGNUM_DIR"
else
  ABS_SIGNUM_DIR="$ABS_WORKSPACE/$SIGNUM_DIR"
fi
CONTRACT_ENGINEER="${CONTRACT_ENGINEER:-$ABS_SIGNUM_DIR/contract-engineer.json}"
CONTRACT_FULL="${CONTRACT_FULL:-$ABS_SIGNUM_DIR/contract.json}"
RECEIPT_PATH="${RECEIPT_PATH:-$ABS_SIGNUM_DIR/receipts/${FROM_PHASE}.json}"
SNAPSHOT_JSON="${SNAPSHOT_JSON:-$ABS_SIGNUM_DIR/snapshots/pre-execute.json}"

for required in "$CONTRACT_ENGINEER" "$CONTRACT_FULL" "$RECEIPT_PATH"; do
  if [[ ! -f "$required" ]]; then
    echo "BLOCK: missing required file: $required" >&2
    exit 1
  fi
done

RUN_ID=$(jq -r '.run_id // empty' "$ABS_SIGNUM_DIR/execution_context.json" 2>/dev/null || true)
RUN_ID_FROM_RECEIPT=$(jq -r '.run_id // empty' "$RECEIPT_PATH")
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$RUN_ID_FROM_RECEIPT"
fi
RUN_DIR="$ABS_SIGNUM_DIR/runs/$RUN_ID"

CURRENT_CONTRACT_HASH="sha256:$(hash_file "$CONTRACT_FULL")"
RECEIPT_CONTRACT_HASH=$(jq -r '.contract_hash // empty' "$RECEIPT_PATH")
if [[ "$CURRENT_CONTRACT_HASH" != "$RECEIPT_CONTRACT_HASH" ]]; then
  echo "BLOCK: contract hash mismatch" >&2
  exit 1
fi

RECEIPT_STATUS=$(jq -r '.status // ""' "$RECEIPT_PATH")
if [[ "$RECEIPT_STATUS" != "PASS" ]]; then
  echo "BLOCK: receipt status is $RECEIPT_STATUS, expected PASS" >&2
  exit 1
fi

if [[ -f "$SNAPSHOT_JSON" ]]; then
  SNAPSHOT_TREE_HASH=$(jq -r '.tree_hash // empty' "$SNAPSHOT_JSON")
  RECEIPT_TREE_HASH=$(jq -r '.base_tree_hash // empty' "$RECEIPT_PATH")
  if [[ -n "$SNAPSHOT_TREE_HASH" && "$SNAPSHOT_TREE_HASH" != "$RECEIPT_TREE_HASH" ]]; then
    echo "BLOCK: snapshot tree hash mismatch" >&2
    exit 1
  fi
fi

# Validate append-only chain integrity for this phase.
if [[ -d "$RUN_DIR" ]]; then
  prev_hash=""
  prev_file=""
  while IFS= read -r file; do
    current_hash="sha256:$(hash_file "$file")"
    parent_hash=$(jq -r '.parent_receipt_hash // empty' "$file")
    if [[ -n "$prev_hash" && "$parent_hash" != "$prev_hash" ]]; then
      echo "BLOCK: broken receipt chain between $prev_file and $file" >&2
      exit 1
    fi
    prev_hash="$current_hash"
    prev_file="$file"
  done < <(find "$RUN_DIR" -maxdepth 1 -type f -name "${FROM_PHASE}-*.json" | sort)
fi

# Artifact integrity check.
mapfile -t ARTIFACTS < <(jq -r '.output_artifacts[]? // empty' "$RECEIPT_PATH")
for artifact in "${ARTIFACTS[@]}"; do
  [[ -z "$artifact" ]] && continue
  artifact_path="$ABS_SIGNUM_DIR/$artifact"
  if [[ ! -f "$artifact_path" ]]; then
    echo "BLOCK: missing artifact $artifact" >&2
    exit 1
  fi
  expected=$(jq -r --arg a "$artifact" '.output_hashes[$a] // empty' "$RECEIPT_PATH")
  actual="sha256:$(hash_file "$artifact_path")"
  if [[ "$expected" != "$actual" ]]; then
    echo "BLOCK: artifact hash mismatch for $artifact" >&2
    exit 1
  fi
done

# Scope integrity.
OUT_OF_SCOPE_COUNT=$(jq '.scope_check.out_of_scope | length' "$RECEIPT_PATH")
if [[ "$OUT_OF_SCOPE_COUNT" -gt 0 ]]; then
  echo "BLOCK: receipt records out-of-scope changes" >&2
  exit 1
fi
MISSING_SCOPE_COUNT=$(jq '.scope_check.missing_in_scope | length' "$RECEIPT_PATH")
if [[ "$MISSING_SCOPE_COUNT" -gt 0 ]]; then
  echo "BLOCK: receipt records missing inScope paths" >&2
  exit 1
fi

# Acceptance-criteria evidence completeness.
RISK_LEVEL=$(jq -r '.riskLevel // "medium"' "$CONTRACT_FULL")
TOTAL_VISIBLE=$(jq '[.acceptanceCriteria[] | select((.visibility // "visible") != "holdout")] | length' "$CONTRACT_ENGINEER")
TOTAL_EVIDENCED=$(jq '.ac_evidence | length' "$RECEIPT_PATH")
if [[ "$TOTAL_VISIBLE" -ne "$TOTAL_EVIDENCED" ]]; then
  echo "BLOCK: AC evidence count mismatch ($TOTAL_EVIDENCED/$TOTAL_VISIBLE)" >&2
  exit 1
fi

while IFS= read -r ac_id; do
  [[ -z "$ac_id" ]] && continue
  if ! jq -e --arg id "$ac_id" '.ac_evidence | has($id)' "$RECEIPT_PATH" >/dev/null 2>&1; then
    echo "BLOCK: missing evidence for $ac_id" >&2
    exit 1
  fi
  exit_code=$(jq -r --arg id "$ac_id" '.ac_evidence[$id].verify_exit_code // 999' "$RECEIPT_PATH")
  if [[ "$exit_code" != "0" ]]; then
    echo "BLOCK: evidence for $ac_id failed with exit $exit_code" >&2
    exit 1
  fi
  verify_format=$(jq -r --arg id "$ac_id" '.ac_evidence[$id].verify_format // ""' "$RECEIPT_PATH")
  if [[ "$verify_format" != "dsl" ]]; then
    echo "BLOCK: unsupported verify format for $ac_id" >&2
    exit 1
  fi
  vacuous=$(jq -r --arg id "$ac_id" '.ac_evidence[$id].vacuous // false' "$RECEIPT_PATH")
  strength=$(jq -r --arg id "$ac_id" '.ac_evidence[$id].verify_strength // ""' "$RECEIPT_PATH")
  if [[ "$vacuous" == "true" || "$strength" == "exit_only" ]]; then
    if [[ "$RISK_LEVEL" != "low" ]]; then
      echo "BLOCK: vacuous evidence for $ac_id" >&2
      exit 1
    fi
  fi
done < <(jq -r '.acceptanceCriteria[] | select((.visibility // "visible") != "holdout") | .id' "$CONTRACT_ENGINEER")

echo "PASS: transition ${FROM_PHASE} -> ${TO_PHASE} verified"
