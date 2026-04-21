#!/usr/bin/env bash
# boundary-verifier.sh -- deterministic phase-boundary verification for Signum.
# Runs AFTER engineer completes and BEFORE audit begins.
# It does not trust agent claims. It observes workspace state, runs AC verifiers,
# hashes artifacts, checks scope integrity, and emits an append-only receipt.
#
# Usage:
#   boundary-verifier.sh [phase] [options]
#
# Options:
#   --workspace-root PATH       Workspace root to inspect (default: $PWD)
#   --signum-dir PATH           Signum artifact dir (default: active contract root from .signum/contracts/index.json, else .signum)
#   --contract PATH             Engineer-visible contract (default: <signum-dir>/contract-engineer.json)
#   --contract-full PATH        Full contract (default: <signum-dir>/contract.json)
#   --snapshot PATH             Snapshot JSON from snapshot-tree.sh
#   --execution-context PATH    Execution context JSON
#   --artifacts CSV             Artifact names under signum dir (default: combined.patch,execute_log.json)
set -euo pipefail
export LC_ALL=C

PHASE="${1:-execute}"
if [[ "$PHASE" == --* ]]; then
  PHASE="execute"
else
  shift || true
fi

WORKSPACE_ROOT="$PWD"
SIGNUM_DIR=""
CONTRACT_ENGINEER=""
CONTRACT_FULL=""
SNAPSHOT_JSON=""
EXECUTION_CONTEXT=""
ARTIFACTS_CSV="combined.patch,execute_log.json"

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
    --snapshot)
      SNAPSHOT_JSON="$2"
      shift 2
      ;;
    --execution-context)
      EXECUTION_CONTEXT="$2"
      shift 2
      ;;
    --artifacts)
      ARTIFACTS_CSV="$2"
      shift 2
      ;;
    *)
      echo "boundary-verifier.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "boundary-verifier.sh: jq not found" >&2
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
    echo "boundary-verifier.sh: no sha256 tool found" >&2
    exit 1
  fi
}

json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'
}

normalize_scope_entry() {
  printf '%s' "$1" | sed 's/ (.*$//'
}

is_glob_like() {
  case "$1" in
    *'*'*|*'?'*|*'['*) return 0 ;;
    *) return 1 ;;
  esac
}

path_allowed() {
  local path="$1"
  local entry raw
  while IFS= read -r raw; do
    [[ -z "$raw" ]] && continue
    entry=$(normalize_scope_entry "$raw")
    [[ -z "$entry" ]] && continue
    # Glob entries: evaluate with bash pattern matching
    if is_glob_like "$entry"; then
      # shellcheck disable=SC2254
      case "$path" in
        $entry ) return 0 ;;
      esac
      continue
    fi
    case "$entry" in
      */)
        case "$path" in
          "$entry"* ) return 0 ;;
        esac
        ;;
      *)
        if [[ "$path" == "$entry" ]]; then
          return 0
        fi
        case "$path" in
          "$entry"/* ) return 0 ;;
        esac
        ;;
    esac
  done <<< "$ALLOWED_PATHS_NL"
  return 1
}

list_files_null() {
  if git -C "$ABS_WORKSPACE" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$ABS_WORKSPACE" ls-files -z --cached --others --exclude-standard -- .
  else
    local signum_name
    signum_name=$(basename "$ABS_SIGNUM_DIR")
    (
      CDPATH= cd "$ABS_WORKSPACE"
      find . \
        -path './.git' -prune -o \
        -path "./${signum_name}" -prune -o \
        -type f -print0
    )
  fi
}

write_manifest() {
  local out="$1"
  local tmp
  tmp=$(mktemp)
  while IFS= read -r -d '' rel_path; do
    [[ -z "$rel_path" ]] && continue
    rel_path="${rel_path#./}"
    [[ -z "$rel_path" ]] && continue
    [[ -f "$ABS_WORKSPACE/$rel_path" ]] || continue
    printf '%s\tsha256:%s\n' "$rel_path" "$(hash_file "$ABS_WORKSPACE/$rel_path")" >> "$tmp"
  done < <(list_files_null)
  sort "$tmp" > "$out"
  rm -f "$tmp"
}

classify_verify_strength() {
  local verify_file="$1"
  if jq -e 'any(.steps[]?; has("expect") and (
      (.expect | has("json_path")) or
      (.expect | has("stdout_contains")) or
      (.expect | has("stdout_matches")) or
      (.expect | has("file_exists")) or
      (.expect | has("file_not_exists"))
    ))' "$verify_file" >/dev/null 2>&1; then
    printf 'observational'
    return 0
  fi
  if jq -e 'any(.steps[]?; has("exec") and (
      .exec.argv[0] == "test" or
      .exec.argv[0] == "grep" or
      (.exec.argv[0] == "jq" and any(.exec.argv[]?; . == "-e"))
    ))' "$verify_file" >/dev/null 2>&1; then
    printf 'predicate'
    return 0
  fi
  printf 'exit_only'
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
SNAPSHOT_JSON="${SNAPSHOT_JSON:-$ABS_SIGNUM_DIR/snapshots/pre-execute.json}"
EXECUTION_CONTEXT="${EXECUTION_CONTEXT:-$ABS_SIGNUM_DIR/execution_context.json}"
# Resolve dsl-runner.sh from trusted Signum install roots only.
# Do NOT trust workspace-local copies — a compromised project could supply a
# dsl-runner.sh that passes all AC checks regardless of actual result.
DSL_RUNNER=""
_REAL_HOME_BV="${HOME}"
for _d in \
  "${_REAL_HOME_BV}/.claude/plugins/signum/platforms/claude-code" \
  "${_REAL_HOME_BV}/.local/share/emporium/signum/platforms/claude-code" \
  "${_REAL_HOME_BV}/.nex/plugins/signum/platforms/claude-code"; do
  [[ -x "${_d}/lib/dsl-runner.sh" ]] || continue
  DSL_RUNNER="${_d}/lib/dsl-runner.sh"
  break
done
# Fallback for test environments: allow workspace-local dsl-runner only when
# SIGNUM_TRUST_LOCAL=1 is explicitly set (e.g. by test harness).
# Production installs MUST resolve from trusted paths above.
if [[ -z "$DSL_RUNNER" && "${SIGNUM_TRUST_LOCAL:-}" == "1" && -x "$ABS_WORKSPACE/lib/dsl-runner.sh" ]]; then
  DSL_RUNNER="$ABS_WORKSPACE/lib/dsl-runner.sh"
fi

for required in "$CONTRACT_ENGINEER" "$CONTRACT_FULL" "$SNAPSHOT_JSON" "$DSL_RUNNER"; do
  if [[ ! -f "$required" ]]; then
    echo "boundary-verifier.sh: required file missing: $required" >&2
    exit 1
  fi
done

mkdir -p "$ABS_SIGNUM_DIR/receipts" "$ABS_SIGNUM_DIR/runs"
RISK_LEVEL=$(jq -r '.riskLevel // "medium"' "$CONTRACT_FULL")
CONTRACT_ID=$(jq -r '.contractId // "unknown-contract"' "$CONTRACT_FULL")
CONTRACT_HASH="sha256:$(hash_file "$CONTRACT_FULL")"

if [[ -f "$EXECUTION_CONTEXT" ]]; then
  RUN_ID=$(jq -r '.run_id // empty' "$EXECUTION_CONTEXT")
else
  RUN_ID=""
fi
if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  RUN_ID="$CONTRACT_ID"
  mkdir -p "$(dirname "$EXECUTION_CONTEXT")"
  if [[ -f "$EXECUTION_CONTEXT" ]]; then
    jq --arg rid "$RUN_ID" '. + {run_id:$rid}' "$EXECUTION_CONTEXT" > "$EXECUTION_CONTEXT.tmp" && mv "$EXECUTION_CONTEXT.tmp" "$EXECUTION_CONTEXT"
  else
    jq -n --arg rid "$RUN_ID" '{run_id:$rid}' > "$EXECUTION_CONTEXT"
  fi
fi

RUN_DIR="$ABS_SIGNUM_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
ATTEMPT_ID=$(( $(find "$RUN_DIR" -maxdepth 1 -type f -name "${PHASE}-*.json" | wc -l | tr -d '[:space:]') + 1 ))
ATTEMPT_PAD=$(printf '%02d' "$ATTEMPT_ID")
LATEST_RECEIPT="$ABS_SIGNUM_DIR/receipts/${PHASE}.json"
RECEIPT_PATH="$RUN_DIR/${PHASE}-${ATTEMPT_PAD}.json"
EVIDENCE_DIR="$ABS_SIGNUM_DIR/receipts/evidence/${PHASE}-${ATTEMPT_PAD}"
mkdir -p "$EVIDENCE_DIR"

PARENT_RECEIPT_HASH=""
if [[ "$ATTEMPT_ID" -gt 1 ]]; then
  PREV_RECEIPT="$RUN_DIR/${PHASE}-$(printf '%02d' $((ATTEMPT_ID - 1))).json"
  if [[ -f "$PREV_RECEIPT" ]]; then
    PARENT_RECEIPT_HASH="sha256:$(hash_file "$PREV_RECEIPT")"
  fi
fi

BASE_TREE_HASH=$(jq -r '.tree_hash // empty' "$SNAPSHOT_JSON")
SNAPSHOT_MANIFEST=$(jq -r '.manifest_path // empty' "$SNAPSHOT_JSON")
if [[ -z "$BASE_TREE_HASH" || -z "$SNAPSHOT_MANIFEST" || ! -f "$SNAPSHOT_MANIFEST" ]]; then
  echo "boundary-verifier.sh: invalid snapshot metadata in $SNAPSHOT_JSON" >&2
  exit 1
fi

CURRENT_MANIFEST=$(mktemp)
AC_OBJ_DIR=$(mktemp -d)
trap 'rm -f "$CURRENT_MANIFEST"; rm -rf "$AC_OBJ_DIR"' EXIT
write_manifest "$CURRENT_MANIFEST"
OBSERVED_TREE_HASH="sha256:$(hash_file "$CURRENT_MANIFEST")"

# Build scope allow-lists. inScope covers all change types; allowNewFilesUnder covers ONLY additions.
IN_SCOPE_NL=$(jq -r '.inScope[]? // empty' "$CONTRACT_FULL")
ALLOW_NEW_NL=$(jq -r '.allowNewFilesUnder[]? // empty' "$CONTRACT_FULL")
# Full allow-list includes both (used for added files)
ALLOWED_PATHS_NL=$(printf '%s\n%s\n' "$IN_SCOPE_NL" "$ALLOW_NEW_NL" | sed '/^$/d')
# Strict allow-list excludes allowNewFilesUnder (used for modified/deleted files)
ALLOWED_PATHS_STRICT_NL=$(printf '%s\n' "$IN_SCOPE_NL" | sed '/^$/d')

# Diff manifests against snapshot.
mapfile -t DIFF_ROWS < <(join -t $'\t' -a1 -a2 -e '__MISSING__' -o 0,1.2,2.2 "$SNAPSHOT_MANIFEST" "$CURRENT_MANIFEST")
CHANGED_PATHS=()
ADDED_PATHS=()
MODIFIED_PATHS=()
DELETED_PATHS=()
OUT_OF_SCOPE=()

for row in "${DIFF_ROWS[@]}"; do
  [[ -z "$row" ]] && continue
  path=${row%%$'\t'*}
  rest=${row#*$'\t'}
  before_hash=${rest%%$'\t'*}
  after_hash=${rest#*$'\t'}
  if [[ "$before_hash" == "$after_hash" ]]; then
    continue
  fi
  CHANGED_PATHS+=("$path")
  if [[ "$before_hash" == '__MISSING__' ]]; then
    ADDED_PATHS+=("$path")
    # Added files: allowed by both inScope and allowNewFilesUnder
    if ! path_allowed "$path"; then
      OUT_OF_SCOPE+=("$path")
    fi
  elif [[ "$after_hash" == '__MISSING__' ]]; then
    DELETED_PATHS+=("$path")
    # Deleted/modified files: only allowed by inScope (not allowNewFilesUnder)
    _saved_allowed="$ALLOWED_PATHS_NL"
    ALLOWED_PATHS_NL="$ALLOWED_PATHS_STRICT_NL"
    if ! path_allowed "$path"; then
      OUT_OF_SCOPE+=("$path")
    fi
    ALLOWED_PATHS_NL="$_saved_allowed"
  else
    MODIFIED_PATHS+=("$path")
    # Deleted/modified files: only allowed by inScope (not allowNewFilesUnder)
    _saved_allowed="$ALLOWED_PATHS_NL"
    ALLOWED_PATHS_NL="$ALLOWED_PATHS_STRICT_NL"
    if ! path_allowed "$path"; then
      OUT_OF_SCOPE+=("$path")
    fi
    ALLOWED_PATHS_NL="$_saved_allowed"
  fi
done

# Ensure inScope paths exist after execute.
MISSING_IN_SCOPE=()
while IFS= read -r raw_path; do
  [[ -z "$raw_path" ]] && continue
  scoped=$(normalize_scope_entry "$raw_path")
  [[ -z "$scoped" ]] && continue
  if is_glob_like "$scoped"; then
    continue
  fi
  if [[ "$scoped" == */ ]]; then
    [[ -d "$ABS_WORKSPACE/$scoped" ]] || MISSING_IN_SCOPE+=("$scoped")
  else
    [[ -e "$ABS_WORKSPACE/$scoped" ]] || MISSING_IN_SCOPE+=("$scoped")
  fi
done <<< "$IN_SCOPE_NL"

# Hash phase artifacts under signum dir.
IFS=',' read -r -a ARTIFACT_NAMES <<< "$ARTIFACTS_CSV"
ARTIFACT_LIST=()
ARTIFACT_HASH_SNIPPETS=()
for artifact_name in "${ARTIFACT_NAMES[@]}"; do
  artifact_name=$(printf '%s' "$artifact_name" | xargs)
  [[ -z "$artifact_name" ]] && continue
  artifact_path="$ABS_SIGNUM_DIR/$artifact_name"
  if [[ -f "$artifact_path" ]]; then
    ARTIFACT_LIST+=("$artifact_name")
    ARTIFACT_HASH_SNIPPETS+=("$(jq -n --arg k "$artifact_name" --arg v "sha256:$(hash_file "$artifact_path")" '{($k):$v}')")
  fi
done
if [[ ${#ARTIFACT_HASH_SNIPPETS[@]} -gt 0 ]]; then
  OUTPUT_HASHES_JSON=$(printf '%s\n' "${ARTIFACT_HASH_SNIPPETS[@]}" | jq -s 'add')
else
  OUTPUT_HASHES_JSON='{}'
fi

TOTAL_ACS=$(jq '[.acceptanceCriteria[] | select((.visibility // "visible") != "holdout")] | length' "$CONTRACT_ENGINEER")
FAILED_ACS=()
VACUOUS_ACS=()
UNSUPPORTED_ACS=()

while IFS= read -r ac_id; do
  [[ -z "$ac_id" ]] && continue
  VERIFY_FILE="$EVIDENCE_DIR/${ac_id}.verify.json"
  EVIDENCE_FILE="$EVIDENCE_DIR/${ac_id}.out.txt"
  jq --arg id "$ac_id" -c '.acceptanceCriteria[] | select(.id == $id) | .verify' "$CONTRACT_ENGINEER" > "$VERIFY_FILE"

  verify_format="dsl"
  verify_exit=0
  evidence_status="PASS"
  strength="unknown"
  vacuous=false
  block_reason=""

  if ! jq -e 'type == "object" and has("steps")' "$VERIFY_FILE" >/dev/null 2>&1; then
    verify_format="unsupported"
    verify_exit=98
    evidence_status="BLOCKED"
    block_reason="unsupported_verify_format"
    printf 'unsupported verify format for %s\n' "$ac_id" > "$EVIDENCE_FILE"
    UNSUPPORTED_ACS+=("$ac_id")
  else
    strength=$(classify_verify_strength "$VERIFY_FILE")
    if [[ "$strength" == "exit_only" ]]; then
      vacuous=true
      VACUOUS_ACS+=("$ac_id")
      if [[ "$RISK_LEVEL" != "low" ]]; then
        verify_exit=96
        evidence_status="BLOCKED"
        block_reason="vacuous_verify"
        printf 'vacuous verify for %s (risk=%s)\n' "$ac_id" "$RISK_LEVEL" > "$EVIDENCE_FILE"
      fi
    fi
    if [[ "$verify_exit" -eq 0 ]]; then
      set +e
      "$DSL_RUNNER" run "$VERIFY_FILE" > "$EVIDENCE_FILE" 2>&1
      verify_exit=$?
      set -e
      if [[ "$verify_exit" -ne 0 ]]; then
        evidence_status="FAIL"
        FAILED_ACS+=("$ac_id")
        block_reason="verify_failed"
      fi
    else
      FAILED_ACS+=("$ac_id")
    fi
  fi

  EVIDENCE_HASH="sha256:$(hash_file "$EVIDENCE_FILE")"
  jq -n \
    --arg id "$ac_id" \
    --arg status "$evidence_status" \
    --arg verify_format "$verify_format" \
    --arg strength "$strength" \
    --arg output_path "$EVIDENCE_FILE" \
    --arg output_hash "$EVIDENCE_HASH" \
    --argjson verify_exit_code "$verify_exit" \
    --argjson vacuous "$vacuous" \
    --arg block_reason "$block_reason" \
    '{($id): {
      status: $status,
      verify_format: $verify_format,
      verify_strength: $strength,
      verify_exit_code: $verify_exit_code,
      verify_output_path: $output_path,
      verify_output_hash: $output_hash,
      vacuous: $vacuous,
      block_reason: (if $block_reason == "" then null else $block_reason end)
    }}' > "$AC_OBJ_DIR/${ac_id}.json"
done < <(jq -r '.acceptanceCriteria[] | select((.visibility // "visible") != "holdout") | .id' "$CONTRACT_ENGINEER")

if find "$AC_OBJ_DIR" -type f -name '*.json' | grep -q .; then
  AC_EVIDENCE_JSON=$(jq -s 'add' "$AC_OBJ_DIR"/*.json)
else
  AC_EVIDENCE_JSON='{}'
fi

PASSED_AC_COUNT=$(( TOTAL_ACS - ${#FAILED_ACS[@]} ))
CHANGED_JSON=$(json_array_from_lines ${CHANGED_PATHS[@]+"${CHANGED_PATHS[@]}"})
ADDED_JSON=$(json_array_from_lines ${ADDED_PATHS[@]+"${ADDED_PATHS[@]}"})
MODIFIED_JSON=$(json_array_from_lines ${MODIFIED_PATHS[@]+"${MODIFIED_PATHS[@]}"})
DELETED_JSON=$(json_array_from_lines ${DELETED_PATHS[@]+"${DELETED_PATHS[@]}"})
OUT_OF_SCOPE_JSON=$(json_array_from_lines ${OUT_OF_SCOPE[@]+"${OUT_OF_SCOPE[@]}"})
MISSING_JSON=$(json_array_from_lines ${MISSING_IN_SCOPE[@]+"${MISSING_IN_SCOPE[@]}"})
FAILED_JSON=$(json_array_from_lines ${FAILED_ACS[@]+"${FAILED_ACS[@]}"})
VACUOUS_JSON=$(json_array_from_lines ${VACUOUS_ACS[@]+"${VACUOUS_ACS[@]}"})
UNSUPPORTED_JSON=$(json_array_from_lines ${UNSUPPORTED_ACS[@]+"${UNSUPPORTED_ACS[@]}"})
ARTIFACTS_JSON=$(json_array_from_lines ${ARTIFACT_LIST[@]+"${ARTIFACT_LIST[@]}"})
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

RECEIPT_STATUS="PASS"
if [[ ${#OUT_OF_SCOPE[@]} -gt 0 || ${#MISSING_IN_SCOPE[@]} -gt 0 || ${#FAILED_ACS[@]} -gt 0 || ${#UNSUPPORTED_ACS[@]} -gt 0 ]]; then
  RECEIPT_STATUS="BLOCK"
fi

jq -n \
  --arg receipt_type "phase_complete" \
  --arg phase "$PHASE" \
  --arg status "$RECEIPT_STATUS" \
  --arg run_id "$RUN_ID" \
  --arg contract_id "$CONTRACT_ID" \
  --arg contract_hash "$CONTRACT_HASH" \
  --arg base_tree_hash "$BASE_TREE_HASH" \
  --arg observed_tree_hash "$OBSERVED_TREE_HASH" \
  --arg snapshot_ref "$SNAPSHOT_JSON" \
  --arg parent_receipt_hash "$PARENT_RECEIPT_HASH" \
  --arg workspace_root "$ABS_WORKSPACE" \
  --arg timestamp "$TIMESTAMP" \
  --argjson attempt_id "$ATTEMPT_ID" \
  --argjson output_artifacts "$ARTIFACTS_JSON" \
  --argjson output_hashes "$OUTPUT_HASHES_JSON" \
  --argjson ac_evidence "$AC_EVIDENCE_JSON" \
  --argjson changed_paths "$CHANGED_JSON" \
  --argjson added_paths "$ADDED_JSON" \
  --argjson modified_paths "$MODIFIED_JSON" \
  --argjson deleted_paths "$DELETED_JSON" \
  --argjson out_of_scope "$OUT_OF_SCOPE_JSON" \
  --argjson missing_in_scope "$MISSING_JSON" \
  --argjson failed_acs "$FAILED_JSON" \
  --argjson vacuous_acs "$VACUOUS_JSON" \
  --argjson unsupported_acs "$UNSUPPORTED_JSON" \
  --argjson total_acs "$TOTAL_ACS" \
  --argjson passed_acs "$PASSED_AC_COUNT" \
  '{
    receipt_type: $receipt_type,
    phase: $phase,
    status: $status,
    run_id: $run_id,
    attempt_id: $attempt_id,
    contract_id: $contract_id,
    contract_hash: $contract_hash,
    base_tree_hash: $base_tree_hash,
    observed_tree_hash: $observed_tree_hash,
    snapshot_ref: $snapshot_ref,
    output_artifacts: $output_artifacts,
    output_hashes: $output_hashes,
    ac_evidence: $ac_evidence,
    scope_check: {
      changed_paths: $changed_paths,
      added_paths: $added_paths,
      modified_paths: $modified_paths,
      deleted_paths: $deleted_paths,
      out_of_scope: $out_of_scope,
      missing_in_scope: $missing_in_scope
    },
    summary: {
      total_acs: $total_acs,
      passed_acs: $passed_acs,
      failed_acs: $failed_acs,
      vacuous_acs: $vacuous_acs,
      unsupported_acs: $unsupported_acs
    },
    parent_receipt_hash: (if $parent_receipt_hash == "" then null else $parent_receipt_hash end),
    workspace_root: $workspace_root,
    timestamp: $timestamp
  }' > "$RECEIPT_PATH"

cp "$RECEIPT_PATH" "$LATEST_RECEIPT"

if [[ "$RECEIPT_STATUS" == "PASS" ]]; then
  echo "PASS: receipt written to $RECEIPT_PATH"
  exit 0
fi

echo "BLOCK: boundary verification failed"
if [[ ${#OUT_OF_SCOPE[@]} -gt 0 ]]; then
  echo " - out-of-scope changes: ${OUT_OF_SCOPE[*]}"
fi
if [[ ${#MISSING_IN_SCOPE[@]} -gt 0 ]]; then
  echo " - missing inScope paths: ${MISSING_IN_SCOPE[*]}"
fi
if [[ ${#FAILED_ACS[@]} -gt 0 ]]; then
  echo " - AC failures: ${FAILED_ACS[*]}"
fi
exit 1
