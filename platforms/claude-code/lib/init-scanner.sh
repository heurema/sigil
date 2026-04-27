#!/usr/bin/env bash
# init-scanner.sh -- compatibility wrapper for scripts/init_scanner.py
# Usage: init-scanner.sh [--project-root <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCANNER="${SCRIPT_DIR}/../scripts/init_scanner.py"

if ! command -v jq > /dev/null 2>&1; then
  echo '{"error":"jq not found"}' >&2
  exit 1
fi

if ! command -v python3 > /dev/null 2>&1; then
  echo "ERROR: python3 not found" >&2
  exit 1
fi

if [ ! -f "$PYTHON_SCANNER" ]; then
  echo "ERROR: init scanner implementation not found: $PYTHON_SCANNER" >&2
  exit 1
fi

exec python3 "$PYTHON_SCANNER" "$@"
