#!/usr/bin/env python3
"""Run deterministic offline Codex Signum prompt eval fixtures."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from checks_codex_prompt import canonical_json, evaluate_fixture


FAILURE_METRICS = {
    "approvalGateFailures": ("approval.",),
    "artifactRootFailures": ("artifact.",),
    "auditDecisionFailures": ("audit.", "decision."),
    "contractDisciplineFailures": ("contract.",),
    "externalReviewDegradationFailures": ("external.",),
    "proofpackConsistencyFailures": ("proofpack.",),
    "scopePolicyFailures": ("scope.",),
}


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("fixture root must be a JSON object")
    return data


def collect_fixture_paths(fixtures_dir: Path) -> List[Path]:
    return sorted(
        (path for path in fixtures_dir.rglob("*.json") if path.is_file()),
        key=lambda path: path.relative_to(fixtures_dir).as_posix(),
    )


def display_path(path: Path, fixtures_dir: Path) -> str:
    try:
        return path.relative_to(fixtures_dir).as_posix()
    except ValueError:
        return path.name


def count_violations(results: Sequence[Dict[str, Any]], prefixes: Sequence[str]) -> int:
    return sum(
        1
        for result in results
        for violation in result.get("observedViolations", [])
        if any(violation.startswith(prefix) for prefix in prefixes)
    )


def count_expected_violations(results: Sequence[Dict[str, Any]], prefixes: Sequence[str]) -> int:
    return sum(
        1
        for result in results
        for violation in result.get("expectedViolations", [])
        if any(violation.startswith(prefix) for prefix in prefixes)
    )


def count_unexpected_violations(results: Sequence[Dict[str, Any]], prefixes: Sequence[str]) -> int:
    return sum(
        1
        for result in results
        for violation in result.get("unexpectedViolations", [])
        if any(violation.startswith(prefix) for prefix in prefixes)
    )


def is_false_auto_ok_violation(violation: str) -> bool:
    return (
        "false_auto_ok" in violation
        or violation == "decision.must_not_claim_auto_ok"
        or violation == "scope.policy_sensitive_auto_ok"
        or violation == "scope.out_of_scope_auto_ok"
    )


def summarize(results: Sequence[Dict[str, Any]], fixture_count: int) -> Dict[str, Any]:
    passed = sum(1 for result in results if result.get("status") == "passed")
    failed = fixture_count - passed
    detected_false_auto_ok = sum(
        1
        for result in results
        for violation in result.get("observedViolations", [])
        if is_false_auto_ok_violation(violation)
    )
    expected_false_auto_ok = sum(
        1
        for result in results
        for violation in result.get("expectedViolations", [])
        if is_false_auto_ok_violation(violation)
    )
    unexpected_false_auto_ok = sum(
        1
        for result in results
        for violation in result.get("unexpectedViolations", [])
        if is_false_auto_ok_violation(violation)
    )
    summary: Dict[str, Any] = {
        "detectedFalseAutoOkCount": detected_false_auto_ok,
        "detectedViolationCount": sum(len(result.get("observedViolations", [])) for result in results),
        "failed": failed,
        "fixtureCount": fixture_count,
        "expectedFalseAutoOkCount": expected_false_auto_ok,
        "expectedViolationCount": sum(len(result.get("expectedViolations", [])) for result in results),
        "falseAutoOkCount": detected_false_auto_ok,
        "hardGateFailures": [
            {
                "caseId": result.get("caseId"),
                "missingExpectedViolations": result.get("missingExpectedViolations", []),
                "unexpectedViolations": result.get("unexpectedViolations", []),
            }
            for result in results
            if result.get("status") != "passed"
        ],
        "hardGatePassed": failed == 0 and fixture_count > 0,
        "invariantPassRate": round(passed / fixture_count, 6) if fixture_count else 0.0,
        "missingExpectedViolationCount": sum(len(result.get("missingExpectedViolations", [])) for result in results),
        "passed": passed,
        "unexpectedFalseAutoOkCount": unexpected_false_auto_ok,
        "unexpectedHiddenHoldoutLeakCount": sum(
            1
            for result in results
            for violation in result.get("unexpectedViolations", [])
            if violation == "scope.hidden_holdout_leak"
        ),
        "unexpectedViolationCount": sum(len(result.get("unexpectedViolations", [])) for result in results),
    }
    for metric, prefixes in FAILURE_METRICS.items():
        summary[metric] = count_violations(results, prefixes)
        summary[f"expected{metric[0].upper()}{metric[1:]}"] = count_expected_violations(results, prefixes)
        summary[f"unexpected{metric[0].upper()}{metric[1:]}"] = count_unexpected_violations(results, prefixes)
    return dict(sorted(summary.items()))


def main(argv: Optional[Sequence[str]] = None) -> int:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run Codex Signum prompt offline eval fixtures.")
    parser.add_argument(
        "--fixtures-dir",
        default=str(script_dir / "fixtures"),
        help="Directory containing Codex prompt eval fixtures.",
    )
    parser.add_argument("--json-output", help="Optional path to write the deterministic JSON report.")
    parser.add_argument("--include-timestamp", action="store_true", help="Include generatedAt timestamp in output.")
    args = parser.parse_args(argv)

    fixtures_dir = Path(args.fixtures_dir)
    fixture_paths = collect_fixture_paths(fixtures_dir)
    results: List[Dict[str, Any]] = []

    for fixture_path in fixture_paths:
        try:
            fixture = load_json(fixture_path)
            result = evaluate_fixture(fixture)
            result["fixturePath"] = display_path(fixture_path, fixtures_dir)
        except Exception as exc:  # surfaced in deterministic JSON for shell tests
            result = {
                "caseId": fixture_path.stem,
                "category": None,
                "description": "",
                "expectedViolations": [],
                "fixturePath": display_path(fixture_path, fixtures_dir),
                "missingExpectedViolations": [],
                "observedVerdict": None,
                "observedViolations": ["runner.exception"],
                "riskLevel": None,
                "status": "failed",
                "unexpectedViolations": [str(exc)],
            }
        results.append(result)

    results = sorted(results, key=lambda item: (str(item.get("category", "")), str(item.get("caseId", ""))))
    report: Dict[str, Any] = {
        "results": results,
        "summary": summarize(results, len(fixture_paths)),
    }
    if args.include_timestamp:
        report["generatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

    blob = canonical_json(report)
    if args.json_output:
        output_path = Path(args.json_output)
        if not output_path.is_absolute():
            output_path = Path.cwd() / output_path
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(blob, encoding="utf-8")
    sys.stdout.write(blob)
    return 0 if report["summary"]["hardGatePassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
