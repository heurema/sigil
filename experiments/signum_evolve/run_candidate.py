"""Evaluate and compare one signum-evolve candidate."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict

from .candidate import load_json


def run_command(command: list[str], *, cwd: Path, env: dict[str, str] | None = None, stdout_path: Path | None = None) -> int:
    if stdout_path is None:
        proc = subprocess.run(
            command,
            cwd=str(cwd),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return proc.returncode

    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    with stdout_path.open("w", encoding="utf-8") as handle:
        proc = subprocess.run(
            command,
            cwd=str(cwd),
            env=env,
            text=True,
            stdout=handle,
            stderr=subprocess.PIPE,
            check=False,
        )
    return proc.returncode


def evaluate_candidate(repo_root: Path, candidate_dir: Path, baseline_path: Path) -> Dict[str, Any]:
    catalog_path = candidate_dir / "policy-rules.json"
    eval_path = candidate_dir / "eval.json"
    compare_path = candidate_dir / "compare.json"

    env = os.environ.copy()
    env["SIGNUM_POLICY_RULE_CATALOG"] = str(catalog_path)
    eval_returncode = run_command(
        [
            sys.executable,
            "evals/policy_scanner/run_policy_scanner_eval.py",
            "--repo-root",
            ".",
            "--json-output",
            str(eval_path),
        ],
        cwd=repo_root,
        env=env,
    )
    if not eval_path.exists():
        raise RuntimeError(f"candidate eval did not create {eval_path}")

    compare_returncode = run_command(
        [
            sys.executable,
            "evals/policy_scanner/compare_policy_scanner_eval.py",
            "--baseline",
            str(baseline_path),
            "--candidate",
            str(eval_path),
        ],
        cwd=repo_root,
        stdout_path=compare_path,
    )
    if not compare_path.exists():
        raise RuntimeError(f"candidate comparison did not create {compare_path}")

    result = {
        "compareReturncode": compare_returncode,
        "evalReturncode": eval_returncode,
        "summary": load_json(eval_path).get("summary", {}),
        "comparison": load_json(compare_path),
    }
    return result
