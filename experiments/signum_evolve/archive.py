"""Run archive helpers for signum-evolve v0."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

from .candidate import write_json


def prepare_run_dir(repo_root: Path, run_id: str) -> Path:
    run_dir = repo_root / "experiments" / "signum_evolve" / "out" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "candidates").mkdir(exist_ok=True)
    return run_dir


def write_run_manifest(
    run_dir: Path,
    *,
    run_id: str,
    config_path: Path,
    seed: int,
    max_candidates: int,
    candidate_count: int,
    baseline_summary: Dict[str, Any],
) -> Dict[str, Any]:
    manifest = {
        "baseline": baseline_summary,
        "candidateCount": candidate_count,
        "config": config_path.as_posix(),
        "createdAt": None,
        "maxCandidates": max_candidates,
        "runId": run_id,
        "schemaVersion": "1.0",
        "seed": seed,
    }
    write_json(run_dir / "run_manifest.json", manifest)
    return manifest


def archive_candidate(run_dir: Path, candidate: Dict[str, Any]) -> Path:
    candidate_dir = run_dir / "candidates" / candidate["candidateId"]
    candidate_dir.mkdir(parents=True, exist_ok=True)
    write_json(candidate_dir / "candidate.json", candidate)
    write_json(candidate_dir / "policy-rules.json", candidate["catalog"])
    return candidate_dir
