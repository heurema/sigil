#!/usr/bin/env python3
"""Summarize existing Codebase Awareness dogfood artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "1.0"
EXIT_OK = 0
EXIT_INVALID_JSON = 3
EXIT_INVALID_SHAPE = 4
EXIT_INFRA = 5


class SummaryError(Exception):
    def __init__(self, exit_code: int, message: str) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.message = message


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a compact reporting-only Codebase Awareness dogfood summary."
    )
    parser.add_argument("--contract-root", required=True, help="Active contract artifact root to read.")
    parser.add_argument("--cache-root", required=True, help="Project-level Codebase Awareness cache root to read.")
    parser.add_argument("--output", default=None, help="Optional JSON output path. Defaults to stdout.")
    return parser.parse_args(argv)


def load_optional_json(path: Path, label: str) -> tuple[bool, dict[str, Any]]:
    if not path.is_file():
        return False, {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SummaryError(EXIT_INVALID_JSON, f"Invalid {label} JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise SummaryError(EXIT_INFRA, f"Unable to read {label} JSON {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SummaryError(EXIT_INVALID_SHAPE, f"{label} JSON must be a top-level object: {path}")
    return True, data


def non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def first_string(*values: Any, default: str = "unknown") -> str:
    for value in values:
        if non_empty_string(value):
            return str(value)
    return default


def safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    return default


def compact_path(value: Any) -> str | None:
    if not non_empty_string(value):
        return None
    text = str(value)
    path = Path(text)
    if path.is_absolute():
        return path.name
    return text


def compact_score(candidate: dict[str, Any]) -> float | None:
    for key in ("score", "confidence"):
        value = candidate.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            return round(float(value), 4)
    return None


def candidate_summary(reuse_candidates: dict[str, Any]) -> tuple[int, list[dict[str, Any]]]:
    raw_candidates = reuse_candidates.get("candidates", [])
    candidates = raw_candidates if isinstance(raw_candidates, list) else []
    candidate_count = safe_int(reuse_candidates.get("candidateCount"), len(candidates))
    if candidate_count < 0:
        candidate_count = len(candidates)

    top_candidates: list[dict[str, Any]] = []
    for item in candidates[:5]:
        if not isinstance(item, dict):
            continue
        top_candidates.append(
            {
                "candidateId": item.get("candidateId"),
                "kind": item.get("kind"),
                "path": compact_path(item.get("path")),
                "symbol": item.get("symbol") if non_empty_string(item.get("symbol")) else None,
                "score": compact_score(item),
            }
        )
    return candidate_count, top_candidates


def reuse_decision_summary(reuse_decision: dict[str, Any], present: bool) -> dict[str, Any]:
    if not present:
        return {"present": False, "decisionCount": 0, "dispositions": {}}

    raw_decisions = reuse_decision.get("decisions", [])
    decisions = raw_decisions if isinstance(raw_decisions, list) else []
    dispositions: Counter[str] = Counter()
    for item in decisions:
        if isinstance(item, dict) and non_empty_string(item.get("disposition")):
            dispositions[str(item["disposition"])] += 1

    return {
        "present": True,
        "decisionCount": len(decisions),
        "dispositions": dict(sorted(dispositions.items())),
    }


def severity_counts_from_findings(duplicate_scan: dict[str, Any]) -> tuple[int, int]:
    major = 0
    critical = 0
    raw_findings = duplicate_scan.get("findings", [])
    findings = raw_findings if isinstance(raw_findings, list) else []
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        severity = finding.get("severity")
        if not isinstance(severity, str):
            continue
        normalized = severity.strip().lower()
        if normalized == "major":
            major += 1
        elif normalized == "critical":
            critical += 1
    return major, critical


def duplicate_scan_summary(duplicate_scan: dict[str, Any], present: bool) -> dict[str, Any]:
    if not present:
        return {"present": False, "recommendedOutcome": None, "majorOrCritical": 0}

    raw_counts = duplicate_scan.get("summaryCounts")
    if isinstance(raw_counts, dict):
        major = safe_int(raw_counts.get("major"))
        critical = safe_int(raw_counts.get("critical"))
    else:
        major, critical = severity_counts_from_findings(duplicate_scan)

    return {
        "present": True,
        "recommendedOutcome": duplicate_scan.get("recommendedOutcome"),
        "majorOrCritical": max(0, major) + max(0, critical),
    }


def load_cache_stats(cache_root: Path) -> dict[str, Any]:
    for filename in ("codebase-index-v1.json", "codebase-index-cached.json", "file-extracts-v1.json"):
        present, data = load_optional_json(cache_root / filename, filename)
        if not present:
            continue
        raw_stats = data.get("scanStats", {})
        stats = raw_stats if isinstance(raw_stats, dict) else {}
        return {
            "present": True,
            "filesReused": max(0, safe_int(stats.get("filesReused"))),
            "filesExtracted": max(0, safe_int(stats.get("filesExtracted"))),
        }
    return {"present": False, "filesReused": 0, "filesExtracted": 0}


def build_summary(contract_root: Path, cache_root: Path) -> dict[str, Any]:
    contract_present, contract = load_optional_json(contract_root / "contract.json", "contract")
    candidates_present, reuse_candidates = load_optional_json(
        contract_root / "reuse_candidates.json", "reuse candidates"
    )
    decision_present, reuse_decision = load_optional_json(contract_root / "reuse_decision.json", "reuse decision")
    duplicate_present, duplicate_scan = load_optional_json(contract_root / "duplicate_scan.json", "duplicate scan")

    candidate_count, top_candidates = (
        candidate_summary(reuse_candidates) if candidates_present else (0, [])
    )
    contract_id = first_string(
        contract.get("contractId") if contract_present else None,
        reuse_candidates.get("contractId") if candidates_present else None,
        reuse_decision.get("contractId") if decision_present else None,
        duplicate_scan.get("contractId") if duplicate_present else None,
        contract_root.name,
    )
    mode = first_string(
        reuse_decision.get("mode") if decision_present else None,
        duplicate_scan.get("mode") if duplicate_present else None,
    )

    return {
        "schemaVersion": SCHEMA_VERSION,
        "contractId": contract_id,
        "mode": mode,
        "candidateCount": candidate_count,
        "topCandidates": top_candidates,
        "reuseDecision": reuse_decision_summary(reuse_decision, decision_present),
        "duplicateScan": duplicate_scan_summary(duplicate_scan, duplicate_present),
        "cacheStats": load_cache_stats(cache_root),
    }


def write_or_print(summary: dict[str, Any], output: str | None) -> None:
    text = json.dumps(summary, indent=2, sort_keys=True) + "\n"
    if output:
        path = Path(output)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print(f"{path.name} written")
    else:
        print(text, end="")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    contract_root = Path(args.contract_root)
    cache_root = Path(args.cache_root)
    try:
        summary = build_summary(contract_root, cache_root)
        write_or_print(summary, args.output)
    except SummaryError as exc:
        print(exc.message, file=sys.stderr)
        return exc.exit_code
    except OSError as exc:
        print(f"Unable to write dogfood summary: {exc}", file=sys.stderr)
        return EXIT_INFRA
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
