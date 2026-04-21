#!/usr/bin/env bash
# test-metric-ratchet.sh -- project-root-aware path behavior for lib/metric-ratchet.sh
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
RATCHET_SCRIPT="$ROOT_DIR/lib/metric-ratchet.sh"

passed=0
failed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_ok() {
  local name="$1"
  shift
  if "$@" >/tmp/test_out.$$ 2>&1; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s\n' "$name"
    sed 's/^/    /' /tmp/test_out.$$
    failed=$((failed + 1))
  fi
  rm -f /tmp/test_out.$$
}

make_dates() {
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
print((now - timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
print((now - timedelta(days=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
}

scenario_project_root_env() {
  local repo outside current_ts previous_ts report_file
  repo="$WORK/repo"
  outside="$WORK/outside"
  report_file="$repo/.signum/metrics/ratchet-report.json"
  mkdir -p "$repo/.signum" "$outside"
  read -r current_ts previous_ts < <(make_dates | tr '\n' ' ')
  cat > "$repo/.signum/proofpack-index.jsonl" <<EOFJSON
{"runId":"sig-run-current","contractId":"sig-current","createdAt":"$current_ts","decision":"AUTO_OK","releaseVerdict":"PROMOTE","riskLevel":"low","confidence":92,"reviewCoverage":2,"schemaVersion":"4.7","summary":"ok","proofpack_sha256":"abc","prev_hash":"genesis","chain_hash":"def"}
{"runId":"sig-run-previous","contractId":"sig-previous","createdAt":"$previous_ts","decision":"AUTO_BLOCK","releaseVerdict":"HOLD","riskLevel":"low","confidence":40,"reviewCoverage":1,"schemaVersion":"4.7","summary":"blocked","proofpack_sha256":"ghi","prev_hash":"def","chain_hash":"jkl"}
EOFJSON

  (
    cd "$outside"
    SIGNUM_PROJECT_ROOT="$repo" "$RATCHET_SCRIPT" 7 7 >/dev/null
  )

  test -f "$report_file"
  test ! -f "$outside/.signum/metrics/ratchet-report.json"
  [[ "$(jq -r '.current.count' "$report_file")" == "1" ]]
  [[ "$(jq -r '.previous.count' "$report_file")" == "1" ]]
}

scenario_inside_repo_still_works() {
  local repo current_ts previous_ts report_file
  repo="$WORK/repo-inside"
  report_file="$repo/.signum/metrics/ratchet-report.json"
  mkdir -p "$repo/.signum"
  read -r current_ts previous_ts < <(make_dates | tr '\n' ' ')
  cat > "$repo/.signum/proofpack-index.jsonl" <<EOFJSON
{"runId":"sig-run-current-2","contractId":"sig-current-2","createdAt":"$current_ts","decision":"HUMAN_REVIEW","releaseVerdict":"HOLD","riskLevel":"medium","confidence":55,"reviewCoverage":2,"schemaVersion":"4.7","summary":"review","proofpack_sha256":"aaa","prev_hash":"genesis","chain_hash":"bbb"}
{"runId":"sig-run-previous-2","contractId":"sig-previous-2","createdAt":"$previous_ts","decision":"AUTO_OK","releaseVerdict":"PROMOTE","riskLevel":"low","confidence":80,"reviewCoverage":2,"schemaVersion":"4.7","summary":"ok","proofpack_sha256":"ccc","prev_hash":"bbb","chain_hash":"ddd"}
EOFJSON

  (
    cd "$repo"
    "$RATCHET_SCRIPT" 7 7 >/dev/null
  )

  test -f "$report_file"
  [[ -n "$(jq -r '.status' "$report_file")" ]]
}

echo "=== Metric ratchet paths ==="
assert_ok "metric-ratchet honors SIGNUM_PROJECT_ROOT for project-level outputs" scenario_project_root_env
assert_ok "metric-ratchet still works when run inside the repo" scenario_inside_repo_still_works

echo ""
echo "Passed: $passed"
echo "Failed: $failed"
if [[ "$failed" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
