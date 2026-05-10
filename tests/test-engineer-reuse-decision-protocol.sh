#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
ROOT_PROMPT="$ROOT_DIR/agents/engineer.md"
OVERLAY_PROMPT="$ROOT_DIR/platforms/claude-code/agents/engineer.md"

passed=0
failed=0

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label" "missing $needle"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$label" "unexpected $needle"
  else
    pass "$label"
  fi
}

check_prompt() {
  local file="$1"
  local label="$2"

  assert_contains "$file" "Codebase Awareness / Reuse Decision Protocol" "$label names reuse decision protocol"
  assert_contains "$file" "implementation_context.json" "$label mentions implementation context"
  assert_contains "$file" "reuse_candidates.json" "$label mentions reuse candidates"
  assert_contains "$file" "Before implementing code changes" "$label requires checking before implementation"
  assert_contains "$file" "Before editing code, write \`reuse_decision.json\`." "$label requires decision before code edits"
  assert_contains "$file" "reuse_decision.json" "$label mentions reuse decision artifact"
  assert_contains "$file" "reuse\`, \`adapt\`, \`reject\`, \`follow-pattern\`, \`respect-boundary\`, \`inspect-only\`, or \`defer\`" "$label lists accepted dispositions"
  assert_contains "$file" "In \`warn\` and \`gate\` modes \`reuse_decision.json\` is required by the orchestrator and must address top/strong candidates" "$label says warn/gate require top/strong coverage"
  assert_contains "$file" "top 3 candidates plus candidates with high score or confidence" "$label defines top/strong candidates"
  assert_contains "$file" "Every \`reuse\`, \`adapt\`, \`follow-pattern\`, or \`respect-boundary\` decision must include \`candidateId\`." "$label requires candidateId for action-bearing decisions"
  assert_contains "$file" "\`reject\`, \`defer\`, and \`inspect-only\` decisions must include rationale." "$label requires rationale for non-action decisions"
  assert_contains "$file" "Do not use a generic \"I looked at candidates\" decision without binding it to relevant candidate IDs." "$label forbids generic reuse decision"
  assert_not_contains "$file" "duplicate_scan.json" "$label does not assign duplicate scan"
  assert_not_contains "$file" "reuse_summary.json" "$label does not assign reuse summary"
}

echo "=== Engineer reuse decision protocol ==="
check_prompt "$ROOT_PROMPT" "root prompt"
check_prompt "$OVERLAY_PROMPT" "overlay prompt"

if cmp -s "$ROOT_PROMPT" "$OVERLAY_PROMPT"; then
  pass "root and overlay engineer prompts match"
else
  fail "root and overlay engineer prompts match" "prompt mirrors differ"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: engineer prompt contains PR2A reuse decision protocol"
