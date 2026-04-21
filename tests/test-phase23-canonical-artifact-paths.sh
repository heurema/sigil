#!/usr/bin/env bash
# test-phase23-canonical-artifact-paths.sh -- ensure remaining Phase 2/3 aux artifacts use canonical artifact root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_COMMAND="$SCRIPT_DIR/../commands/signum.md"
OVERLAY_COMMAND="$SCRIPT_DIR/../platforms/claude-code/commands/signum.md"

passed=0
failed=0

assert_pass() {
  local name="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s | %s\n' "$name" "$output"
    failed=$((failed + 1))
  fi
}

assert_section_absent() {
  local name="$1"
  local pattern="$2"
  local section="$3"
  if grep -Fq "$pattern" <<<"$section"; then
    printf '  FAIL: %s | found forbidden pattern: %s\n' "$name" "$pattern"
    failed=$((failed + 1))
  else
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

phase_section() {
  local file="$1"
  awk '
    /If `repo-contract.json` exists in the project root, also capture invariant baseline/ { in_scope=1 }
    /^### Step 3\.3:/ { in_scope=0 }
    in_scope { print }
  ' "$file"
}

echo "=== Phase 2/3 canonical artifact paths ==="

for command in "$ROOT_COMMAND" "$OVERLAY_COMMAND"; do
  if [[ "$command" == *"/platforms/claude-code/"* ]]; then
    label="claude-overlay"
  else
    label="root"
  fi
  section=$(phase_section "$command")

  assert_pass "${label} links repo contract baseline view" \
    grep -Fq 'link_active_artifact "repo_contract_baseline.json"' "$command"
  assert_pass "${label} links repo contract violations view" \
    grep -Fq 'link_active_artifact "repo_contract_violations.json"' "$command"
  assert_pass "${label} links review context view" \
    grep -Fq 'link_active_artifact "review_context.json"' "$command"
  assert_pass "${label} links codex review prompt view" \
    grep -Fq 'link_active_artifact "review_prompt_codex.txt"' "$command"
  assert_pass "${label} links gemini review prompt view" \
    grep -Fq 'link_active_artifact "review_prompt_gemini.txt"' "$command"

  assert_pass "${label} declares repo baseline canonical path" \
    grep -Fq 'REPO_CONTRACT_BASELINE_PATH="${ARTIFACT_ROOT}repo_contract_baseline.json"' "$command"
  assert_pass "${label} declares repo violations canonical path" \
    grep -Fq 'REPO_CONTRACT_VIOLATIONS_PATH="${ARTIFACT_ROOT}repo_contract_violations.json"' "$command"
  assert_pass "${label} declares review context canonical path" \
    grep -Fq 'REVIEW_CONTEXT_PATH="${ARTIFACT_ROOT}review_context.json"' "$command"
  assert_pass "${label} declares codex prompt canonical path" \
    grep -Fq 'REVIEW_PROMPT_CODEX_PATH="${ARTIFACT_ROOT}review_prompt_codex.txt"' "$command"
  assert_pass "${label} declares gemini prompt canonical path" \
    grep -Fq 'REVIEW_PROMPT_GEMINI_PATH="${ARTIFACT_ROOT}review_prompt_gemini.txt"' "$command"

  assert_section_absent "${label} no root repo baseline path in phase section" '.signum/repo_contract_baseline.json' "$section"
  assert_section_absent "${label} no root repo violations path in phase section" '.signum/repo_contract_violations.json' "$section"
  assert_section_absent "${label} no root review context path in phase section" '.signum/review_context.json' "$section"
  assert_section_absent "${label} no root codex prompt path in phase section" '.signum/review_prompt_codex.txt' "$section"
  assert_section_absent "${label} no root gemini prompt path in phase section" '.signum/review_prompt_gemini.txt' "$section"
done

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
