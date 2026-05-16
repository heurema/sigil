#!/usr/bin/env bash
# test-codex-agent-review-check.sh -- deterministic tests for Codex local review gate
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check_codex_agent_review.py"

passed=0
failed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

write_contract_root() {
  local root="$1" risk="$2" decision="$3"
  mkdir -p "$root/reviews"
  cat > "$root/contract.json" <<JSON
{"contractId":"$(basename "$root")","riskLevel":"$risk"}
JSON
  cat > "$root/audit_summary.json" <<JSON
{
  "decision": "$decision",
  "riskLevel": "$risk",
  "agentReviewCoverage": {"codex": "ready"},
  "agentReviewArtifacts": [".signum/contracts/$(basename "$root")/reviews/codex.json"]
}
JSON
  cat > "$root/proofpack.json" <<JSON
{
  "decision": "$decision",
  "riskLevel": "$risk",
  "checks": {
    "reviews": {
      "codex": {
        "content": {"provider": "codex", "reviewerType": "local_agent", "state": "ready"},
        "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sizeBytes": 80,
        "status": "present"
      }
    }
  },
  "artifactRefs": [{"path": "reviews/codex.json"}]
}
JSON
  cat > "$root/reviews/codex.json" <<JSON
{
  "provider": "codex",
  "reviewerType": "local_agent",
  "state": "ready",
  "verdict": "APPROVE",
  "findings": [],
  "summary": "No blocking findings."
}
JSON
}

run_checker() {
  local root="$1" output="$2"
  python3 "$CHECKER" --repo-root "$REPO_ROOT" --contract-root "$root" > "$output"
}

assert_json_field() {
  local name="$1" file="$2" filter="$3" expected="$4" actual
  actual="$(jq -r "$filter" "$file")"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected $expected, got $actual"
  fi
}

assert_ok() {
  local name="$1" root="$2" out="$3"
  local output
  if output="$(python3 "$CHECKER" --repo-root "$REPO_ROOT" --contract-root "$root" --json-output "$out" 2>&1)"; then
    printf '%s\n' "$output" | jq empty
    cmp -s "$out" <(printf '%s\n' "$output") || {
      fail "$name" "--json-output differs from stdout"
      return
    }
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

assert_fail_violation() {
  local name="$1" root="$2" expected="$3" out="$4"
  local output exit_code
  set +e
  output="$(python3 "$CHECKER" --repo-root "$REPO_ROOT" --contract-root "$root" > "$out" 2>&1)"
  exit_code=$?
  set -e
  if [ "$exit_code" -eq 0 ]; then
    fail "$name" "expected failure, got exit 0"
    return
  fi
  jq empty "$out"
  if jq -e --arg expected "$expected" '.violations | index($expected)' "$out" >/dev/null; then
    pass "$name"
  else
    fail "$name" "missing violation $expected in $output"
  fi
}

echo "=== Codex local agent review checker ==="

python3 -m py_compile "$CHECKER"
pass "checker py_compile"

VALID="$WORK/project/.signum/contracts/sig-codex-valid"
write_contract_root "$VALID" medium AUTO_OK
assert_ok "medium AUTO_OK with Codex review passes" "$VALID" "$WORK/valid.json"
assert_json_field "valid result is required" "$WORK/valid.json" '.required' "true"
assert_json_field "valid hard gate passes" "$WORK/valid.json" '.hardGatePassed' "true"
assert_json_field "valid proofpack includes Codex review" "$WORK/valid.json" '.checks.proofpackIncludesCodexReview' "true"

LOW="$WORK/project/.signum/contracts/sig-codex-low"
write_contract_root "$LOW" low AUTO_OK
rm -f "$LOW/reviews/codex.json"
jq 'del(.agentReviewCoverage, .agentReviewArtifacts)' "$LOW/audit_summary.json" > "$LOW/audit_summary.tmp" \
  && mv "$LOW/audit_summary.tmp" "$LOW/audit_summary.json"
jq 'del(.checks.reviews.codex, .artifactRefs)' "$LOW/proofpack.json" > "$LOW/proofpack.tmp" \
  && mv "$LOW/proofpack.tmp" "$LOW/proofpack.json"
assert_ok "low AUTO_OK without Codex review is not gated" "$LOW" "$WORK/low.json"
assert_json_field "low result is not required" "$WORK/low.json" '.required' "false"

HUMAN="$WORK/project/.signum/contracts/sig-codex-human"
write_contract_root "$HUMAN" high HUMAN_REVIEW
rm -f "$HUMAN/reviews/codex.json"
jq 'del(.agentReviewCoverage, .agentReviewArtifacts)' "$HUMAN/audit_summary.json" > "$HUMAN/audit_summary.tmp" \
  && mv "$HUMAN/audit_summary.tmp" "$HUMAN/audit_summary.json"
jq 'del(.checks.reviews.codex, .artifactRefs)' "$HUMAN/proofpack.json" > "$HUMAN/proofpack.tmp" \
  && mv "$HUMAN/proofpack.tmp" "$HUMAN/proofpack.json"
assert_ok "high HUMAN_REVIEW without Codex review is not gated" "$HUMAN" "$WORK/human.json"

MISSING="$WORK/project/.signum/contracts/sig-codex-missing"
write_contract_root "$MISSING" medium AUTO_OK
rm -f "$MISSING/reviews/codex.json"
assert_fail_violation "missing Codex review file fails" "$MISSING" "codex_review.missing" "$WORK/missing-review.json"

DEGRADED="$WORK/project/.signum/contracts/sig-codex-degraded"
write_contract_root "$DEGRADED" medium AUTO_OK
jq '.agentReviewCoverage.codex = "runtime_error"' "$DEGRADED/audit_summary.json" > "$DEGRADED/audit_summary.tmp" \
  && mv "$DEGRADED/audit_summary.tmp" "$DEGRADED/audit_summary.json"
assert_fail_violation "degraded Codex review coverage fails" "$DEGRADED" "agent_review.coverage_not_ready" "$WORK/degraded.json"

UNRECORDED="$WORK/project/.signum/contracts/sig-codex-unrecorded"
write_contract_root "$UNRECORDED" medium AUTO_OK
jq 'del(.agentReviewArtifacts)' "$UNRECORDED/audit_summary.json" > "$UNRECORDED/audit_summary.tmp" \
  && mv "$UNRECORDED/audit_summary.tmp" "$UNRECORDED/audit_summary.json"
assert_fail_violation "missing audit artifact reference fails" "$UNRECORDED" "agent_review.artifact_not_recorded" "$WORK/unrecorded.json"

UNPACKED="$WORK/project/.signum/contracts/sig-codex-unpacked"
write_contract_root "$UNPACKED" medium AUTO_OK
jq 'del(.checks.reviews.codex, .artifactRefs)' "$UNPACKED/proofpack.json" > "$UNPACKED/proofpack.tmp" \
  && mv "$UNPACKED/proofpack.tmp" "$UNPACKED/proofpack.json"
assert_fail_violation "missing proofpack Codex review evidence fails" "$UNPACKED" "proofpack.codex_review_missing" "$WORK/unpacked.json"

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
