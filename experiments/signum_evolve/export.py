"""Adoption bundle export for signum-evolve v0."""
from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any, Dict

from .candidate import load_json
from .mutate import mutation_summary


def copy_required(candidate_dir: Path, out_dir: Path) -> Dict[str, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    mapping = {
        "candidate": (candidate_dir / "candidate.json", out_dir / "candidate.json"),
        "catalog": (candidate_dir / "policy-rules.json", out_dir / "policy-rules.candidate.json"),
        "compare": (candidate_dir / "compare.json", out_dir / "compare.json"),
        "eval": (candidate_dir / "eval.json", out_dir / "eval.json"),
    }
    for source, target in mapping.values():
        if not source.exists():
            raise FileNotFoundError(source)
        shutil.copyfile(source, target)
    return {key: target for key, (_source, target) in mapping.items()}


def write_report(out_dir: Path, candidate: Dict[str, Any], compare: Dict[str, Any]) -> None:
    lines = [
        "# Signum Evolve Adoption Report",
        "",
        f"- Candidate ID: `{candidate['candidateId']}`",
        f"- Mutation: `{mutation_summary(candidate)}`",
        f"- Comparison status: `{compare.get('status')}`",
        f"- Decision: `{compare.get('decision')}`",
        f"- Hard gate passed: `{compare.get('hardGatePassed')}`",
        f"- Improvements: `{len(compare.get('improvements', []))}`",
        f"- Regressions: `{len(compare.get('regressions', []))}`",
        "",
        "## Expected Files To Change If Adopted",
        "",
        "- `lib/policy-rules.json`",
        "- `platforms/claude-code/lib/policy-rules.json`",
        "- policy scanner eval baseline only after accepted behavior evidence",
        "",
        "## Warning",
        "",
        "This bundle is not auto-applied. Adoption requires a separate normal PR and maintainer review.",
        "",
    ]
    (out_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def write_checklist(out_dir: Path) -> None:
    lines = [
        "# Adoption Checklist",
        "",
        "- [ ] Candidate generated offline.",
        "- [ ] No CRITICAL rules changed.",
        "- [ ] Hard gates passed.",
        "- [ ] Comparison reviewed.",
        "- [ ] Maintainer accepts trade-off.",
        "- [ ] Adoption uses a separate normal PR.",
        "",
    ]
    (out_dir / "adoption-checklist.md").write_text("\n".join(lines), encoding="utf-8")


def export_bundle(run_dir: Path, candidate_id: str, out_dir: Path) -> Path:
    candidate_dir = run_dir / "candidates" / candidate_id
    if not candidate_dir.is_dir():
        raise FileNotFoundError(f"candidate not found in run: {candidate_id}")
    copy_required(candidate_dir, out_dir)
    candidate = load_json(candidate_dir / "candidate.json")
    compare = load_json(candidate_dir / "compare.json")
    write_report(out_dir, candidate, compare)
    write_checklist(out_dir)
    return out_dir
