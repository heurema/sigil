## Phase 4: PACK

**Goal:** Bundle all artifacts into a self-contained, verifiable proof package (schema v4.8) with embedded artifact contents.

### Step 4.0: Transition contract status to completed

Transition the contract status from `active` to `completed` and record the `completedAt` timestamp:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_TMP_PATH="${CONTRACT_PATH%.json}-tmp.json"
COMPLETED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg ts "$COMPLETED_TS" \
  '.status = "completed" | .timestamps.completedAt = $ts' \
  "$CONTRACT_PATH" > "$CONTRACT_TMP_PATH" && \
  mv "$CONTRACT_TMP_PATH" "$CONTRACT_PATH"
echo "Contract status: active → completed at $COMPLETED_TS"
```

### Step 4.1: Collect metadata and build proofpack

Use the Bash tool:

```bash
# Cross-platform sha256 helper
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  echo "ERROR: no sha256 tool found"; exit 1
fi

hash_file() {
  local f="$1"
  [ -f "$f" ] || { echo "missing"; return; }
  $HASH_CMD "$f" | awk '{print $1}'
}

file_size() {
  local f="$1"
  [ -f "$f" ] || { echo "0"; return; }
  wc -c < "$f" | tr -d ' '
}

source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
BASELINE_PATH="${ARTIFACT_ROOT}baseline.json"
COMBINED_PATCH_PATH="${ARTIFACT_ROOT}combined.patch"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
MECHANIC_REPORT_PATH="${ARTIFACT_ROOT}mechanic_report.json"
HOLDOUT_REPORT_PATH="${ARTIFACT_ROOT}holdout_report.json"
POLICY_SCAN_PATH="${ARTIFACT_ROOT}policy_scan.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
APPROVAL_PATH="${ARTIFACT_ROOT}approval.json"
PROOFPACK_PATH="${ARTIFACT_ROOT}proofpack.json"
ANTI_ENTROPY_PATH="${ARTIFACT_ROOT}anti_entropy_report.json"
CONTRACT_HASH_PATH="${ARTIFACT_ROOT}contract-hash.txt"
EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
AUDIT_ITERATION_LOG_PATH="${ARTIFACT_ROOT}audit_iteration_log.json"
REVIEWS_DIR="${ARTIFACT_ROOT}reviews"
RECEIPTS_EXEC_PATH="${ARTIFACT_ROOT}receipts/execute.json"

# Metadata
DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
GOAL=$(jq -r '.goal' "$CONTRACT_PATH")
RISK=$(jq -r '.riskLevel' "$CONTRACT_PATH")
ATTEMPTS=$(jq -r '.totalAttempts' "$EXECUTE_LOG_PATH" 2>/dev/null || echo "unknown")
MECHANIC=$(jq -r '.mechanic' "$AUDIT_SUMMARY_PATH")
CONFIDENCE=$(jq -r '.confidence.overall // 0' "$AUDIT_SUMMARY_PATH")
RUN_DATE=$(date +%Y-%m-%dT%H:%M:%SZ)
RUN_RANDOM=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
RUN_ID="signum-$(date +%Y-%m-%d)-${RUN_RANDOM}"

# Audit chain
CONTRACT_HASH=$(grep 'contract_sha256:' "$CONTRACT_HASH_PATH" 2>/dev/null | awk '{print $2}' || echo "unavailable")
APPROVED_AT=$(grep 'approved_at:' "$CONTRACT_HASH_PATH" 2>/dev/null | awk '{print $2}' || echo "unavailable")
BASE_COMMIT=$(jq -r '.base_commit // "unavailable"' "$EXECUTION_CONTEXT_PATH" 2>/dev/null || echo "unavailable")

# Contract redaction: strip holdoutScenarios, save to temp file
REDACTED_CONTRACT=$(mktemp /tmp/signum-contract-redacted.XXXXXX.json)
python3 - "$CONTRACT_PATH" <<'PY' > "$REDACTED_CONTRACT"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
data.pop('holdoutScenarios', None)
json.dump(data, sys.stdout)
PY

CONTRACT_SHA256=$(hash_file "$REDACTED_CONTRACT")
CONTRACT_FULL_SHA256=$(hash_file "$CONTRACT_PATH")

# Envelope builder: embeds file content if <=102400 bytes, else omits
# JSON files (.json) are embedded as objects, text files as strings
build_envelope() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo '{"content":null,"sha256":null,"sizeBytes":0,"status":"error","omitReason":"file not found"}'
    return
  fi
  local sha
  sha=$(hash_file "$path")
  local size
  size=$(file_size "$path")
  if [ "$size" -le 102400 ]; then
    local content
    if [[ "$path" == *.json ]]; then
      content=$(cat "$path")
    else
      content=$(jq -Rs . < "$path")
    fi
    printf '{"content":%s,"sha256":"%s","sizeBytes":%s,"status":"present"}' \
      "$content" "$sha" "$size"
  else
    printf '{"content":null,"sha256":"%s","sizeBytes":%s,"status":"omitted","omitReason":"size exceeds 100 KiB"}' \
      "$sha" "$size"
  fi
}

# Contract envelope (special: has both sha256 of redacted and fullSha256 of original)
CONTRACT_SIZE=$(file_size "$REDACTED_CONTRACT")
if [ "$CONTRACT_SIZE" -le 102400 ]; then
  CONTRACT_CONTENT=$(cat "$REDACTED_CONTRACT")
  CONTRACT_ENV=$(printf '{"content":%s,"sha256":"%s","fullSha256":"%s","sizeBytes":%s,"status":"present"}' \
    "$CONTRACT_CONTENT" "$CONTRACT_SHA256" "$CONTRACT_FULL_SHA256" "$CONTRACT_SIZE")
else
  CONTRACT_ENV=$(printf '{"content":null,"sha256":"%s","fullSha256":"%s","sizeBytes":%s,"status":"omitted","omitReason":"size exceeds 100 KiB"}' \
    "$CONTRACT_SHA256" "$CONTRACT_FULL_SHA256" "$CONTRACT_SIZE")
fi

# Diff embedding
DIFF_ENV=$(build_envelope "$COMBINED_PATCH_PATH")

# Baseline envelope (optional artifact)
BASELINE_ENV=$(build_envelope "$BASELINE_PATH")

# Execute log envelope
EXECUTE_ENV=$(build_envelope "$EXECUTE_LOG_PATH")

# Mechanic and holdout envelopes
MECHANIC_ENV=$(build_envelope "$MECHANIC_REPORT_PATH")
HOLDOUT_ENV=$(build_envelope "$HOLDOUT_REPORT_PATH")

# Policy scan envelope — written to temp file so jq reads content directly,
# avoiding shell variable limits on large reports.
POLICY_SCAN_ENV_TMP=$(mktemp)
trap 'rm -f "$POLICY_SCAN_ENV_TMP"' EXIT
build_envelope "$POLICY_SCAN_PATH" > "$POLICY_SCAN_ENV_TMP"

# Audit summary envelope
AUDIT_ENV=$(build_envelope "$AUDIT_SUMMARY_PATH")

# Approval envelope
APPROVAL_ENV=$(build_envelope "$APPROVAL_PATH")

# Dynamic reviews: enumerate canonical reviews/*.json
REVIEWS_JSON='{'
first=1
for review_file in "$REVIEWS_DIR"/*.json; do
  [ -f "$review_file" ] || continue
  provider=$(basename "$review_file" .json)
  env_json=$(build_envelope "$review_file")
  if [ "$first" -eq 1 ]; then
    REVIEWS_JSON="${REVIEWS_JSON}\"${provider}\":${env_json}"
    first=0
  else
    REVIEWS_JSON="${REVIEWS_JSON},\"${provider}\":${env_json}"
  fi
done
REVIEWS_JSON="${REVIEWS_JSON}}"

# Detect contract source
if [ -n "${SIGNUM_CONTRACT_PATH:-}" ]; then
  CONTRACT_SOURCE="file"
else
  CONTRACT_SOURCE="interactive"
fi

# Detect CI context
CI_CONTEXT="null"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  CI_PROVIDER="github-actions"
  CI_RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  CI_PR_NUMBER=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null || true)
  CI_TRIGGER="${GITHUB_EVENT_NAME:-unknown}"
  CI_CONTEXT=$(jq -n \
    --arg provider "$CI_PROVIDER" \
    --arg runUrl "$CI_RUN_URL" \
    --arg trigger "$CI_TRIGGER" \
    '{provider: $provider, runUrl: $runUrl, triggerEvent: $trigger}')
  [ -n "$CI_PR_NUMBER" ] && CI_CONTEXT=$(echo "$CI_CONTEXT" | jq --argjson pr "$CI_PR_NUMBER" '. + {prNumber: $pr}')
fi

# Baseline comparison: find previous proofpack if exists
BASELINE_COMP="null"
PREV_PROOFPACK=$(ls -t .signum/contracts/*/proofpack.json 2>/dev/null | head -1 || true)
if [ -n "$PREV_PROOFPACK" ] && [ -f "$PREV_PROOFPACK" ]; then
  PREV_RUN_ID=$(jq -r '.runId // empty' "$PREV_PROOFPACK" 2>/dev/null || true)
  PREV_DECISION=$(jq -r '.decision // empty' "$PREV_PROOFPACK" 2>/dev/null || true)
  PREV_CONFIDENCE=$(jq -r '.confidence.overall // 0' "$PREV_PROOFPACK" 2>/dev/null || echo 0)
  CONF_DELTA=$(echo "$CONFIDENCE - $PREV_CONFIDENCE" | bc 2>/dev/null || echo 0)
  if [ -n "$PREV_RUN_ID" ]; then
    BASELINE_COMP=$(jq -n \
      --arg prevId "$PREV_RUN_ID" \
      --arg prevDec "$PREV_DECISION" \
      --argjson prevConf "$PREV_CONFIDENCE" \
      --argjson delta "$CONF_DELTA" \
      '{previousRunId: $prevId, previousDecision: $prevDec, previousConfidence: $prevConf, confidenceDelta: $delta}')
  fi
fi

# Extract contractId for lineage
PACK_CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")

# Read iteration metadata for iterativeAudit section
ITERATIONS_USED_PACK=$(jq -r '.iterationsUsed // 1' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo 1)
BEST_ITERATION_PACK=$(jq -r '.bestIteration // 1' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo 1)
ITERATIVE_AUDIT_JSON="null"
if [ "$ITERATIONS_USED_PACK" -gt 1 ] && [ -f "$AUDIT_ITERATION_LOG_PATH" ]; then
  # Read audit_summary metadata fields required by iterativeAudit schema
  PACK_ITERS_MAX=$(jq -r '.iterationsMax // 20' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo 20)
  PACK_EARLY_STOP=$(jq -r '.earlyStop // false' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo false)
  PACK_EARLY_STOP_REASON=$(jq -r '.earlyStopReason // ""' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "")
  PACK_TERMINAL_REASON=$(jq -r '.terminalReason // ""' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "")
  PACK_REMAINING_SEV=$(jq -r '.remainingSeverity // "none"' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "none")
  # Build resolvedFindings: findings present in pass 1 but absent in best pass (by fingerprint)
  # Use .pass field lookup instead of array index to handle sparse logs from skipped iterations
  PACK_RESOLVED=$(jq -n \
    --argjson log "$(cat "$AUDIT_ITERATION_LOG_PATH")" \
    --argjson best "$BEST_ITERATION_PACK" \
    '($log[0].canonicalFindings // []) as $first |
     (($log[] | select(.pass == $best)).canonicalFindings // []) as $last |
     ($last | map(.fingerprint // (.file + ":" + (.line|tostring) + ":" + .category))) as $lastFps |
     [$first[] | select((.fingerprint // (.file + ":" + (.line|tostring) + ":" + .category)) as $fp | $lastFps | index($fp) | not)]')
  # Build remainingFindings: findings present in the best pass
  # Use .pass field lookup instead of array index to handle sparse logs from skipped iterations
  PACK_REMAINING=$(jq --argjson best "$BEST_ITERATION_PACK" '(.[].pass as $p | select($p == $best) | .canonicalFindings) // []' "$AUDIT_ITERATION_LOG_PATH" 2>/dev/null || echo "[]")
  ITERATIVE_AUDIT_JSON=$(jq -n \
    --argjson iters_used "$ITERATIONS_USED_PACK" \
    --argjson iters_max "$PACK_ITERS_MAX" \
    --argjson best "$BEST_ITERATION_PACK" \
    --argjson early_stop "$PACK_EARLY_STOP" \
    --arg early_stop_reason "$PACK_EARLY_STOP_REASON" \
    --arg terminal_reason "$PACK_TERMINAL_REASON" \
    --arg remaining_sev "$PACK_REMAINING_SEV" \
    --argjson resolved "$PACK_RESOLVED" \
    --argjson remaining "$PACK_REMAINING" \
    --argjson log "$(cat "$AUDIT_ITERATION_LOG_PATH")" \
    '{iterationsUsed: $iters_used, iterationsMax: $iters_max, bestIteration: $best,
      earlyStop: $early_stop, earlyStopReason: $early_stop_reason,
      terminalReason: $terminal_reason, remainingSeverity: $remaining_sev,
      resolvedFindings: $resolved, remainingFindings: $remaining,
      auditIterations: $log}')
fi

# Receipt metadata (specpunk receipt v1 compatible fields)
PACK_STARTED_AT=$(jq -r '.started_at // empty' "$EXECUTE_LOG_PATH" 2>/dev/null || echo "$RUN_DATE")
PACK_DURATION_MS=$(jq -r '.duration_ms // 0' "$EXECUTE_LOG_PATH" 2>/dev/null || echo "0")
PACK_RISK_LEVEL=$(jq -r '.riskLevel // "low"' "$CONTRACT_PATH" 2>/dev/null || echo "low")
PACK_RELEASE_VERDICT=$(jq -r '.releaseVerdict // "HOLD"' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "HOLD")
PACK_AVAILABLE_REVIEWS=$(jq -r '.availableReviews // 0' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo "0")

# Final assembly
jq -n \
  --arg schemaVersion "4.8" \
  --arg signumVersion "4.21.6" \
  --arg createdAt "$RUN_DATE" \
  --arg runId "$RUN_ID" \
  --arg contractId "$PACK_CONTRACT_ID" \
  --arg decision "$DECISION" \
  --arg summary "Goal: $GOAL | Risk: $RISK | Attempts: $ATTEMPTS | Mechanic: $MECHANIC | Confidence: ${CONFIDENCE}% | Decision: $DECISION" \
  --argjson confidence "$CONFIDENCE" \
  --arg contractHash "$CONTRACT_HASH" \
  --arg approvedAt "$APPROVED_AT" \
  --arg baseCommit "$BASE_COMMIT" \
  --argjson contractEnv "$CONTRACT_ENV" \
  --argjson diffEnv "$DIFF_ENV" \
  --argjson baselineEnv "$BASELINE_ENV" \
  --argjson executeEnv "$EXECUTE_ENV" \
  --argjson mechanicEnv "$MECHANIC_ENV" \
  --argjson holdoutEnv "$HOLDOUT_ENV" \
  --slurpfile policyScanEnv "$POLICY_SCAN_ENV_TMP" \
  --argjson auditEnv "$AUDIT_ENV" \
  --argjson approvalEnv "$APPROVAL_ENV" \
  --argjson reviewsEnv "$REVIEWS_JSON" \
  --arg contractSource "$CONTRACT_SOURCE" \
  --argjson ciContext "$CI_CONTEXT" \
  --argjson baselineComp "$BASELINE_COMP" \
  --argjson iterativeAuditJson "$ITERATIVE_AUDIT_JSON" \
  --arg startedAt "$PACK_STARTED_AT" \
  --argjson durationMs "$PACK_DURATION_MS" \
  --arg riskLevel "$PACK_RISK_LEVEL" \
  --arg releaseVerdict "$PACK_RELEASE_VERDICT" \
  --argjson availableReviews "$PACK_AVAILABLE_REVIEWS" \
  '{
    schemaVersion: $schemaVersion,
    signumVersion: $signumVersion,
    createdAt: $createdAt,
    runId: $runId,
    contractId: (if $contractId != "" then $contractId else null end),
    decision: $decision,
    releaseVerdict: $releaseVerdict,
    riskLevel: $riskLevel,
    summary: $summary,
    confidence: { overall: $confidence },
    timing: { startedAt: $startedAt, completedAt: $createdAt, durationMs: $durationMs },
    reviewCoverage: { availableReviews: $availableReviews },
    contractSource: $contractSource,
    auditChain: {
      contractSha256: $contractHash,
      approvedAt: $approvedAt,
      baseCommit: $baseCommit
    },
    contract: $contractEnv,
    diff: $diffEnv,
    baseline: $baselineEnv,
    executeLog: $executeEnv,
    approval: $approvalEnv,
    checks: {
      mechanic: $mechanicEnv,
      holdout: $holdoutEnv,
      policy_scan: $policyScanEnv[0],
      reviews: $reviewsEnv,
      auditSummary: $auditEnv
    }
  }
  | if $ciContext != null then . + {ciContext: $ciContext} else . end
  | if $baselineComp != null then . + {baselineComparison: $baselineComp} else . end
  | if $iterativeAuditJson != null then . + {iterativeAudit: $iterativeAuditJson} else . end
  ' > "$PROOFPACK_PATH"

# Cleanup temp files
rm -f "$REDACTED_CONTRACT"

# Advisory anti-entropy artifact (non-blocking, report-only)
if [ -f lib/pack-anti-entropy.sh ]; then
  bash lib/pack-anti-entropy.sh \
    --project-root . \
    --contract "$CONTRACT_PATH" \
    --proofpack "$PROOFPACK_PATH" \
    --output "$ANTI_ENTROPY_PATH" || true
fi

echo "Proofpack written: $RUN_ID (schema v4.8)"
```

### Step 4.2: Update contract status

Use the Bash tool to transition the contract to `completed`:

```bash
if [ -f lib/contract-dir.sh ]; then
  source lib/contract-dir.sh
  ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
  CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
  EXECUTION_CONTEXT_PATH="${ARTIFACT_ROOT}execution_context.json"
  RECEIPTS_EXEC_PATH="${ARTIFACT_ROOT}receipts/execute.json"
  CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")
  if [ -n "$CONTRACT_ID" ]; then
    update_contract_status "$CONTRACT_ID" "completed"
    RUN_ID=$(jq -r '.run_id // empty' "$EXECUTION_CONTEXT_PATH" 2>/dev/null || true)
    if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
      RUN_ID=$(jq -r '.run_id // empty' "$RECEIPTS_EXEC_PATH" 2>/dev/null || true)
    fi
    # Verify durable canonical artifacts for this completed contract.
    verify_canonical_contract_artifacts "$CONTRACT_ID" \
      "contract.json" \
      "proofpack.json" \
      "anti_entropy_report.json" \
      "audit_summary.json" \
      "approval.json" \
      "execution_context.json" \
      "receipts" \
      "snapshots"
    if [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ]; then
      verify_canonical_contract_artifacts "$CONTRACT_ID" "runs/${RUN_ID}"
    fi
    echo "Contract $CONTRACT_ID → completed"
  fi
fi
```

---
