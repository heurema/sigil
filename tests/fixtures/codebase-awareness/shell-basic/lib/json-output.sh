#!/usr/bin/env bash
set -euo pipefail

emit_json_report() {
  local status="$1"
  printf '{"status":"%s"}\n' "$status"
}

write_json_file() {
  local output="$1"
  local status="$2"
  mkdir -p "$(dirname "$output")"
  emit_json_report "$status" > "$output"
}
