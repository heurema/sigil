## Phase 5: RECONCILE

**Goal:** Resolve post-implementation obligations and update project state. Runs only when `cleanupObligations` is present and non-empty in the contract, AND the audit decision is `AUTO_OK`.

**Skip if:** `cleanupObligations` is absent/empty, OR decision is `AUTO_BLOCK` or `HUMAN_REVIEW`.

### Step 5.1: Check obligations

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"

OBLIGATIONS=$(jq -r '.cleanupObligations // [] | length' "$CONTRACT_PATH")
DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
if [ "$OBLIGATIONS" -eq 0 ] || [ "$DECISION" != "AUTO_OK" ]; then
  echo "RECONCILE skipped (obligations=$OBLIGATIONS, decision=$DECISION)"
else
  echo "RECONCILE: $OBLIGATIONS obligation(s) to resolve"
  jq -r '.cleanupObligations[] | "  - [\(.action)] \(.target): \(.description)"' "$CONTRACT_PATH"
fi
```

If skipped, proceed directly to Final Output.

### Step 5.2: Resolve obligations

Use the Agent tool to launch a general-purpose agent (model: sonnet) with this prompt:

```
You are the RECONCILE agent for Signum. Your job is to resolve cleanup obligations after a successful implementation.

The canonical artifact root for the active contract is `.signum/contracts/<activeContractId>/`.
If needed, use `.signum/contracts/index.json.activeContractId` to locate it.

Read `contract.json` under that canonical artifact root — the `cleanupObligations` array lists what needs to be done.
Read `proofpack.json` under that same canonical artifact root — the `summary` field describes what was implemented.

For each obligation:

1. action=update_roadmap: Read the target file (e.g. docs/roadmap.md). Find items that correspond to the implemented acceptance criteria (from contract.json). Mark them as done ([x]). Do NOT change items unrelated to this contract.

2. action=update_status: Read the target file. Update the status/version field to reflect completion. Minimal change only.

3. action=update_docs: Read the target file. Update descriptions that reference the changed modules. Minimal change — only fix what is now inaccurate.

4. action=remove_code: Check if the target path still exists and is no longer imported/used. If safe to remove, delete it. If still referenced, add a TODO comment instead.

5. action=update_manifest: Read the target file and update lifecycle/status fields.

After resolving each obligation, report what you did.
Write a summary to `reconcile_report.json` under the same canonical artifact root:
{
  "obligations_total": N,
  "resolved": N,
  "skipped": N,
  "details": [
    {"action": "...", "target": "...", "status": "resolved|skipped", "what_changed": "..."}
  ]
}
```

### Step 5.3: Verify resolution

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_TMP_PATH="${CONTRACT_PATH%.json}-tmp.json"
RECONCILE_REPORT_PATH="${ARTIFACT_ROOT}reconcile_report.json"

if [ ! -f "$RECONCILE_REPORT_PATH" ]; then
  echo "WARNING: reconcile_report.json missing — RECONCILE agent may have failed"
else
  RESOLVED=$(jq '.resolved' "$RECONCILE_REPORT_PATH")
  TOTAL=$(jq '.obligations_total' "$RECONCILE_REPORT_PATH")
  SKIPPED=$(jq '.skipped' "$RECONCILE_REPORT_PATH")
  echo "RECONCILE: $RESOLVED/$TOTAL resolved, $SKIPPED skipped"
  jq -r '.details[] | "  [\(.status)] \(.action) \(.target): \(.what_changed)"' "$RECONCILE_REPORT_PATH"

  # Update contract: mark resolved obligations
  RECONCILE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg ts "$RECONCILE_TS" \
    '(.cleanupObligations // []) |= [.[] | . + {resolvedAt: $ts}] | .timestamps.reconciledAt = $ts' \
    "$CONTRACT_PATH" > "$CONTRACT_TMP_PATH" && \
    mv "$CONTRACT_TMP_PATH" "$CONTRACT_PATH"
fi
```

### Step 5.4: Write retrospective (medium/high risk only)

**Skip for low risk.**

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
EXECUTE_LOG_PATH="${ARTIFACT_ROOT}execute_log.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
RETRO_PATH="${ARTIFACT_ROOT}retro.json"

RISK=$(jq -r '.riskLevel' "$CONTRACT_PATH")
if [ "$RISK" = "low" ]; then
  echo "Retro skipped (low risk)"
else
  INSCOPE_COUNT=$(jq '.inScope | length' "$CONTRACT_PATH")
  CHANGED_COUNT=$(git diff --name-only | wc -l | tr -d ' ')
  ATTEMPTS=$(jq -r '.totalAttempts // "?"' "$EXECUTE_LOG_PATH")
  ITERATIONS=$(jq -r '.iterationsUsed // 1' "$AUDIT_SUMMARY_PATH")
  FINDINGS=$(jq '[.reviews[].findings[]?] | length' "$AUDIT_SUMMARY_PATH" 2>/dev/null || echo 0)

  cat > "$RETRO_PATH" << RETRO
{
  "estimated_files": $INSCOPE_COUNT,
  "actual_files": $CHANGED_COUNT,
  "scope_accuracy": "$(echo "scale=2; $INSCOPE_COUNT / ($CHANGED_COUNT + 0.001)" | bc 2>/dev/null || echo "?")",
  "execute_attempts": $ATTEMPTS,
  "audit_iterations": $ITERATIONS,
  "total_findings": $FINDINGS,
  "risk_level": "$RISK",
  "risk_accurate": $([ "$INSCOPE_COUNT" -le 15 ] && [ "$RISK" != "high" ] && echo true || echo false)
}
RETRO
  echo "Retro written: estimated=$INSCOPE_COUNT actual=$CHANGED_COUNT attempts=$ATTEMPTS iterations=$ITERATIONS findings=$FINDINGS"
fi
```

---

