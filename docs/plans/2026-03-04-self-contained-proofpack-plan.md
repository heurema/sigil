# Self-Contained Proofpack v4.0 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Embed all artifact contents into proofpack.json so it's a single self-contained file for CI validation and audit trail.

**Architecture:** Replace string path references with envelope objects containing content + sha256 + sizeBytes + status. Schema bump v3 -> v4. Contract holdouts redacted with separate fullSha256.

**Tech Stack:** JSON Schema, jq, bash, python3 (for contract redaction)

**Design doc:** `docs/plans/2026-03-04-self-contained-proofpack-design.md`

---

### Task 1: Update proofpack.schema.json to v4.0

**Files:**
- Modify: `lib/schemas/proofpack.schema.json`

**Step 1: Read current schema**

Read `lib/schemas/proofpack.schema.json` to confirm current v3.0 structure.

**Step 2: Write new v4.0 schema**

Replace contents with:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["schemaVersion", "signumVersion", "createdAt", "runId", "decision", "summary", "contract", "diff", "checks"],
  "definitions": {
    "envelope": {
      "type": "object",
      "required": ["sha256", "sizeBytes", "status"],
      "properties": {
        "content": {},
        "sha256": { "type": ["string", "null"] },
        "sizeBytes": { "type": "integer", "minimum": 0 },
        "status": { "type": "string", "enum": ["present", "omitted", "error"] },
        "omitReason": { "type": "string" }
      }
    },
    "contractEnvelope": {
      "type": "object",
      "required": ["sha256", "sizeBytes", "status"],
      "properties": {
        "content": {},
        "sha256": { "type": ["string", "null"] },
        "fullSha256": { "type": "string" },
        "sizeBytes": { "type": "integer", "minimum": 0 },
        "status": { "type": "string", "enum": ["present", "omitted", "error"] },
        "omitReason": { "type": "string" }
      }
    }
  },
  "properties": {
    "schemaVersion": { "type": "string", "const": "4.0" },
    "signumVersion": { "type": "string" },
    "createdAt": { "type": "string", "format": "date-time" },
    "runId": { "type": "string", "pattern": "^signum-" },
    "decision": { "type": "string", "enum": ["AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW"] },
    "summary": { "type": "string" },
    "confidence": {
      "type": "object",
      "properties": {
        "overall": { "type": "number", "minimum": 0, "maximum": 100 }
      }
    },
    "auditChain": {
      "type": "object",
      "properties": {
        "contractSha256": { "type": "string" },
        "approvedAt": { "type": "string" },
        "baseCommit": { "type": "string" }
      }
    },
    "contract": { "$ref": "#/definitions/contractEnvelope" },
    "diff": { "$ref": "#/definitions/envelope" },
    "baseline": { "$ref": "#/definitions/envelope" },
    "executeLog": { "$ref": "#/definitions/envelope" },
    "checks": {
      "type": "object",
      "required": ["mechanic", "reviews", "auditSummary"],
      "properties": {
        "mechanic": { "$ref": "#/definitions/envelope" },
        "holdout": { "$ref": "#/definitions/envelope" },
        "reviews": {
          "type": "object",
          "additionalProperties": { "$ref": "#/definitions/envelope" }
        },
        "auditSummary": { "$ref": "#/definitions/envelope" }
      }
    }
  }
}
```

Key changes from v3:
- `const: "4.0"` for schemaVersion
- All artifact fields use `$ref: envelope` instead of `type: string`
- `contract` uses `contractEnvelope` (adds `fullSha256`)
- `checks.audit_summary` -> `checks.auditSummary`
- `checksums` field removed
- `reviews` uses `additionalProperties` (dynamic provider keys)
- New top-level: `signumVersion`, `createdAt`

**Step 3: Commit**

```bash
cd /Users/vi/personal/skill7/devtools/signum
git add lib/schemas/proofpack.schema.json
git commit -m "feat: proofpack schema v4.0 with envelope format"
```

---

### Task 2: Rewrite Phase 4 PACK in orchestrator

**Files:**
- Modify: `commands/signum.md` (lines 1060-1162, Phase 4 section)

**Step 1: Read current Phase 4**

Read `commands/signum.md` lines 1060-1162 to confirm current PACK implementation.

**Step 2: Replace Phase 4 with new embedding logic**

Replace the entire Phase 4 section (from `## Phase 4: PACK` through the `proofpack.json` write) with:

````markdown
## Phase 4: PACK

**Goal:** Embed all artifacts into a single self-contained proofpack.json.

### Step 4.1: Build self-contained proofpack

Use the Bash tool to assemble the proofpack with embedded artifact contents:

```bash
# Cross-platform sha256
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  echo "ERROR: no sha256 tool found"; exit 1
fi

hash_file() {
  $HASH_CMD "$1" 2>/dev/null | awk '{print $1}' || echo ""
}

file_size() {
  wc -c < "$1" 2>/dev/null | tr -d ' ' || echo "0"
}

# Metadata
ARTIFACT_ROOT=".signum/contracts/<contractId>"
CONTRACT_PATH="$ARTIFACT_ROOT/contract.json"
AUDIT_SUMMARY_PATH="$ARTIFACT_ROOT/audit_summary.json"
EXECUTE_LOG_PATH="$ARTIFACT_ROOT/execute_log.json"
BASELINE_PATH="$ARTIFACT_ROOT/baseline.json"
MECHANIC_REPORT_PATH="$ARTIFACT_ROOT/mechanic_report.json"
HOLDOUT_REPORT_PATH="$ARTIFACT_ROOT/holdout_report.json"
COMBINED_PATCH_PATH="$ARTIFACT_ROOT/combined.patch"
CONTRACT_HASH_PATH="$ARTIFACT_ROOT/contract-hash.txt"
EXECUTION_CONTEXT_PATH="$ARTIFACT_ROOT/execution_context.json"
REVIEWS_DIR="$ARTIFACT_ROOT/reviews"
PROOFPACK_PATH="$ARTIFACT_ROOT/proofpack.json"

DECISION=$(jq -r '.decision' "$AUDIT_SUMMARY_PATH")
GOAL=$(jq -r '.goal' "$CONTRACT_PATH")
RISK=$(jq -r '.riskLevel' "$CONTRACT_PATH")
ATTEMPTS=$(jq -r '.totalAttempts' "$EXECUTE_LOG_PATH" 2>/dev/null || echo "unknown")
MECHANIC=$(jq -r '.mechanic' "$AUDIT_SUMMARY_PATH")
CONFIDENCE=$(jq -r '.confidence.overall // 0' "$AUDIT_SUMMARY_PATH")
RUN_DATE=$(date +%Y-%m-%d)
RUN_RANDOM=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
RUN_ID="signum-${RUN_DATE}-${RUN_RANDOM}"
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Audit chain
CONTRACT_HASH=$(grep 'contract_sha256:' "$CONTRACT_HASH_PATH" 2>/dev/null | awk '{print $2}' || echo "unavailable")
APPROVED_AT=$(grep 'approved_at:' "$CONTRACT_HASH_PATH" 2>/dev/null | awk '{print $2}' || echo "unavailable")
BASE_COMMIT=$(jq -r '.base_commit // "unavailable"' "$EXECUTION_CONTEXT_PATH" 2>/dev/null || echo "unavailable")

# Contract: redact holdouts, compute both hashes
FULL_CONTRACT_SHA=$(hash_file "$CONTRACT_PATH")
FULL_CONTRACT_SIZE=$(file_size "$CONTRACT_PATH")
python3 -c "
import json, sys
with open('$CONTRACT_PATH') as f:
    c = json.load(f)
c.pop('holdoutScenarios', None)
json.dump(c, sys.stdout, indent=2)
" > /tmp/signum-contract-redacted.json
REDACTED_CONTRACT_SHA=$(hash_file /tmp/signum-contract-redacted.json)

# Diff: embed if <100KB, otherwise omit-but-hash
DIFF_SIZE=$(file_size "$COMBINED_PATCH_PATH")
DIFF_SHA=$(hash_file "$COMBINED_PATCH_PATH")
DIFF_THRESHOLD=102400
if [ "$DIFF_SIZE" -le "$DIFF_THRESHOLD" ]; then
  DIFF_STATUS="present"
  DIFF_REASON=""
else
  DIFF_STATUS="omitted"
  DIFF_REASON="exceeds 100KB threshold"
fi

# Helper: build envelope for a JSON artifact
build_envelope() {
  local FILE="$1"
  if [ -f "$FILE" ]; then
    local SHA=$(hash_file "$FILE")
    local SIZE=$(file_size "$FILE")
    local CONTENT=$(cat "$FILE")
    jq -n --arg sha "$SHA" --argjson size "$SIZE" --argjson content "$CONTENT" \
      '{content: $content, sha256: $sha, sizeBytes: $size, status: "present"}'
  else
    jq -n '{content: null, sha256: null, sizeBytes: 0, status: "error", omitReason: "file not found"}'
  fi
}

# Build each envelope
ENV_CONTRACT=$(jq -n \
  --argjson content "$(cat /tmp/signum-contract-redacted.json)" \
  --arg sha "$REDACTED_CONTRACT_SHA" \
  --arg fullSha "$FULL_CONTRACT_SHA" \
  --argjson size "$FULL_CONTRACT_SIZE" \
  '{content: $content, sha256: $sha, fullSha256: $fullSha, sizeBytes: $size, status: "present"}')

if [ "$DIFF_STATUS" = "present" ]; then
  DIFF_CONTENT=$(jq -Rs '.' "$COMBINED_PATCH_PATH")
  ENV_DIFF=$(jq -n --argjson content "$DIFF_CONTENT" --arg sha "$DIFF_SHA" --argjson size "$DIFF_SIZE" \
    '{content: $content, sha256: $sha, sizeBytes: $size, status: "present"}')
else
  ENV_DIFF=$(jq -n --arg sha "$DIFF_SHA" --argjson size "$DIFF_SIZE" --arg reason "$DIFF_REASON" \
    '{content: null, sha256: $sha, sizeBytes: $size, status: "omitted", omitReason: $reason}')
fi

ENV_BASELINE=$(build_envelope "$BASELINE_PATH")
ENV_EXEC_LOG=$(build_envelope "$EXECUTE_LOG_PATH")
ENV_MECHANIC=$(build_envelope "$MECHANIC_REPORT_PATH")
ENV_AUDIT=$(build_envelope "$AUDIT_SUMMARY_PATH")

# Holdout report (optional)
if [ -f "$HOLDOUT_REPORT_PATH" ]; then
  ENV_HOLDOUT=$(build_envelope "$HOLDOUT_REPORT_PATH")
else
  ENV_HOLDOUT=$(jq -n '{content: null, sha256: null, sizeBytes: 0, status: "omitted", omitReason: "no holdout scenarios"}')
fi

# Reviews (dynamic — enumerate $REVIEWS_DIR)
REVIEWS_JSON="{}"
if [ -d "$REVIEWS_DIR" ]; then
  for REVIEW_FILE in "$REVIEWS_DIR"/*.json; do
    [ -f "$REVIEW_FILE" ] || continue
    PROVIDER=$(basename "$REVIEW_FILE" .json)
    ENV=$(build_envelope "$REVIEW_FILE")
    REVIEWS_JSON=$(echo "$REVIEWS_JSON" | jq --arg p "$PROVIDER" --argjson e "$ENV" '. + {($p): $e}')
  done
fi

# Assemble final proofpack
jq -n \
  --arg schema "4.0" \
  --arg signumVer "4.0.0" \
  --arg createdAt "$CREATED_AT" \
  --arg runId "$RUN_ID" \
  --arg decision "$DECISION" \
  --arg summary "Goal: $GOAL | Risk: $RISK | Attempts: $ATTEMPTS | Mechanic: $MECHANIC | Confidence: ${CONFIDENCE}% | Decision: $DECISION" \
  --argjson confidence "$CONFIDENCE" \
  --arg contractSha "$CONTRACT_HASH" \
  --arg approvedAt "$APPROVED_AT" \
  --arg baseCommit "$BASE_COMMIT" \
  --argjson contract "$ENV_CONTRACT" \
  --argjson diff "$ENV_DIFF" \
  --argjson baseline "$ENV_BASELINE" \
  --argjson executeLog "$ENV_EXEC_LOG" \
  --argjson mechanic "$ENV_MECHANIC" \
  --argjson holdout "$ENV_HOLDOUT" \
  --argjson reviews "$REVIEWS_JSON" \
  --argjson auditSummary "$ENV_AUDIT" \
  '{
    schemaVersion: $schema,
    signumVersion: $signumVer,
    createdAt: $createdAt,
    runId: $runId,
    decision: $decision,
    summary: $summary,
    confidence: { overall: $confidence },
    auditChain: {
      contractSha256: $contractSha,
      approvedAt: $approvedAt,
      baseCommit: $baseCommit
    },
    contract: $contract,
    diff: $diff,
    baseline: $baseline,
    executeLog: $executeLog,
    checks: {
      mechanic: $mechanic,
      holdout: $holdout,
      reviews: $reviews,
      auditSummary: $auditSummary
    }
  }' > "$PROOFPACK_PATH"

rm -f /tmp/signum-contract-redacted.json
echo "Proofpack v4.0 written: $RUN_ID ($(file_size "$PROOFPACK_PATH") bytes)"
```
````

**Step 3: Verify the section integrates cleanly**

Read surrounding sections (Final Output at ~line 1166) to confirm no references to old `checksums` field or old proofpack fields need updating.

**Step 4: Update Final Output section**

The existing Final Output section (lines 1166-1186) should still work since it reads `decision`, `confidence.overall`, and `runId` — all present in v4. No changes needed. Verify by reading lines 1166-1186.

**Step 5: Commit**

```bash
cd /Users/vi/personal/skill7/devtools/signum
git add commands/signum.md
git commit -m "feat: Phase 4 embeds artifacts into self-contained proofpack v4.0"
```

---

### Task 3: Update docs/reference.md

**Files:**
- Modify: `docs/reference.md` (proofpack.json fields section, lines 127-136)

**Step 1: Read current proofpack docs**

Read `docs/reference.md` lines 92-136.

**Step 2: Update proofpack description and field table**

Replace the proofpack description at line 110:
```
| `proofpack.json` | Pack | Self-contained evidence bundle with embedded artifacts, checksums, and confidence |
```

Replace the proofpack.json fields table (lines 127-136) with:

```markdown
### proofpack.json fields (v4.0)

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `"4.0"` | Always "4.0" |
| `signumVersion` | string | Signum version that generated this proofpack |
| `createdAt` | string | ISO 8601 timestamp of proofpack creation |
| `runId` | string | `signum-YYYY-MM-DD-XXXXXX` |
| `decision` | `AUTO_OK\|AUTO_BLOCK\|HUMAN_REVIEW` | Final verdict |
| `summary` | string | One-line human-readable summary |
| `confidence` | object | `{ overall: 0-100 }` — weighted confidence score |
| `auditChain` | object | `{ contractSha256, approvedAt, baseCommit }` — immutable audit anchors |
| `contract` | envelope | Redacted contract (holdouts stripped), `fullSha256` for original |
| `diff` | envelope | Patch content (omitted if >100KB) |
| `baseline` | envelope | Pre-change lint/typecheck/test results |
| `executeLog` | envelope | Attempt history and check results |
| `checks.mechanic` | envelope | Lint, typecheck, test with regression flags |
| `checks.holdout` | envelope | Holdout scenario pass/fail (if applicable) |
| `checks.reviews.*` | envelope | Per-provider review (dynamic keys) |
| `checks.auditSummary` | envelope | Synthesized decision with confidence |

Each artifact uses the **envelope format**: `{ content, sha256, sizeBytes, status, omitReason? }`.
- `status: present` — content embedded
- `status: omitted` — content null, validate by sha256
- `status: error` — generation failed, see omitReason
```

**Step 3: Commit**

```bash
cd /Users/vi/personal/skill7/devtools/signum
git add docs/reference.md
git commit -m "docs: update proofpack reference for v4.0 envelope format"
```

---

### Task 4: Update CHANGELOG.md

**Files:**
- Modify: `CHANGELOG.md`

**Step 1: Read current CHANGELOG header**

Read `CHANGELOG.md` first 30 lines to see format.

**Step 2: Add v4.0.0 entry**

Prepend after the header:

```markdown
## [4.0.0] — 2026-03-04

### Changed
- **BREAKING**: proofpack.json schema v3.0 → v4.0
- All artifact fields changed from file path strings to envelope objects with embedded content
- `checksums` top-level field removed (per-artifact sha256 in each envelope)
- `checks.audit_summary` renamed to `checks.auditSummary` (camelCase unification)
- `auditChain` fields renamed: `contract_sha256` → `contractSha256`, `approved_at` → `approvedAt`, `base_commit` → `baseCommit`
- Hash format changed from `sha256:hex` prefix to plain hex string

### Added
- Self-contained proofpack: all artifact contents embedded in single JSON file
- Envelope format: `{ content, sha256, sizeBytes, status, omitReason? }`
- Envelope status field: `present | omitted | error` for each artifact
- Contract redaction: holdouts stripped from embedded content, `fullSha256` preserves original hash
- Diff omit-but-hash: patches >100KB stored as hash + size only
- Dynamic review provider keys (not limited to claude/codex/gemini)
- `signumVersion` and `createdAt` top-level fields
- `baseline` and `executeLog` as first-class proofpack artifacts
```

**Step 3: Commit**

```bash
cd /Users/vi/personal/skill7/devtools/signum
git add CHANGELOG.md
git commit -m "docs: CHANGELOG for v4.0.0 self-contained proofpack"
```

---

### Task 5: Update plugin.json version

**Files:**
- Modify: `.claude-plugin/plugin.json`

**Step 1: Read current manifest**

Read `.claude-plugin/plugin.json`.

**Step 2: Bump version**

Change `"version": "3.0.0"` to `"version": "4.0.0"`.

**Step 3: Commit**

```bash
cd /Users/vi/personal/skill7/devtools/signum
git add .claude-plugin/plugin.json
git commit -m "chore: bump version to 4.0.0"
```

---

### Task 6: Smoke test

**Step 1: Validate schema is valid JSON**

```bash
cd /Users/vi/personal/skill7/devtools/signum
python3 -c "import json; json.load(open('lib/schemas/proofpack.schema.json')); print('schema OK')"
```

Expected: `schema OK`

**Step 2: Validate schema with jsonschema (if available)**

```bash
python3 -c "
import json
try:
    from jsonschema import Draft7Validator
    schema = json.load(open('lib/schemas/proofpack.schema.json'))
    Draft7Validator.check_schema(schema)
    print('schema validates OK')
except ImportError:
    print('jsonschema not installed, skip')
"
```

**Step 3: Dry-run envelope builder**

Create a minimal test to verify the bash envelope builder works:

```bash
cd /Users/vi/personal/skill7/devtools/signum
ARTIFACT_ROOT=/tmp/signum-test/.signum/contracts/sig-test
mkdir -p "$ARTIFACT_ROOT/reviews"
echo '{"goal":"test","riskLevel":"low"}' > "$ARTIFACT_ROOT/contract.json"
echo 'diff content' > "$ARTIFACT_ROOT/combined.patch"
echo '{"lint":0,"typecheck":0}' > "$ARTIFACT_ROOT/baseline.json"
echo '{"totalAttempts":1}' > "$ARTIFACT_ROOT/execute_log.json"
echo '{"mechanic":"pass","decision":"AUTO_OK","confidence":{"overall":90}}' > "$ARTIFACT_ROOT/audit_summary.json"
echo '{"passed":0,"failed":0}' > "$ARTIFACT_ROOT/mechanic_report.json"
echo '{"verdict":"APPROVE","findings":[],"summary":"ok"}' > "$ARTIFACT_ROOT/reviews/claude.json"
echo 'contract_sha256: abc123' > "$ARTIFACT_ROOT/contract-hash.txt"
echo 'approved_at: 2026-03-04T10:00:00Z' >> "$ARTIFACT_ROOT/contract-hash.txt"
echo '{"base_commit":"def456"}' > "$ARTIFACT_ROOT/execution_context.json"

# Verify the generated proofpack has expected structure
cd /tmp/signum-test
# (paste the Phase 4 bash script and run it)
# Then verify:
jq '.schemaVersion' "$ARTIFACT_ROOT/proofpack.json"  # should be "4.0"
jq '.contract.status' "$ARTIFACT_ROOT/proofpack.json"  # should be "present"
jq '.contract.fullSha256' "$ARTIFACT_ROOT/proofpack.json"  # should be non-null
jq '.diff.status' "$ARTIFACT_ROOT/proofpack.json"  # should be "present" (small diff)
jq '.checks.reviews | keys' "$ARTIFACT_ROOT/proofpack.json"  # should be ["claude"]
rm -rf /tmp/signum-test
```

Expected: all jq queries return correct values.
