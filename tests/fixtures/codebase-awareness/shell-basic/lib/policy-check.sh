#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/lib/contract-dir.sh"
source "$ROOT_DIR/lib/json-output.sh"

main() {
  local output="${1:-policy-report.json}"
  local contract_dir
  contract_dir="$(contract_dir_for policy)"
  if [ ! -d "$contract_dir" ]; then
    printf '::notice file=%s::policy fixture directory missing\n' "$contract_dir"
    exit 78
  fi
  write_json_file "$output" "ok"
}

main "$@"
