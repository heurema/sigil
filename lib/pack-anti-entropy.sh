#!/usr/bin/env bash
# pack-anti-entropy.sh -- safe writer for .signum/anti_entropy_report.json
# Always exits 0. If anti-entropy-report.sh fails, writes a fallback error artifact instead.
#
# Usage:
#   pack-anti-entropy.sh [--project-root <path>] [--contract <path>] [--proofpack <path>] \
#     [--doc-parity-json <path>] [--metric-ratchet-json <path>] [--output <path>] [--as-of YYYY-MM-DD]

set -euo pipefail

PROJECT_ROOT="."
CONTRACT_PATH=".signum/contract.json"
PROOFPACK_PATH=".signum/proofpack.json"
DOC_PARITY_JSON=""
METRIC_RATCHET_JSON=""
OUTPUT_PATH=".signum/anti_entropy_report.json"
AS_OF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --contract) CONTRACT_PATH="$2"; shift 2 ;;
    --proofpack) PROOFPACK_PATH="$2"; shift 2 ;;
    --doc-parity-json) DOC_PARITY_JSON="$2"; shift 2 ;;
    --metric-ratchet-json) METRIC_RATCHET_JSON="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    --as-of) AS_OF="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 0
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTER="$SCRIPT_DIR/anti-entropy-report.sh"
PROJECT_ROOT_ABS="$(cd "$PROJECT_ROOT" && pwd)"

if [[ "$OUTPUT_PATH" != /* ]]; then
  OUTPUT_PATH="$PROJECT_ROOT_ABS/$OUTPUT_PATH"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

run_args=(--project-root "$PROJECT_ROOT" --contract "$CONTRACT_PATH" --proofpack "$PROOFPACK_PATH" --output "$OUTPUT_PATH")
[ -n "$DOC_PARITY_JSON" ] && run_args+=(--doc-parity-json "$DOC_PARITY_JSON")
[ -n "$METRIC_RATCHET_JSON" ] && run_args+=(--metric-ratchet-json "$METRIC_RATCHET_JSON")
[ -n "$AS_OF" ] && run_args+=(--as-of "$AS_OF")

if [ -x "$REPORTER" ] || [ -f "$REPORTER" ]; then
  if OUTPUT="$("$REPORTER" "${run_args[@]}" 2>&1)"; then
    STATUS=$(printf '%s\n' "$OUTPUT" | jq -r '.status // "ok"' 2>/dev/null || echo "ok")
    SUMMARY=$(printf '%s\n' "$OUTPUT" | jq -r '.summary // "anti-entropy report written"' 2>/dev/null || echo "anti-entropy report written")
    COUNT=$(printf '%s\n' "$OUTPUT" | jq -r '.findings | length' 2>/dev/null || echo "0")
    echo "Anti-entropy report: $STATUS ($COUNT findings) — $SUMMARY"
    exit 0
  fi
  ERROR_TEXT="$OUTPUT"
else
  ERROR_TEXT="anti-entropy-report.sh not found"
fi

python3 - "$OUTPUT_PATH" "$PROJECT_ROOT" "$CONTRACT_PATH" "$PROOFPACK_PATH" "$ERROR_TEXT" <<'PY'
import json, os, sys

output_path, project_root, contract_path, proofpack_path, error_text = sys.argv[1:]
report = {
    "check": "anti_entropy",
    "status": "error",
    "summary": "Anti-entropy report generation failed",
    "projectRoot": os.path.abspath(project_root),
    "inputs": {
        "contract": contract_path,
        "proofpack": proofpack_path,
    },
    "sources": [],
    "findings": [],
    "error": error_text[:4000],
}

os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
print(json.dumps(report))
PY

echo "Anti-entropy report: error (fallback artifact written)"
exit 0
