"""CLI for signum-evolve v0."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Sequence

from .archive import archive_candidate, prepare_run_dir, write_run_manifest
from .candidate import DEFAULT_ALLOWED_PREFIXES, canonical_json, generate_candidates, load_catalog, load_json
from .export import export_bundle
from .mutate import validate_scope_only_mutation
from .report import baseline_summary_from_scorecard, write_leaderboard
from .run_candidate import evaluate_candidate


def repo_path(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def manifest_path_ref(repo_root: Path, path: Path) -> Path:
    resolved = path.resolve()
    try:
        return resolved.relative_to(repo_root)
    except ValueError:
        return Path(f"external:{resolved.name}")


def load_config(path: Path) -> Dict[str, Any]:
    config = load_json(path)
    if config.get("schemaVersion") != "1.0":
        raise ValueError("config schemaVersion must be 1.0")
    return config


def command_generate(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    config_path = repo_path(repo_root, args.config).resolve()
    config = load_config(config_path)
    catalog_path = repo_path(repo_root, config.get("baselineCatalog", "lib/policy-rules.json")).resolve()
    baseline_path = repo_path(
        repo_root,
        config.get("baselineScorecard", "evals/policy_scanner/baselines/current.json"),
    ).resolve()
    allowed_prefixes = tuple(config.get("allowedPrefixes", DEFAULT_ALLOWED_PREFIXES))

    catalog = load_catalog(catalog_path)
    baseline_scorecard = load_json(baseline_path)
    candidates = generate_candidates(
        catalog,
        max_candidates=args.max_candidates,
        seed=args.seed,
        allowed_prefixes=allowed_prefixes,
    )
    if not candidates:
        raise RuntimeError("no candidates generated")

    run_dir = prepare_run_dir(repo_root, args.run_id)
    for candidate in candidates:
        errors = validate_scope_only_mutation(catalog, candidate["catalog"])
        if errors:
            raise RuntimeError(f"{candidate['candidateId']} failed mutation validation: {errors}")
        candidate_dir = archive_candidate(run_dir, candidate)
        evaluate_candidate(repo_root, candidate_dir, baseline_path)

    leaderboard = write_leaderboard(run_dir, args.run_id, baseline_scorecard)
    write_run_manifest(
        run_dir,
        run_id=args.run_id,
        config_path=manifest_path_ref(repo_root, config_path),
        seed=args.seed,
        max_candidates=args.max_candidates,
        candidate_count=len(candidates),
        baseline_summary=baseline_summary_from_scorecard(baseline_scorecard),
    )
    sys.stdout.write(canonical_json({"candidateCount": len(candidates), "leaderboard": "leaderboard.json", "runId": args.run_id}))
    return 0 if leaderboard["candidates"] else 1


def command_leaderboard(args: argparse.Namespace) -> int:
    run_dir = Path(args.run)
    leaderboard_path = run_dir / "leaderboard.json"
    sys.stdout.write(canonical_json(load_json(leaderboard_path)))
    return 0


def command_export(args: argparse.Namespace) -> int:
    export_bundle(Path(args.run), args.candidate, Path(args.out))
    sys.stdout.write(canonical_json({"candidateId": args.candidate, "out": args.out}))
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Offline Signum evolve v0 candidate generator.")
    subcommands = parser.add_subparsers(dest="command", required=True)

    generate = subcommands.add_parser("generate", help="Generate and evaluate candidate catalogs.")
    generate.add_argument("--repo-root", default=".", help="Repository root.")
    generate.add_argument("--config", required=True, help="Config JSON path.")
    generate.add_argument("--run-id", required=True, help="Deterministic run ID.")
    generate.add_argument("--max-candidates", type=int, default=20, help="Maximum candidates to generate.")
    generate.add_argument("--seed", type=int, default=42, help="Recorded deterministic seed.")
    generate.set_defaults(func=command_generate)

    leaderboard = subcommands.add_parser("leaderboard", help="Print a run leaderboard.")
    leaderboard.add_argument("--run", required=True, help="Run output directory.")
    leaderboard.set_defaults(func=command_leaderboard)

    export = subcommands.add_parser("export", help="Export an adoption bundle for one candidate.")
    export.add_argument("--run", required=True, help="Run output directory.")
    export.add_argument("--candidate", required=True, help="Candidate ID.")
    export.add_argument("--out", required=True, help="Output directory.")
    export.set_defaults(func=command_export)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
