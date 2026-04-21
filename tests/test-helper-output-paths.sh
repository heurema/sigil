#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
POLICY_ROOT="$ROOT_DIR/lib/policy-scanner.sh"
POLICY_OVERLAY="$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh"
MECHANIC_ROOT="$ROOT_DIR/lib/mechanic-parser.sh"
MECHANIC_OVERLAY="$ROOT_DIR/platforms/claude-code/lib/mechanic-parser.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_policy_case() {
  local script="$1"
  local label="$2"
  local case_dir="$WORK/$label-policy"
  mkdir -p "$case_dir/artifacts"
  cat > "$case_dir/artifacts/combined.patch" <<'EOF'
diff --git a/src/demo.py b/src/demo.py
@@ -0,0 +1,2 @@
+def handler():
+    return None
EOF
  (
    cd "$case_dir"
    "$script" "$case_dir/artifacts/combined.patch" >/dev/null
  )
  test -f "$case_dir/artifacts/policy_scan.json"
  test ! -f "$case_dir/.signum/policy_scan.json"
}

run_mechanic_case() {
  local script="$1"
  local label="$2"
  local case_dir="$WORK/$label-mechanic"
  mkdir -p "$case_dir/artifacts"
  cat > "$case_dir/artifacts/baseline.json" <<'EOF'
{"lint":0,"typecheck":0,"tests":{"exit_code":0,"failing":[]}}
EOF
  (
    cd "$case_dir"
    "$script" "$case_dir/artifacts/baseline.json" >/dev/null
  )
  test -f "$case_dir/artifacts/mechanic_report.json"
  jq -e '.hasRegressions == false' "$case_dir/artifacts/mechanic_report.json" >/dev/null
  test ! -f "$case_dir/.signum/mechanic_report.json"
}

run_policy_case "$POLICY_ROOT" "root"
run_policy_case "$POLICY_OVERLAY" "overlay"
run_mechanic_case "$MECHANIC_ROOT" "root"
run_mechanic_case "$MECHANIC_OVERLAY" "overlay"

echo "ok: helper scripts write outputs next to canonical input artifacts"
