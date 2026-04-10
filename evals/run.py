#!/usr/bin/env python3
"""Offline snapshot runner for Signum eval harness fixtures."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List

from checks import canonical_json, evaluate_fixture


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text())


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run Signum eval harness fixtures against committed snapshots.")
    parser.add_argument("--fixtures-dir", help="Directory containing fixture JSON files")
    parser.add_argument("--snapshots-dir", help="Directory containing expected snapshot JSON files")
    parser.add_argument("--update-snapshots", action="store_true", help="Rewrite snapshots from current fixture evaluation")
    args = parser.parse_args()

    fixtures_dir = Path(args.fixtures_dir) if args.fixtures_dir else script_dir / "fixtures"
    snapshots_dir = Path(args.snapshots_dir) if args.snapshots_dir else script_dir / "snapshots"
    fixture_paths = sorted(fixtures_dir.glob("*.json"))

    summary: Dict[str, Any] = {
        "status": "ok",
        "fixtureCount": len(fixture_paths),
        "passed": 0,
        "failed": 0,
        "results": [],
    }

    if not fixture_paths:
        summary["status"] = "error"
        summary["failed"] = 1
        summary["results"].append(
            {
                "caseId": None,
                "snapshotStatus": "error",
                "observedVerdict": None,
                "invariantStatus": "error",
                "failedChecks": ["runner.no_fixtures"],
                "reasons": [f"no fixture files found in {fixtures_dir.resolve()}"],
            }
        )
        print(canonical_json(summary), end="")
        return 1

    snapshots_dir.mkdir(parents=True, exist_ok=True)

    for fixture_path in fixture_paths:
        try:
            fixture = load_json(fixture_path)
            result = evaluate_fixture(fixture)
            snapshot_path = snapshots_dir / fixture_path.name
            result_blob = canonical_json(result)

            if args.update_snapshots:
                snapshot_path.write_text(result_blob)
                snapshot_status = "written"
                reasons: List[str] = []
                summary["passed"] += 1
            else:
                if not snapshot_path.exists():
                    snapshot_status = "missing"
                    reasons = [f"snapshot missing: {snapshot_path}"]
                    summary["failed"] += 1
                    summary["status"] = "error"
                else:
                    expected_blob = canonical_json(load_json(snapshot_path))
                    if expected_blob == result_blob:
                        snapshot_status = "match"
                        reasons = []
                        summary["passed"] += 1
                    else:
                        snapshot_status = "mismatch"
                        reasons = [f"snapshot differs: {snapshot_path}"]
                        summary["failed"] += 1
                        summary["status"] = "error"

            summary["results"].append(
                {
                    "caseId": result.get("caseId"),
                    "snapshotStatus": snapshot_status,
                    "observedVerdict": result.get("observedVerdict"),
                    "invariantStatus": result.get("invariantStatus"),
                    "failedChecks": result.get("failedChecks", []),
                    "reasons": reasons,
                }
            )
        except Exception as exc:  # pragma: no cover - surfaced in JSON for shell tests
            summary["status"] = "error"
            summary["failed"] += 1
            summary["results"].append(
                {
                    "caseId": fixture_path.stem,
                    "snapshotStatus": "error",
                    "observedVerdict": None,
                    "invariantStatus": "error",
                    "failedChecks": ["runner.exception"],
                    "reasons": [str(exc)],
                }
            )

    print(canonical_json(summary), end="")
    return 0 if summary["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
