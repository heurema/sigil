#!/usr/bin/env bash
# test-emporium-sync.sh -- tests for lib/check-emporium-sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_CHECK="$SCRIPT_DIR/../lib/check-emporium-sync.sh"

passed=0
failed=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_exit_contains() {
  local name="$1" expected_exit="$2" expected_text="$3"
  shift 3
  local output exit_code
  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e

  if [ "$exit_code" -ne "$expected_exit" ]; then
    printf '  FAIL: %s — expected exit %s, got %s\n%s\n' "$name" "$expected_exit" "$exit_code" "$output"
    failed=$((failed + 1))
    return
  fi

  if [[ "$output" != *"$expected_text"* ]]; then
    printf '  FAIL: %s — output missing "%s"\n%s\n' "$name" "$expected_text" "$output"
    failed=$((failed + 1))
    return
  fi

  printf '  PASS: %s\n' "$name"
  passed=$((passed + 1))
}

cat > "$WORK/plugin.json" <<'EOF'
{
  "name": "signum",
  "version": "4.20.0"
}
EOF

cat > "$WORK/marketplace-ok.json" <<'EOF'
{
  "plugins": [
    {
      "name": "signum",
      "version": "4.20.0",
      "source": {
        "ref": "v4.20.0"
      }
    }
  ]
}
EOF

cat > "$WORK/marketplace-version-drift.json" <<'EOF'
{
  "plugins": [
    {
      "name": "signum",
      "version": "4.19.2",
      "source": {
        "ref": "v4.20.0"
      }
    }
  ]
}
EOF

cat > "$WORK/marketplace-ref-drift.json" <<'EOF'
{
  "plugins": [
    {
      "name": "signum",
      "version": "4.20.0",
      "source": {
        "ref": "v4.19.2"
      }
    }
  ]
}
EOF

cat > "$WORK/marketplace-missing-entry.json" <<'EOF'
{
  "plugins": [
    {
      "name": "other-plugin",
      "version": "1.0.0",
      "source": {
        "ref": "v1.0.0"
      }
    }
  ]
}
EOF

echo "=== Sync check behavior ==="

assert_exit_contains "passes when Emporium version and ref match" 0 \
  "OK: Emporium entry matches local Signum release metadata." \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_REPO="example/emporium" \
    EMPORIUM_GIT_REF="release-test" \
    EMPORIUM_PATH="registry/marketplace.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-ok.json" \
    bash "$SYNC_CHECK"

assert_exit_contains "reports parameterized Emporium source" 0 \
  "Emporium source repo: example/emporium" \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_REPO="example/emporium" \
    EMPORIUM_GIT_REF="release-test" \
    EMPORIUM_PATH="registry/marketplace.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-ok.json" \
    bash "$SYNC_CHECK"

assert_exit_contains "fails on version drift" 1 \
  "ERROR: Emporium drift detected for signum." \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_REPO="example/emporium" \
    EMPORIUM_GIT_REF="release-test" \
    EMPORIUM_PATH="registry/marketplace.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-version-drift.json" \
    bash "$SYNC_CHECK"

assert_exit_contains "fails on ref drift" 1 \
  "ERROR: Emporium drift detected for signum." \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_REPO="example/emporium" \
    EMPORIUM_GIT_REF="release-test" \
    EMPORIUM_PATH="registry/marketplace.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-ref-drift.json" \
    bash "$SYNC_CHECK"

assert_exit_contains "fails when signum entry is missing" 1 \
  "ERROR: Emporium marketplace entry for signum not found." \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_REPO="example/emporium" \
    EMPORIUM_GIT_REF="release-test" \
    EMPORIUM_PATH="registry/marketplace.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-missing-entry.json" \
    bash "$SYNC_CHECK"

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
fi
