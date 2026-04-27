#!/usr/bin/env bash
# run-deterministic-tests.sh -- local deterministic checks for PR CI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run_step() {
  local label="$1"
  shift
  echo "== $label =="
  "$@"
  echo ""
}

run_shell_tests() {
  local label="$1"
  shift
  local -a find_args=("$@")
  local found=0

  echo "== $label =="
  while IFS= read -r test_script; do
    found=1
    if [ "${SIGNUM_CLEANROOM_SMOKE_ACTIVE:-0}" = "1" ] \
      && [ "$(basename "$test_script")" = "test-cleanroom-smoke.sh" ]; then
      echo "-- ${test_script#$REPO_ROOT/} (skipped: clean-room smoke already active)"
      continue
    fi
    echo "-- ${test_script#$REPO_ROOT/}"
    bash "$test_script"
  done < <(find "${find_args[@]}" -type f -name 'test-*.sh' | sort)

  if [ "$found" -eq 0 ]; then
    echo "No tests found."
  fi
  echo ""
}

cd "$REPO_ROOT"

run_shell_tests "Top-level shell tests" "$REPO_ROOT/tests" -maxdepth 1

if [ -d "$REPO_ROOT/platforms/claude-code/tests" ]; then
  run_shell_tests "Claude Code platform shell tests" "$REPO_ROOT/platforms/claude-code/tests"
fi

if [ -f "$REPO_ROOT/evals/run.py" ]; then
  run_step "Offline eval snapshots" python3 evals/run.py
fi

echo "Deterministic tests passed."
