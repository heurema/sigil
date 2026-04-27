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
  echo "Anti-entropy: $(jq -r ' .status + " — " + .summary' "$ANTI_ENTROPY_PATH" 2>/dev/null || echo 'unknown')"
fi
if [ -f "${ARTIFACT_ROOT}reconcile_report.json" ]; then
  echo "Reconcile: $(jq '.resolved' "${ARTIFACT_ROOT}reconcile_report.json")/$(jq '.obligations_total' "${ARTIFACT_ROOT}reconcile_report.json") obligations resolved"
fi
```

Then display the appropriate next steps based on the decision:

- **AUTO_OK**: "Changes are verified. Review `combined.patch` under the canonical artifact root shown above and commit when ready."
- **AUTO_BLOCK**: "Issues found. Review `audit_summary.json` under the canonical artifact root shown above and fix before committing."
- **HUMAN_REVIEW**: "Audit inconclusive. Review `audit_summary.json` under the canonical artifact root shown above, then either: (1) refine acceptance criteria and re-run `/signum`, or (2) manually verify the flagged findings."

---

