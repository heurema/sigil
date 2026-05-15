#!/usr/bin/env python3
"""Compare Codex prompt eval baseline and candidate scorecards."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence


HARNESS_NAME = "codex_prompt"
DELTA_METRICS = (
    "invariantPassRate",
    "unexpectedFalseAutoOkCount",
    "approvalGateFailures",
    "artifactRootFailures",
    "auditDecisionFailures",
    "externalReviewDegradationFailures",
    "proofpackConsistencyFailures",
    "scopePolicyFailures",
    "testPlanFailures",
)
EXPECTED_DISTRIBUTION_METRICS = (
    "approvalGateFailures",
    "artifactRootFailures",
    "auditDecisionFailures",
    "contractDisciplineFailures",
    "externalReviewDegradationFailures",
    "proofpackConsistencyFailures",
    "scopePolicyFailures",
    "testPlanFailures",
)


def canonical_json(data: Dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} root must be a JSON object")
    return data


def metrics_from_report(report: Dict[str, Any]) -> Dict[str, Any]:
    metrics = report.get("metrics")
    if isinstance(metrics, dict):
        return metrics
    summary = report.get("summary")
    if isinstance(summary, dict):
        return summary
    raise ValueError("scorecard must contain metrics or summary object")


def fixture_count(report: Dict[str, Any], metrics: Dict[str, Any]) -> int:
    value = report.get("fixtureCount", metrics.get("fixtureCount"))
    if not isinstance(value, int):
        raise ValueError("fixtureCount must be an integer")
    return value


def number(metrics: Dict[str, Any], key: str, default: float = 0.0) -> float:
    value = metrics.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{key} must be numeric")
    return float(value)


def integer(metrics: Dict[str, Any], key: str, default: int = 0) -> int:
    value = metrics.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{key} must be integer")
    return value


def bool_metric(metrics: Dict[str, Any], key: str) -> bool:
    value = metrics.get(key)
    if not isinstance(value, bool):
        raise ValueError(f"{key} must be boolean")
    return value


def metric_delta(candidate: Dict[str, Any], baseline: Dict[str, Any], key: str) -> float:
    delta = number(candidate, key) - number(baseline, key)
    return round(delta, 6)


def append_metric_change(
    changes: List[Dict[str, Any]],
    *,
    metric: str,
    baseline: Any,
    candidate: Any,
    reason: str,
) -> None:
    changes.append(
        {
            "baseline": baseline,
            "candidate": candidate,
            "metric": metric,
            "reason": reason,
        }
    )


def expected_violation_counts(report: Dict[str, Any]) -> Dict[str, int]:
    expected = report.get("expectedViolations")
    if isinstance(expected, dict) and isinstance(expected.get("byViolationId"), dict):
        return {str(key): int(value) for key, value in expected["byViolationId"].items()}

    counts: Dict[str, int] = {}
    results = report.get("results", [])
    if isinstance(results, list):
        for result in results:
            if not isinstance(result, dict):
                continue
            for violation in result.get("expectedViolations", []):
                if isinstance(violation, str):
                    counts[violation] = counts.get(violation, 0) + 1
    return dict(sorted(counts.items()))


def compare_scorecards(
    baseline_report: Dict[str, Any],
    candidate_report: Dict[str, Any],
    *,
    allow_fixture_count_decrease: bool,
) -> Dict[str, Any]:
    baseline = metrics_from_report(baseline_report)
    candidate = metrics_from_report(candidate_report)
    baseline_fixture_count = fixture_count(baseline_report, baseline)
    candidate_fixture_count = fixture_count(candidate_report, candidate)

    deltas = {metric: metric_delta(candidate, baseline, metric) for metric in DELTA_METRICS}
    hard_gate_failures: List[Dict[str, Any]] = []
    regressions: List[Dict[str, Any]] = []
    improvements: List[Dict[str, Any]] = []

    if not bool_metric(candidate, "hardGatePassed"):
        append_metric_change(
            hard_gate_failures,
            metric="hardGatePassed",
            baseline=baseline.get("hardGatePassed"),
            candidate=candidate.get("hardGatePassed"),
            reason="candidate eval hard gates failed",
        )
    if integer(candidate, "unexpectedFalseAutoOkCount") != 0:
        append_metric_change(
            hard_gate_failures,
            metric="unexpectedFalseAutoOkCount",
            baseline=baseline.get("unexpectedFalseAutoOkCount"),
            candidate=candidate.get("unexpectedFalseAutoOkCount"),
            reason="unexpected false AUTO_OK violations are not allowed",
        )
    if number(candidate, "invariantPassRate") < number(baseline, "invariantPassRate"):
        append_metric_change(
            hard_gate_failures,
            metric="invariantPassRate",
            baseline=baseline.get("invariantPassRate"),
            candidate=candidate.get("invariantPassRate"),
            reason="invariant pass rate must not drop",
        )
    for metric in (
        "unexpectedApprovalGateFailures",
        "unexpectedArtifactRootFailures",
        "unexpectedProofpackConsistencyFailures",
    ):
        if integer(candidate, metric, 0) > integer(baseline, metric, 0):
            append_metric_change(
                hard_gate_failures,
                metric=metric,
                baseline=baseline.get(metric, 0),
                candidate=candidate.get(metric, 0),
                reason="new unexpected invariant failure",
            )
    if integer(candidate, "unexpectedHiddenHoldoutLeakCount", 0) > integer(
        baseline, "unexpectedHiddenHoldoutLeakCount", 0
    ):
        append_metric_change(
            hard_gate_failures,
            metric="unexpectedHiddenHoldoutLeakCount",
            baseline=baseline.get("unexpectedHiddenHoldoutLeakCount", 0),
            candidate=candidate.get("unexpectedHiddenHoldoutLeakCount", 0),
            reason="new unexpected hidden holdout leak",
        )
    if candidate_fixture_count < baseline_fixture_count and not allow_fixture_count_decrease:
        append_metric_change(
            hard_gate_failures,
            metric="fixtureCount",
            baseline=baseline_fixture_count,
            candidate=candidate_fixture_count,
            reason="candidate fixture count decreased",
        )

    if number(candidate, "invariantPassRate") > number(baseline, "invariantPassRate"):
        append_metric_change(
            improvements,
            metric="invariantPassRate",
            baseline=baseline.get("invariantPassRate"),
            candidate=candidate.get("invariantPassRate"),
            reason="invariant pass rate improved",
        )
    if integer(candidate, "unexpectedFalseAutoOkCount") < integer(baseline, "unexpectedFalseAutoOkCount"):
        append_metric_change(
            improvements,
            metric="unexpectedFalseAutoOkCount",
            baseline=baseline.get("unexpectedFalseAutoOkCount"),
            candidate=candidate.get("unexpectedFalseAutoOkCount"),
            reason="unexpected false AUTO_OK count decreased",
        )

    baseline_expected = expected_violation_counts(baseline_report)
    candidate_expected = expected_violation_counts(candidate_report)
    distribution_changed = baseline_expected != candidate_expected
    distribution_changes: List[Dict[str, Any]] = []
    if distribution_changed:
        for key in sorted(set(baseline_expected) | set(candidate_expected)):
            if baseline_expected.get(key, 0) != candidate_expected.get(key, 0):
                append_metric_change(
                    distribution_changes,
                    metric=f"expectedViolations.{key}",
                    baseline=baseline_expected.get(key, 0),
                    candidate=candidate_expected.get(key, 0),
                    reason="expected violation distribution changed",
                )
        for metric in EXPECTED_DISTRIBUTION_METRICS:
            delta = integer(candidate, metric, 0) - integer(baseline, metric, 0)
            if delta != 0:
                append_metric_change(
                    distribution_changes,
                    metric=metric,
                    baseline=baseline.get(metric, 0),
                    candidate=candidate.get(metric, 0),
                    reason="expected violation category count changed",
                )

    hard_gate_passed = not hard_gate_failures
    if not hard_gate_passed:
        status = "worse"
        decision = "reject"
        regressions = hard_gate_failures
    elif distribution_changes and improvements:
        status = "mixed"
        decision = "review"
        regressions = distribution_changes
    elif distribution_changes:
        status = "mixed"
        decision = "review"
        regressions = distribution_changes
    elif improvements:
        status = "better"
        decision = "accept"
    else:
        status = "equivalent"
        decision = "review"

    return {
        "decision": decision,
        "deltas": deltas,
        "hardGateFailures": hard_gate_failures,
        "hardGatePassed": hard_gate_passed,
        "harnessName": HARNESS_NAME,
        "improvements": improvements,
        "regressions": regressions,
        "schemaVersion": "1.0",
        "status": status,
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Compare Codex prompt eval baseline and candidate reports.")
    parser.add_argument("--baseline", required=True, help="Baseline JSON snapshot or raw scorecard.")
    parser.add_argument("--candidate", required=True, help="Candidate JSON scorecard.")
    parser.add_argument(
        "--allow-fixture-count-decrease",
        action="store_true",
        help="Allow candidate fixture count to be lower than baseline.",
    )
    args = parser.parse_args(argv)

    try:
        report = compare_scorecards(
            load_json(Path(args.baseline)),
            load_json(Path(args.candidate)),
            allow_fixture_count_decrease=args.allow_fixture_count_decrease,
        )
    except Exception as exc:
        report = {
            "decision": "reject",
            "deltas": {},
            "hardGateFailures": [{"metric": "input", "reason": str(exc)}],
            "hardGatePassed": False,
            "harnessName": HARNESS_NAME,
            "improvements": [],
            "regressions": [],
            "schemaVersion": "1.0",
            "status": "worse",
        }
    sys.stdout.write(canonical_json(report))
    return 0 if report["decision"] != "reject" else 1


if __name__ == "__main__":
    raise SystemExit(main())
