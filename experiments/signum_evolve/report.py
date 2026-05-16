"""Report and leaderboard helpers for signum-evolve."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

from .candidate import load_json, write_json
from .replay import compact_historical_replay, decision_with_replay


def baseline_summary_from_scorecard(scorecard: Dict[str, Any]) -> Dict[str, Any]:
    metrics = scorecard.get("metrics") if isinstance(scorecard.get("metrics"), dict) else scorecard.get("summary", {})
    return {
        "criticalRecall": metrics.get("criticalRecall"),
        "fixtureCount": metrics.get("fixtureCount"),
        "precision": metrics.get("precision"),
        "recall": metrics.get("recall"),
    }


def replay_drift_count(replay: Dict[str, Any] | None) -> int:
    if not replay:
        return 0
    return sum(
        int(replay.get(field, 0) or 0)
        for field in (
            "newFindingsCount",
            "removedFindingsCount",
            "changedSeverityCount",
            "changedRuleCount",
        )
    )


def candidate_score(compare: Dict[str, Any], replay: Dict[str, Any] | None) -> Dict[str, Any]:
    return {
        "catalogChangedRuleCount": 0,
        "hardGatePassed": compare.get("hardGatePassed") is True,
        "improvementCount": len(compare.get("improvements", [])),
        "regressionCount": len(compare.get("regressions", [])),
        "removedCriticalFindingsCount": int((replay or {}).get("removedCriticalFindingsCount", 0) or 0),
        "replayDriftCount": replay_drift_count(replay),
    }


def rank_key(entry: Dict[str, Any]) -> tuple[Any, ...]:
    score = entry.get("score", {})
    decision_order = {"accept": 0, "review": 1, "reject": 2}
    status_order = {"better": 0, "equivalent": 1, "mixed": 2, "worse": 3}
    return (
        0 if score.get("hardGatePassed") else 1,
        0 if int(score.get("removedCriticalFindingsCount", 0) or 0) == 0 else 1,
        decision_order.get(str(entry.get("decision")), 3),
        status_order.get(str(entry.get("status")), 4),
        int(score.get("regressionCount", 0) or 0),
        -int(score.get("improvementCount", 0) or 0),
        int(score.get("replayDriftCount", 0) or 0),
        str(entry.get("candidateId", "")),
    )


def leaderboard_entry(candidate_dir: Path) -> Dict[str, Any]:
    candidate = load_json(candidate_dir / "candidate.json")
    compare = load_json(candidate_dir / "compare.json")
    catalog_diff_path = candidate_dir / "catalog_diff.json"
    catalog_diff = load_json(catalog_diff_path) if catalog_diff_path.exists() else None
    replay_path = candidate_dir / "historical_replay.json"
    replay = load_json(replay_path) if replay_path.exists() else None
    score = candidate_score(compare, replay)
    if catalog_diff is not None:
        score["catalogChangedRuleCount"] = int(catalog_diff.get("changedRuleCount", 0) or 0)
    entry = {
        "candidateId": candidate["candidateId"],
        "decision": decision_with_replay(compare, replay),
        "hardGatePassed": compare.get("hardGatePassed"),
        "improvements": compare.get("improvements", []),
        "mutation": candidate.get("mutation", {}),
        "mutationCount": candidate.get("mutationCount", len(candidate.get("mutations", []))),
        "regressions": compare.get("regressions", []),
        "score": score,
        "status": compare.get("status"),
    }
    if catalog_diff is not None:
        entry["catalogDiff"] = {
            "changedRuleCount": catalog_diff.get("changedRuleCount", 0),
            "criticalRuleChangesCount": catalog_diff.get("criticalRuleChangesCount", 0),
        }
    if replay is not None:
        entry["historicalReplay"] = compact_historical_replay(replay)
    return entry


def build_leaderboard(run_dir: Path, run_id: str, baseline_scorecard: Dict[str, Any]) -> Dict[str, Any]:
    candidate_dirs = sorted((run_dir / "candidates").glob("cand_*"))
    entries = [leaderboard_entry(path) for path in candidate_dirs]
    entries = sorted(entries, key=rank_key)
    for index, entry in enumerate(entries, start=1):
        entry["rank"] = index
    return {
        "baseline": baseline_summary_from_scorecard(baseline_scorecard),
        "candidates": entries,
        "runId": run_id,
        "schemaVersion": "1.0",
    }


def write_leaderboard(run_dir: Path, run_id: str, baseline_scorecard: Dict[str, Any]) -> Dict[str, Any]:
    leaderboard = build_leaderboard(run_dir, run_id, baseline_scorecard)
    write_json(run_dir / "leaderboard.json", leaderboard)
    return leaderboard
