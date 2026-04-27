#!/usr/bin/env bash
# test-dsl-runner.sh -- run deterministic DSL runner regression suite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for test_script in "$SCRIPT_DIR"/dsl-runner/test-*.sh; do
  echo "== $(basename "$test_script") =="
  bash "$test_script"
  echo ""
done

printf 'DSL runner suite passed.\n'
