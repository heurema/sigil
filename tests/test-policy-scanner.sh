#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/lib/policy-scanner.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p artifacts

cat > artifacts/combined.patch <<'EOF2'
diff --git a/src/demo.py b/src/demo.py
@@ -0,0 +1,3 @@
+def handler():
+    # TODO: finish this
+    return None
EOF2

"$SCRIPT" artifacts/combined.patch >/dev/null
jq -e '.summaryCounts.critical == 1' artifacts/policy_scan.json >/dev/null
jq -e '.findings[0].pattern == "incomplete_implementation"' artifacts/policy_scan.json >/dev/null

echo "PASS: policy scanner flags TODO as CRITICAL incomplete implementation"
