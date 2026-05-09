#!/usr/bin/env python3
"""Thin wrapper for the PACK-stage Codebase Awareness reuse summary builder."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.codebase_awareness.build_reuse_summary import main


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
