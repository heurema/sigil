#!/usr/bin/env bash
# test-doc-parity.sh -- tests for lib/doc-parity-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

OK_OUTPUT=$(bash "$CHECK_SCRIPT" --repo-root "$OK_REPO" 2>/dev/null)
OK_STATUS=$(echo "$OK_OUTPUT" | jq -r '.status')
OK_COUNT=$(echo "$OK_OUTPUT" | jq '.findings | length')
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

WARN_OUTPUT=$(bash "$CHECK_SCRIPT" --repo-root "$WARN_REPO" 2>/dev/null)
WARN_STATUS=$(echo "$WARN_OUTPUT" | jq -r '.status')
WARN_CODES=$(echo "$WARN_OUTPUT" | jq -r '.findings[].code')
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

ALLOW_OUTPUT=$(bash "$CHECK_SCRIPT" --repo-root "$ALLOW_REPO" 2>/dev/null)
ALLOW_STATUS=$(echo "$ALLOW_OUTPUT" | jq -r '.status')
ALLOW_COUNT=$(echo "$ALLOW_OUTPUT" | jq '.findings | length')
assert_eq "allowlisted overlay returns status ok" "$ALLOW_STATUS" "ok"
assert_eq "allowlisted overlay has zero findings" "$ALLOW_COUNT" "0"

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
