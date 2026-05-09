#!/usr/bin/env python3
"""Compare policy scanner eval baseline and candidate scorecards."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence


HARNESS_NAME = "policy_scanner"
DELTA_METRICS = (
    "precision",
    "recall",
    "f1",
    "criticalFalseNegatives",
    "falsePositives",
    "knownBaselineFailures",
    "runtimeMsP95",
    "determinismScore",
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


def compare_scorecards(baseline_report: Dict[str, Any], candidate_report: Dict[str, Any]) -> Dict[str, Any]:
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
    if integer(candidate, "criticalFalseNegatives") != 0:
        append_metric_change(
            hard_gate_failures,
            metric="criticalFalseNegatives",
            baseline=baseline.get("criticalFalseNegatives"),
            candidate=candidate.get("criticalFalseNegatives"),
            reason="critical false negatives are not allowed",
        )
    if number(candidate, "determinismScore") != 1.0:
        append_metric_change(
            hard_gate_failures,
            metric="determinismScore",
            baseline=baseline.get("determinismScore"),
            candidate=candidate.get("determinismScore"),
            reason="candidate output is not deterministic",
        )
    if "unexpectedCriticalFindings" in candidate and integer(candidate, "unexpectedCriticalFindings") != 0:
        append_metric_change(
            hard_gate_failures,
            metric="unexpectedCriticalFindings",
            baseline=baseline.get("unexpectedCriticalFindings"),
            candidate=candidate.get("unexpectedCriticalFindings"),
            reason="negative fixtures produced unexpected CRITICAL findings",
        )

    recall_delta = number(candidate, "recall") - number(baseline, "recall")
    precision_delta = number(candidate, "precision") - number(baseline, "precision")
    critical_recall_delta = number(candidate, "criticalRecall") - number(baseline, "criticalRecall")
    false_positive_delta = integer(candidate, "falsePositives") - integer(baseline, "falsePositives")
    known_failure_delta = integer(candidate, "knownBaselineFailures", 0) - integer(baseline, "knownBaselineFailures", 0)

    false_positive_budget = number(baseline, "falsePositives") * 1.10
    if integer(baseline, "falsePositives") == 0:
        false_positive_budget = 0.0
    recall_materially_improved = recall_delta >= 0.05

    if precision_delta < -0.02 and not (
        recall_materially_improved and number(candidate, "falsePositives") <= false_positive_budget
    ):
        append_metric_change(
            regressions,
            metric="precision",
            baseline=baseline.get("precision"),
            candidate=candidate.get("precision"),
            reason="precision dropped beyond tolerance",
        )
    if recall_delta < 0:
        append_metric_change(
            regressions,
            metric="recall",
            baseline=baseline.get("recall"),
            candidate=candidate.get("recall"),
            reason="recall must not drop",
        )
    if critical_recall_delta < 0:
        append_metric_change(
            regressions,
            metric="criticalRecall",
            baseline=baseline.get("criticalRecall"),
            candidate=candidate.get("criticalRecall"),
            reason="critical recall must not drop",
        )
    if false_positive_delta > 0 and not recall_materially_improved:
        append_metric_change(
            regressions,
            metric="falsePositives",
            baseline=baseline.get("falsePositives"),
            candidate=candidate.get("falsePositives"),
            reason="false positives increased without material recall improvement",
        )
    elif number(candidate, "falsePositives") > false_positive_budget and not recall_materially_improved:
        append_metric_change(
            regressions,
            metric="falsePositives",
            baseline=baseline.get("falsePositives"),
            candidate=candidate.get("falsePositives"),
            reason="false positives exceed the 10 percent budget",
        )

    if known_failure_delta > 0:
        append_metric_change(
            regressions,
            metric="knownBaselineFailures",
            baseline=baseline.get("knownBaselineFailures"),
            candidate=candidate.get("knownBaselineFailures"),
            reason="known baseline failures increased",
        )
    if candidate_fixture_count < baseline_fixture_count:
        append_metric_change(
            regressions,
            metric="fixtureCount",
            baseline=baseline_fixture_count,
            candidate=candidate_fixture_count,
            reason="candidate fixture count decreased",
        )

    if precision_delta > 0:
        append_metric_change(
            improvements,
            metric="precision",
            baseline=baseline.get("precision"),
            candidate=candidate.get("precision"),
            reason="precision improved",
        )
    if recall_delta > 0:
        append_metric_change(
            improvements,
            metric="recall",
            baseline=baseline.get("recall"),
            candidate=candidate.get("recall"),
            reason="recall improved",
        )
    if metric_delta(candidate, baseline, "f1") > 0:
        append_metric_change(
            improvements,
            metric="f1",
            baseline=baseline.get("f1"),
            candidate=candidate.get("f1"),
            reason="f1 improved",
        )
    if integer(candidate, "criticalFalseNegatives") < integer(baseline, "criticalFalseNegatives"):
        append_metric_change(
            improvements,
            metric="criticalFalseNegatives",
            baseline=baseline.get("criticalFalseNegatives"),
            candidate=candidate.get("criticalFalseNegatives"),
            reason="critical false negatives decreased",
        )
    if integer(candidate, "falsePositives") < integer(baseline, "falsePositives"):
        append_metric_change(
            improvements,
            metric="falsePositives",
            baseline=baseline.get("falsePositives"),
            candidate=candidate.get("falsePositives"),
            reason="false positives decreased",
        )
    if known_failure_delta < 0:
        append_metric_change(
            improvements,
            metric="knownBaselineFailures",
            baseline=baseline.get("knownBaselineFailures"),
            candidate=candidate.get("knownBaselineFailures"),
            reason="known baseline failures were resolved",
        )

    hard_gate_passed = not hard_gate_failures
    if not hard_gate_passed:
        status = "worse"
        decision = "reject"
    elif regressions and improvements:
        status = "mixed"
        decision = "review"
    elif regressions:
        status = "worse"
        decision = "review"
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
    parser = argparse.ArgumentParser(description="Compare policy scanner eval baseline and candidate reports.")
    parser.add_argument("--baseline", required=True, help="Baseline JSON snapshot or raw scorecard.")
    parser.add_argument("--candidate", required=True, help="Candidate JSON scorecard.")
    args = parser.parse_args(argv)

    try:
        report = compare_scorecards(load_json(Path(args.baseline)), load_json(Path(args.candidate)))
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
