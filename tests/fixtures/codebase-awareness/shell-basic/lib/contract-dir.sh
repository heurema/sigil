#!/usr/bin/env bash
set -euo pipefail

contract_dir_for() {
  local name="$1"
  printf 'tests/fixtures/%s\n' "$name"
}
