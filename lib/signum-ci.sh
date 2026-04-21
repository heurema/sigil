#!/usr/bin/env bash
# signum-ci.sh - CI wrapper for Signum pipeline
# Runs Signum with a pre-approved contract and maps decision to exit code.
#
# Exit codes:
#   0  - AUTO_OK (safe to merge)
#   1  - AUTO_BLOCK (issues found, block merge)
#   78 - HUMAN_REVIEW (needs manual review)
#
# Environment variables:
#   SIGNUM_CONTRACT_PATH - path to pre-approved contract.json (required)
#   SIGNUM_MAX_TURNS     - max agent turns (default: 30)
#   SIGNUM_ALLOWED_TOOLS - comma-separated tool allowlist (optional)
#   SIGNUM_PROJECT_ROOT  - project root (default: current directory)
#   SIGNUM_AUDIT_MAX_ITERATIONS - max audit fix iterations (default: 20, inherited by pipeline)
#   SIGNUM_CI_RELAXED    - if "true", HUMAN_REVIEW maps to exit 0 (pass with warning)

set -euo pipefail

resolve_ci_single_contract_dir() {
  local project_root="${1:-}"
  local contracts_root="${project_root}/.signum/contracts"
  local dir_count=""
  local only_dir=""

  if [ -z "$project_root" ] || [ ! -d "$contracts_root" ]; then
    return 1
  fi

  dir_count=$(find "$contracts_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$dir_count" != "1" ]; then
    return 1
  fi

  only_dir=$(find "$contracts_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
  if [ -n "$only_dir" ] && [ -d "$only_dir" ]; then
    printf '%s\n' "$only_dir"
    return 0
  fi

  return 1
}

resolve_ci_artifact_root() {
  local project_root="${1:-}"
  local contract_id="${2:-}"
  local index_path="${project_root}/.signum/contracts/index.json"
  local active_id=""
  local last_dir=""
  local single_dir=""

  if [ -z "$project_root" ]; then
    echo "resolve_ci_artifact_root: project_root required" >&2
    return 1
  fi

  if [ -n "$contract_id" ] && [ -d "$project_root/.signum/contracts/$contract_id" ]; then
    printf '%s\n' "$project_root/.signum/contracts/$contract_id"
    return 0
  fi

  if [ -f "$index_path" ]; then
    active_id=$(jq -r '.activeContractId // empty' "$index_path" 2>/dev/null || true)
    if [ -n "$active_id" ] && [ -d "$project_root/.signum/contracts/$active_id" ]; then
      printf '%s\n' "$project_root/.signum/contracts/$active_id"
      return 0
    fi

    last_dir=$(jq -r '.contracts[-1].directory // empty' "$index_path" 2>/dev/null || true)
    last_dir="${last_dir%/}"
    if [ -n "$last_dir" ] && [ -d "$project_root/$last_dir" ]; then
      printf '%s\n' "$project_root/$last_dir"
      return 0
    fi
  fi

  single_dir=$(resolve_ci_single_contract_dir "$project_root" 2>/dev/null || true)
  if [ -n "$single_dir" ] && [ -d "$single_dir" ]; then
    printf '%s\n' "$single_dir"
    return 0
  fi

  # Legacy fallback during migration.
  if [ -d "$project_root/.signum" ]; then
    printf '%s\n' "$project_root/.signum"
    return 0
  fi

  return 1
}

resolve_ci_proofpack_path() {
  local project_root="${1:-}"
  local contract_id="${2:-}"
  local artifact_root=""
  local single_dir=""

  if [ -z "$project_root" ]; then
    echo "resolve_ci_proofpack_path: project_root required" >&2
    return 1
  fi

  artifact_root=$(resolve_ci_artifact_root "$project_root" "$contract_id" 2>/dev/null || true)
  if [ -n "$artifact_root" ] && [ -f "$artifact_root/proofpack.json" ]; then
    printf '%s\n' "$artifact_root/proofpack.json"
    return 0
  fi

  single_dir=$(resolve_ci_single_contract_dir "$project_root" 2>/dev/null || true)
  if [ -n "$single_dir" ] && [ -f "$single_dir/proofpack.json" ]; then
    printf '%s\n' "$single_dir/proofpack.json"
    return 0
  fi

  # Legacy fallback during migration.
  if [ -f "$project_root/.signum/proofpack.json" ]; then
    printf '%s\n' "$project_root/.signum/proofpack.json"
    return 0
  fi

  return 1
}

signum_ci_main() {
  local contract="${SIGNUM_CONTRACT_PATH:-}"
  local input_contract_id=""
  local project_root="${SIGNUM_PROJECT_ROOT:-$(pwd)}"
  local max_turns="${SIGNUM_MAX_TURNS:-30}"
  local task=""
  local artifact_root=""
  local proofpack_path=""
  local decision=""
  local confidence=""
  local run_id=""
  local pp_hash=""

  if [ -z "$contract" ]; then
    echo "ERROR: SIGNUM_CONTRACT_PATH is required" >&2
    exit 1
  fi
  if [ ! -f "$contract" ]; then
    echo "ERROR: Contract not found: $contract" >&2
    exit 1
  fi

  if ! jq -e '.schemaVersion and .goal and .inScope and .acceptanceCriteria and .riskLevel' \
    "$contract" > /dev/null 2>&1; then
    echo "ERROR: Invalid contract (missing required fields)" >&2
    exit 1
  fi

  input_contract_id=$(jq -r '.contractId // empty' "$contract" 2>/dev/null || true)

  echo "=== Signum CI ==="
  echo "Contract: $contract"
  echo "Project:  $project_root"
  echo "Max turns: $max_turns"

  mkdir -p "$project_root/.signum"
  echo "Contract mode: file (Phase 1 imports SIGNUM_CONTRACT_PATH into canonical artifact root)"

  task=$(jq -r '.goal' "$contract")

  CLAUDE_ARGS=(
    -p "/signum $task"
    --output-format json
    --max-turns "$max_turns"
    --verbose
  )

  if [ -n "${SIGNUM_ALLOWED_TOOLS:-}" ]; then
    CLAUDE_ARGS+=(--allowedTools "$SIGNUM_ALLOWED_TOOLS")
  fi

  echo "Starting Signum pipeline..."
  cd "$project_root"
  claude "${CLAUDE_ARGS[@]}" || true

  artifact_root=$(resolve_ci_artifact_root "$project_root" "$input_contract_id" 2>/dev/null || true)
  proofpack_path=$(resolve_ci_proofpack_path "$project_root" "$input_contract_id" 2>/dev/null || true)
  if [ -z "$artifact_root" ] && [ -n "$proofpack_path" ]; then
    artifact_root=$(dirname "$proofpack_path")
  fi

  if [ -z "$proofpack_path" ] || [ ! -f "$proofpack_path" ]; then
    echo "ERROR: proofpack.json not produced" >&2
    exit 1
  fi

  decision=$(jq -r '.decision' "$proofpack_path")
  confidence=$(jq -r '.confidence.overall // 0' "$proofpack_path")
  run_id=$(jq -r '.runId' "$proofpack_path")

  echo ""
  echo "=== Result ==="
  echo "Artifact root: ${artifact_root:-unresolved}"
  echo "Proofpack:  $proofpack_path"
  echo "Decision:   $decision"
  echo "Confidence: ${confidence}%"
  echo "Run ID:     $run_id"

  if command -v sha256sum >/dev/null 2>&1; then
    pp_hash=$(sha256sum "$proofpack_path" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    pp_hash=$(shasum -a 256 "$proofpack_path" | awk '{print $1}')
  else
    pp_hash="unavailable"
  fi
  echo "Proofpack SHA-256: $pp_hash"

  case "$decision" in
    AUTO_OK)
      echo "Status: PASS"
      exit 0
      ;;
    AUTO_BLOCK)
      echo "Status: BLOCKED"
      exit 1
      ;;
    HUMAN_REVIEW)
      if [ "${SIGNUM_CI_RELAXED:-false}" = "true" ]; then
        echo "Status: NEEDS REVIEW (relaxed mode - passing)"
        exit 0
      else
        echo "Status: NEEDS REVIEW"
        exit 78
      fi
      ;;
    *)
      echo "ERROR: Unknown decision: $decision" >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  signum_ci_main "$@"
fi
