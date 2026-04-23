#!/usr/bin/env bash
# test-update-emporium-marketplace.sh -- tests for lib/update-emporium-marketplace.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/../lib/update-emporium-marketplace.sh"

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
  "version": "4.20.1"
}
EOF

cat > "$WORK/marketplace-drift.json" <<'EOF'
{
  "plugins": [
    {
      "name": "signum",
      "version": "4.20.0",
      "source": {
        "source": "url",
        "url": "https://github.com/heurema/signum.git",
        "ref": "v4.20.0"
      }
    },
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

cat > "$WORK/marketplace-ok.json" <<'EOF'
{
  "plugins": [
    {
      "name": "signum",
      "version": "4.20.1",
      "source": {
        "source": "url",
        "url": "https://github.com/heurema/signum.git",
        "ref": "v4.20.1"
      }
    }
  ]
}
EOF

cat > "$WORK/marketplace-missing.json" <<'EOF'
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

echo "=== Update behavior ==="

assert_exit_contains "updates drifted entry" 0 \
  "UPDATED: signum -> version 4.20.1, ref v4.20.1" \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-drift.json" \
    bash "$UPDATE_SCRIPT"

UPDATED_VERSION="$(jq -r '.plugins[] | select(.name == "signum") | .version' "$WORK/marketplace-drift.json")"
UPDATED_REF="$(jq -r '.plugins[] | select(.name == "signum") | .source.ref' "$WORK/marketplace-drift.json")"
OTHER_VERSION="$(jq -r '.plugins[] | select(.name == "other-plugin") | .version' "$WORK/marketplace-drift.json")"

if [ "$UPDATED_VERSION" = "4.20.1" ] && [ "$UPDATED_REF" = "v4.20.1" ] && [ "$OTHER_VERSION" = "1.0.0" ]; then
  echo "  PASS: writes expected version/ref and preserves unrelated entries"
  passed=$((passed + 1))
else
  echo "  FAIL: writes expected version/ref and preserves unrelated entries"
  failed=$((failed + 1))
fi

assert_exit_contains "reports unchanged entry" 0 \
  "UNCHANGED: signum already points to version 4.20.1, ref v4.20.1" \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-ok.json" \
    bash "$UPDATE_SCRIPT"

assert_exit_contains "fails when entry is missing" 1 \
  "ERROR: Emporium marketplace entry for signum not found" \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    EMPORIUM_MARKETPLACE_PATH="$WORK/marketplace-missing.json" \
    bash "$UPDATE_SCRIPT"

assert_exit_contains "fails without marketplace path" 1 \
  "ERROR: EMPORIUM_MARKETPLACE_PATH is required." \
  env \
    SIGNUM_PLUGIN_JSON_PATH="$WORK/plugin.json" \
    bash "$UPDATE_SCRIPT"

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
