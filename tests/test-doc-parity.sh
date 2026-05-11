#!/usr/bin/env bash
# test-doc-parity.sh -- tests for lib/doc-parity-check.sh
set -euo pipefail

export CDPATH=

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/../lib/doc-parity-check.sh"

passed=0
failed=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected "%s", got "%s"\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -Fq "$needle"; then
    printf '  PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf '  FAIL: %s — expected to find "%s"\n' "$name" "$needle"
    failed=$((failed + 1))
  fi
}

run_check() {
  local repo="$1" output_var="$2" exit_var="$3"
  local output status

  set +e
  output=$(bash "$CHECK_SCRIPT" --repo-root "$repo" 2>/dev/null)
  status=$?
  set -e

  printf -v "$output_var" '%s' "$output"
  printf -v "$exit_var" '%s' "$status"
}

write_common_files() {
  local dir="$1"
  mkdir -p "$dir/commands" "$dir/platforms/claude-code/commands" "$dir/docs/plans" "$dir/docs" "$dir/lib/schemas"

  cat > "$dir/commands/signum.md" <<'EOF'
## Phase 1: CONTRACT
## Phase 2: EXECUTE
## Phase 3: AUDIT
## Phase 4: PACK
EOF

  cat > "$dir/docs/reference.md" <<'EOF'
# Signum Reference

## Canonical Sources

- **Canonical pipeline behavior:** root `commands/signum.md`
- **Platform-specific overlays:** `platforms/*/commands/signum.md`
- **Derived docs:** `README.md`, `docs/how-it-works.md`, `docs/reference.md`, roadmap docs

### Known overlay deviations

- `platforms/claude-code/commands/signum.md` currently adds **Phase 5: RECONCILE** after PACK.
- This is an **overlay-only deviation**, not canonical core pipeline behavior.
- Treat it as valid only while it remains listed in `docs/overlay-deviations.json`.

| `schemaVersion` | `"3.0"`–`"3.8"` | Schema version |

### proofpack.json fields

- `lib/schemas/proofpack.schema.json` defines the proofpack schema.
- `scripts/validate_proofpack.py` validates emitted proofpacks.

The runtime PACK phase writes `.signum/contracts/<contractId>/proofpack.json`.

| Field | Required | Notes |
| --- | --- | --- |
| `schemaVersion` | Yes | Proofpack schema version |
| `contractId` | Yes | Contract identifier |
| `decision` | Yes | Decision |
| `releaseVerdict` | Yes | Release verdict |
| `riskLevel` | Yes | Risk level |
| `timing` | Yes | Timing metadata |
| `reviewCoverage` | Yes | Review coverage |
| `contractSource` | Yes | Contract source |
| `approval` | Yes | Approval evidence |
| `checks.policy_scan` | Yes | Policy scan evidence |
| `ciContext` | Optional | CI metadata |
| `baselineComparison` | Optional | Baseline comparison |
| `removalEvidence` | Optional | Removal evidence |
EOF

  cat > "$dir/SKILL.md" <<'EOF'
# Signum

- Keep active run/pipeline artifacts under `.signum/contracts/<contractId>/`
- Treat root `.signum/` as a registry/state/archive/compatibility namespace.
EOF

  cat > "$dir/ARCHITECTURE.md" <<'EOF'
# Architecture

1. User runs `/signum:init`.
2. Signum writes run artifacts under `.signum/contracts/<contractId>/`.

Root `.signum/` is a registry/state/archive/compatibility namespace.
EOF

  cat > "$dir/lib/schemas/contract.schema.json" <<'EOF'
{
  "properties": {
    "schemaVersion": {
      "enum": ["3.0", "3.1", "3.2", "3.3", "3.4", "3.5", "3.6", "3.7", "3.8"]
    }
  }
}
EOF

  cat > "$dir/docs/plans/2026-03-15-large-project-support-roadmap.md" <<'EOF'
# Signum: Large-Project Support Roadmap

> **2026-04-10 maintenance update**

### Phase 1: Project Intent Layer
- **Status:** shipped in core

### Phase 2: Glossary Enforcement
- **Status:** shipped in core

### Phase 3: Cross-Contract Coherence
- **Status:** shipped in core

### Phase 4: Upstream Staleness Detection
- **Status:** shipped in core

### Phase 5: Within-Task Refinement Loop
- **Status:** shipped in core
EOF

  cat > "$dir/docs/overlay-deviations.json" <<'EOF'
{
  "version": 1,
  "overlays": {
    "platforms/claude-code/commands/signum.md": {
      "allowedExtraPhases": [
        {
          "name": "RECONCILE",
          "reason": "overlay-only deviation"
        }
      ]
    }
  }
}
EOF
}

echo "=== OK case ==="
OK_REPO="$WORK/ok"
write_common_files "$OK_REPO"
cp "$OK_REPO/commands/signum.md" "$OK_REPO/platforms/claude-code/commands/signum.md"

run_check "$OK_REPO" OK_OUTPUT OK_EXIT
OK_STATUS=$(echo "$OK_OUTPUT" | jq -r '.status')
OK_COUNT=$(echo "$OK_OUTPUT" | jq '.findings | length')
assert_eq "ok repo exits zero" "$OK_EXIT" "0"
assert_eq "ok repo returns status ok" "$OK_STATUS" "ok"
assert_eq "ok repo has zero findings" "$OK_COUNT" "0"

echo ""
echo "=== Warn case ==="
WARN_REPO="$WORK/warn"
write_common_files "$WARN_REPO"

cat > "$WARN_REPO/platforms/claude-code/commands/signum.md" <<'EOF'
## Phase 1: CONTRACT
## Phase 2: EXECUTE
## Phase 3: AUDIT
## Phase 4: PACK
## Phase 5: RECONCILE
EOF

cat > "$WARN_REPO/docs/reference.md" <<'EOF'
# Signum Reference

| `schemaVersion` | `"3.0"`–`"3.7"` | Schema version |

### proofpack.json fields

- `lib/schemas/proofpack.schema.json` defines the proofpack schema.
- `scripts/validate_proofpack.py` validates emitted proofpacks.

The runtime PACK phase writes `.signum/contracts/<contractId>/proofpack.json`.

| Field | Required | Notes |
| --- | --- | --- |
| `schemaVersion` | Yes | Proofpack schema version |
| `contractId` | Yes | Contract identifier |
| `decision` | Yes | Decision |
| `releaseVerdict` | Yes | Release verdict |
| `riskLevel` | Yes | Risk level |
| `timing` | Yes | Timing metadata |
| `reviewCoverage` | Yes | Review coverage |
| `contractSource` | Yes | Contract source |
| `approval` | Yes | Approval evidence |
| `checks.policy_scan` | Yes | Policy scan evidence |
| `ciContext` | Optional | CI metadata |
| `baselineComparison` | Optional | Baseline comparison |
| `removalEvidence` | Optional | Removal evidence |
EOF

cat > "$WARN_REPO/docs/overlay-deviations.json" <<'EOF'
{
  "version": 1,
  "overlays": {
    "platforms/claude-code/commands/signum.md": {
      "allowedExtraPhases": []
    }
  }
}
EOF

cat > "$WARN_REPO/docs/plans/2026-03-15-large-project-support-roadmap.md" <<'EOF'
# Signum: Large-Project Support Roadmap

### Phase 1: Project Intent Layer
- **Status:** not started

### Phase 2: Glossary Enforcement
- **Status:** shipped in core

### Phase 3: Cross-Contract Coherence
- **Status:** shipped in core

### Phase 4: Upstream Staleness Detection
- **Status:** shipped in core

### Phase 5: Within-Task Refinement Loop
- **Status:** shipped in core
EOF

run_check "$WARN_REPO" WARN_OUTPUT WARN_EXIT
WARN_STATUS=$(echo "$WARN_OUTPUT" | jq -r '.status')
WARN_CODES=$(echo "$WARN_OUTPUT" | jq -r '.findings[].code')
assert_eq "warn repo exits zero" "$WARN_EXIT" "0"
assert_eq "warn repo returns status warn" "$WARN_STATUS" "warn"
assert_contains "warn repo flags missing canonical policy" "$WARN_CODES" "canonical_source_policy_missing"
assert_contains "warn repo flags schema mismatch" "$WARN_CODES" "schema_version_range_mismatch"
assert_contains "warn repo flags phase mismatch" "$WARN_CODES" "phase_inventory_mismatch"
assert_contains "warn repo flags maintenance note" "$WARN_CODES" "roadmap_maintenance_note_missing"
assert_contains "warn repo flags roadmap status mismatch" "$WARN_CODES" "roadmap_phase_status_mismatch"

echo ""
echo "=== Allowlisted overlay deviation case ==="
ALLOW_REPO="$WORK/allow"
write_common_files "$ALLOW_REPO"

cat > "$ALLOW_REPO/platforms/claude-code/commands/signum.md" <<'EOF'
## Phase 1: CONTRACT
## Phase 2: EXECUTE
## Phase 3: AUDIT
## Phase 4: PACK
## Phase 5: RECONCILE
EOF

run_check "$ALLOW_REPO" ALLOW_OUTPUT ALLOW_EXIT
ALLOW_STATUS=$(echo "$ALLOW_OUTPUT" | jq -r '.status')
ALLOW_COUNT=$(echo "$ALLOW_OUTPUT" | jq '.findings | length')
assert_eq "allowlisted overlay exits zero" "$ALLOW_EXIT" "0"
assert_eq "allowlisted overlay returns status ok" "$ALLOW_STATUS" "ok"
assert_eq "allowlisted overlay has zero findings" "$ALLOW_COUNT" "0"

echo ""
echo "=== Critical proofpack drift case ==="
PROOFPACK_DRIFT_REPO="$WORK/proofpack-drift"
write_common_files "$PROOFPACK_DRIFT_REPO"
cp "$PROOFPACK_DRIFT_REPO/commands/signum.md" "$PROOFPACK_DRIFT_REPO/platforms/claude-code/commands/signum.md"
printf '\n### proofpack.json fields (v4.6)\n' >> "$PROOFPACK_DRIFT_REPO/docs/reference.md"

run_check "$PROOFPACK_DRIFT_REPO" PROOFPACK_DRIFT_OUTPUT PROOFPACK_DRIFT_EXIT
PROOFPACK_DRIFT_STATUS=$(echo "$PROOFPACK_DRIFT_OUTPUT" | jq -r '.status')
PROOFPACK_DRIFT_CODES=$(echo "$PROOFPACK_DRIFT_OUTPUT" | jq -r '.findings[].code')
assert_eq "proofpack drift exits nonzero" "$PROOFPACK_DRIFT_EXIT" "1"
assert_eq "proofpack drift returns status error" "$PROOFPACK_DRIFT_STATUS" "error"
assert_contains "proofpack drift flags stale v4.6 heading" "$PROOFPACK_DRIFT_CODES" "reference_proofpack_v46_stale"

echo ""
echo "=== Critical skill artifact-root drift case ==="
SKILL_DRIFT_REPO="$WORK/skill-drift"
write_common_files "$SKILL_DRIFT_REPO"
cp "$SKILL_DRIFT_REPO/commands/signum.md" "$SKILL_DRIFT_REPO/platforms/claude-code/commands/signum.md"
printf '\nKeep all artifacts in `.signum/`.\n' >> "$SKILL_DRIFT_REPO/SKILL.md"

run_check "$SKILL_DRIFT_REPO" SKILL_DRIFT_OUTPUT SKILL_DRIFT_EXIT
SKILL_DRIFT_STATUS=$(echo "$SKILL_DRIFT_OUTPUT" | jq -r '.status')
SKILL_DRIFT_CODES=$(echo "$SKILL_DRIFT_OUTPUT" | jq -r '.findings[].code')
assert_eq "skill drift exits nonzero" "$SKILL_DRIFT_EXIT" "1"
assert_eq "skill drift returns status error" "$SKILL_DRIFT_STATUS" "error"
assert_contains "skill drift flags stale root wording" "$SKILL_DRIFT_CODES" "skill_root_artifacts_stale"

echo ""
echo "=== Critical architecture command drift case ==="
ARCH_DRIFT_REPO="$WORK/architecture-drift"
write_common_files "$ARCH_DRIFT_REPO"
cp "$ARCH_DRIFT_REPO/commands/signum.md" "$ARCH_DRIFT_REPO/platforms/claude-code/commands/signum.md"
printf '\nLegacy command: /signum init\n' >> "$ARCH_DRIFT_REPO/ARCHITECTURE.md"

run_check "$ARCH_DRIFT_REPO" ARCH_DRIFT_OUTPUT ARCH_DRIFT_EXIT
ARCH_DRIFT_STATUS=$(echo "$ARCH_DRIFT_OUTPUT" | jq -r '.status')
ARCH_DRIFT_CODES=$(echo "$ARCH_DRIFT_OUTPUT" | jq -r '.findings[].code')
assert_eq "architecture drift exits nonzero" "$ARCH_DRIFT_EXIT" "1"
assert_eq "architecture drift returns status error" "$ARCH_DRIFT_STATUS" "error"
assert_contains "architecture drift flags stale init command" "$ARCH_DRIFT_CODES" "architecture_init_command_stale"

echo ""
echo "=== Results ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
