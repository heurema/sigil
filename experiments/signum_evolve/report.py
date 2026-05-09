"""Report and leaderboard helpers for signum-evolve v0."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

from .candidate import load_json, write_json


def baseline_summary_from_scorecard(scorecard: Dict[str, Any]) -> Dict[str, Any]:
    metrics = scorecard.get("metrics") if isinstance(scorecard.get("metrics"), dict) else scorecard.get("summary", {})
    return {
        "criticalRecall": metrics.get("criticalRecall"),
        "fixtureCount": metrics.get("fixtureCount"),
        "precision": metrics.get("precision"),
        "recall": metrics.get("recall"),
    }


def leaderboard_entry(candidate_dir: Path) -> Dict[str, Any]:
    candidate = load_json(candidate_dir / "candidate.json")
    compare = load_json(candidate_dir / "compare.json")
    return {
        "candidateId": candidate["candidateId"],
        "decision": compare.get("decision"),
        "hardGatePassed": compare.get("hardGatePassed"),
        "improvements": compare.get("improvements", []),
        "mutation": candidate.get("mutation", {}),
        "regressions": compare.get("regressions", []),
        "status": compare.get("status"),
    }


def build_leaderboard(run_dir: Path, run_id: str, baseline_scorecard: Dict[str, Any]) -> Dict[str, Any]:
    candidate_dirs = sorted((run_dir / "candidates").glob("cand_*"))
    return {
        "baseline": baseline_summary_from_scorecard(baseline_scorecard),
        "candidates": [leaderboard_entry(path) for path in candidate_dirs],
        "runId": run_id,
        "schemaVersion": "1.0",
    }


def write_leaderboard(run_dir: Path, run_id: str, baseline_scorecard: Dict[str, Any]) -> Dict[str, Any]:
    leaderboard = build_leaderboard(run_dir, run_id, baseline_scorecard)
    write_json(run_dir / "leaderboard.json", leaderboard)
    return leaderboard
