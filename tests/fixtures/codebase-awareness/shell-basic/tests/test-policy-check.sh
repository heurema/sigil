#!/usr/bin/env bash
set -euo pipefail

passed=0
failed=0

pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s -- %s\n' "$1" "$2"; failed=$((failed + 1)); }

source lib/json-output.sh
bash lib/policy-check.sh /tmp/report.json
jq -e . /tmp/report.json >/dev/null
python3 - <<'PY'
import json
from pathlib import Path

json.loads(Path("/tmp/report.json").read_text())
PY
