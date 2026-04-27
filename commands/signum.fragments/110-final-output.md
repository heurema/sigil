## Final Output

Display to the user:

Use the Bash tool to list all produced artifacts:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
PROOFPACK_PATH="${ARTIFACT_ROOT}proofpack.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
DIFF_PATH="${ARTIFACT_ROOT}combined.patch"
ANTI_ENTROPY_PATH="${ARTIFACT_ROOT}anti_entropy_report.json"

echo "=== Canonical artifact root ==="
echo "$ARTIFACT_ROOT"
echo ""
echo "=== Artifacts ==="
if [ -d "$ARTIFACT_ROOT" ]; then
  (
    cd "$ARTIFACT_ROOT" &&
    find . -maxdepth 2 -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort
  )
else
  echo "WARNING: artifact root not found"
fi
echo ""
echo "Decision:   $(jq -r .decision "$PROOFPACK_PATH")"
echo "Confidence: $(jq -r '.confidence.overall' "$PROOFPACK_PATH")%"
echo "Run ID:     $(jq -r .runId "$PROOFPACK_PATH")"
if [ -f "$ANTI_ENTROPY_PATH" ]; then
  echo "Anti-entropy: $(jq -r '.status + \" — \" + .summary' "$ANTI_ENTROPY_PATH" 2>/dev/null || echo 'unknown')"
fi
```

Then display the appropriate next steps based on the decision:

- **AUTO_OK**: "Changes are verified. Review `combined.patch` under the canonical artifact root shown above and commit when ready."
- **AUTO_BLOCK**: "Issues found. Review `audit_summary.json` under the canonical artifact root shown above and fix before committing."
- **HUMAN_REVIEW**: "Audit inconclusive. Review `audit_summary.json` under the canonical artifact root shown above, then either: (1) refine acceptance criteria and re-run `/signum`, or (2) manually verify the flagged findings."

### Step 4.5: Finalize run (artifact cleanup)

After displaying results, finalize the current run to prevent stale artifacts from confusing subsequent invocations.

**Decision-based behavior:**

- **AUTO_OK** → auto-finalize (archive + purge working set). Zero-friction success path.
- **HUMAN_REVIEW** → ask the user: "Pipeline complete (HUMAN_REVIEW). Artifacts remain under the canonical artifact root shown above. Options: (1) archive — save to .signum/archive/ and clean working set, (2) keep — leave all artifacts for review, (3) delete — remove working set entirely." Default if no answer: keep.
- **AUTO_BLOCK** → ask the user: "Pipeline blocked (AUTO_BLOCK). Options: (1) keep — leave artifacts under the canonical artifact root for debugging (default), (2) delete — remove the working set." Default if no answer: keep.

**Finalize flow (archive + purge):**

Use the Bash tool:

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
AUDIT_SUMMARY_PATH="${ARTIFACT_ROOT}audit_summary.json"
DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")

finalize_run() {
  ARCHIVE_TMP=$(mktemp -d .signum/archive-tmp.XXXXXX)
  archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_TMP"

  if [ ! -f "$ARCHIVE_TMP/contract.json" ] || [ ! -f "$ARCHIVE_TMP/proofpack.json" ]; then
    echo "ERROR: archive incomplete — keeping working set intact"
    rm -rf "$ARCHIVE_TMP"
    return 1
  fi

  if [ -n "$CONTRACT_ID" ]; then
    ARCHIVE_FINAL=".signum/archive/${CONTRACT_ID}"
    mkdir -p "$ARCHIVE_FINAL"
    cp -R "$ARCHIVE_TMP"/. "$ARCHIVE_FINAL"/
  fi
  rm -rf "$ARCHIVE_TMP"

  source lib/session-manager.sh 2>/dev/null || true
  if type session_append &>/dev/null; then
    GOAL=$(jq -r '.goal // "unknown"' "$CONTRACT_PATH" 2>/dev/null | head -c 120)
    if [ "$DECISION" = "AUTO_OK" ]; then
      session_append "success" "AUTO_OK: $GOAL"
    elif [ "$DECISION" = "AUTO_BLOCK" ]; then
      REASON=$(jq -r '.reasoning // "unknown"' "$AUDIT_SUMMARY_PATH" 2>/dev/null | head -c 120)
      session_append "failure" "AUTO_BLOCK ($REASON): $GOAL"
    elif [ "$DECISION" = "HUMAN_REVIEW" ]; then
      session_append "model_disagreement" "HUMAN_REVIEW: $GOAL"
    fi
    if jq -e '.reviews | to_entries[] | select(.value.findings[]? | .category == "scope")' "$AUDIT_SUMMARY_PATH" &>/dev/null; then
      session_append "scope_violation" "Scope issue detected in: $GOAL" 8
    fi
  fi

  clear_active_contract >/dev/null 2>&1 || true
  purge_root_working_set_views >/dev/null 2>&1 || true

  echo "Run finalized: archived to .signum/archive/$CONTRACT_ID/, working set cleaned"
}

if [ "$DECISION" = "AUTO_OK" ]; then
  finalize_run
fi
```

If `DECISION` is `AUTO_OK`, finalize runs automatically. For `HUMAN_REVIEW` or `AUTO_BLOCK`, wait for the user's choice (prompted above), then run one of the following bash blocks (each is self-contained — variables must be re-resolved since each Bash tool call gets a fresh shell):

**If user chooses "archive":**

```bash
source lib/contract-dir.sh 2>/dev/null || true
ARTIFACT_ROOT="$(active_artifact_root 2>/dev/null || echo .signum/)"
CONTRACT_PATH="${ARTIFACT_ROOT}contract.json"
CONTRACT_ID=$(jq -r '.contractId // empty' "$CONTRACT_PATH")
ARCHIVE_TMP=$(mktemp -d .signum/archive-tmp.XXXXXX)
archive_contract_artifacts "$CONTRACT_ID" "$ARCHIVE_TMP"
if [ ! -f "$ARCHIVE_TMP/contract.json" ] || [ ! -f "$ARCHIVE_TMP/proofpack.json" ]; then
  echo "ERROR: archive incomplete — keeping working set intact"
  rm -rf "$ARCHIVE_TMP"; exit 1
fi
if [ -n "$CONTRACT_ID" ]; then
  mkdir -p ".signum/archive/${CONTRACT_ID}"
  cp -R "$ARCHIVE_TMP"/. ".signum/archive/${CONTRACT_ID}/"
fi
rm -rf "$ARCHIVE_TMP"
clear_active_contract >/dev/null 2>&1 || true
purge_root_working_set_views >/dev/null 2>&1 || true
echo "Run finalized: archived to .signum/archive/$CONTRACT_ID/, working set cleaned"
```

**If user chooses "delete":**

```bash
source lib/contract-dir.sh 2>/dev/null || true
clear_active_contract >/dev/null 2>&1 || true
purge_root_working_set_views >/dev/null 2>&1 || true
echo "Working set deleted (no archive)"
```

**If user chooses "keep" or does not respond:** do nothing.

---

