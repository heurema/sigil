#!/usr/bin/env python3
"""Deterministic offline eval harness for lib/policy-scanner.sh."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


VALID_KINDS = {"positive", "negative", "suppression", "adversarial"}
SHAPE_FIELDS = {
    "findings": list,
    "suppressedFindings": list,
    "rejectedSuppressions": list,
    "summaryCounts": dict,
}


@dataclass(frozen=True)
class ScannerRun:
    returncode: int
    runtime_ms: float
    stdout: str
    stderr: str
    output: Optional[Dict[str, Any]]
    output_error: Optional[str]


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise argparse.ArgumentTypeError(f"expected true or false, got {value!r}")


def canonical_json(data: Dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("fixture root must be a JSON object")
    return data


def resolve_path(value: Optional[str], repo_root: Path, default: Path) -> Path:
    if not value:
        return default
    path = Path(value)
    if path.is_absolute():
        return path
    return repo_root / path


def percentile(values: Sequence[float], percentile_value: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    index = (len(ordered) - 1) * percentile_value
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    weight = index - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def rounded_metric(value: float) -> float:
    return round(value, 6)


def stable_finding(finding: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "file": finding.get("file"),
        "line": finding.get("line"),
        "pattern": finding.get("pattern"),
        "ruleId": finding.get("ruleId"),
        "severity": finding.get("severity"),
        "snippet": finding.get("snippet"),
        "type": finding.get("type"),
    }


def stable_suppressed(finding: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "file": finding.get("file"),
        "line": finding.get("line"),
        "ruleId": finding.get("ruleId"),
        "severity": finding.get("severity"),
        "suppressionLine": finding.get("suppressionLine"),
        "suppressionReason": finding.get("suppressionReason"),
        "suppressionScope": finding.get("suppressionScope"),
    }


def stable_rejected(rejection: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "file": rejection.get("file"),
        "line": rejection.get("line", rejection.get("targetLine", rejection.get("markerLine"))),
        "markerLine": rejection.get("markerLine"),
        "rejectedReason": rejection.get("rejectedReason"),
        "ruleId": rejection.get("ruleId"),
        "severity": rejection.get("severity"),
        "targetLine": rejection.get("targetLine"),
    }


def sort_records(records: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return sorted(
        records,
        key=lambda item: (
            str(item.get("ruleId", "")),
            str(item.get("severity", "")),
            str(item.get("file", "")),
            -1 if item.get("line") is None else int(item.get("line", -1)),
            str(item.get("rejectedReason", "")),
            str(item.get("snippet", "")),
        ),
    )


def normalize_scanner_output(output: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "findings": sort_records(stable_finding(item) for item in output.get("findings", [])),
        "rejectedSuppressions": sort_records(
            stable_rejected(item) for item in output.get("rejectedSuppressions", [])
        ),
        "summaryCounts": output.get("summaryCounts", {}),
        "suppressedFindings": sort_records(
            stable_suppressed(item) for item in output.get("suppressedFindings", [])
        ),
    }


def validate_scanner_shape(output: Any) -> Optional[str]:
    if not isinstance(output, dict):
        return "policy_scan.json root is not an object"
    for field, expected_type in SHAPE_FIELDS.items():
        if field not in output:
            return f"policy_scan.json missing {field}"
        if not isinstance(output[field], expected_type):
            return f"policy_scan.json field {field} has invalid type"
    return None


def run_scanner(repo_root: Path, patch_text: str) -> ScannerRun:
    with tempfile.TemporaryDirectory(prefix="signum-policy-scanner-eval-") as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        patch_path = temp_dir / "combined.patch"
        output_path = temp_dir / "policy_scan.json"
        patch_path.write_text(patch_text, encoding="utf-8")

        start = time.perf_counter()
        proc = subprocess.run(
            ["bash", "lib/policy-scanner.sh", str(patch_path)],
            cwd=str(repo_root),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        runtime_ms = (time.perf_counter() - start) * 1000.0

        output: Optional[Dict[str, Any]] = None
        output_error: Optional[str] = None
        if not output_path.exists():
            output_error = "policy_scan.json was not created"
        else:
            try:
                loaded = json.loads(output_path.read_text(encoding="utf-8"))
                shape_error = validate_scanner_shape(loaded)
                if shape_error:
                    output_error = shape_error
                else:
                    output = loaded
            except json.JSONDecodeError as exc:
                output_error = f"policy_scan.json is invalid JSON: {exc}"

        return ScannerRun(
            returncode=proc.returncode,
            runtime_ms=runtime_ms,
            stdout=proc.stdout.strip(),
            stderr=proc.stderr.strip(),
            output=output,
            output_error=output_error,
        )


def expected_line(expected: Dict[str, Any]) -> Optional[int]:
    line = expected.get("line")
    if line is None:
        return None
    if isinstance(line, int):
        return line
    raise ValueError(f"line must be integer or null in expected finding: {expected!r}")


def record_matches_expected(actual: Dict[str, Any], expected: Dict[str, Any]) -> bool:
    if actual.get("ruleId") != expected.get("ruleId"):
        return False
    if actual.get("severity") != expected.get("severity"):
        return False
    if actual.get("file") != expected.get("file"):
        return False
    line = expected_line(expected)
    return line is None or actual.get("line") == line


def record_matches_allowed(actual: Dict[str, Any], allowed: Dict[str, Any]) -> bool:
    if allowed.get("ruleId") is not None and actual.get("ruleId") != allowed.get("ruleId"):
        return False
    if allowed.get("severity") is not None and actual.get("severity") != allowed.get("severity"):
        return False
    if allowed.get("file") is not None and actual.get("file") != allowed.get("file"):
        return False
    line = allowed.get("line")
    return line is None or actual.get("line") == line


def has_severity_mismatch(actuals: Sequence[Dict[str, Any]], expected: Dict[str, Any]) -> bool:
    expected_line_value = expected_line(expected)
    for actual in actuals:
        if actual.get("ruleId") != expected.get("ruleId"):
            continue
        if actual.get("file") != expected.get("file"):
            continue
        if expected_line_value is not None and actual.get("line") != expected_line_value:
            continue
        if actual.get("severity") != expected.get("severity"):
            return True
    return False


def rejected_matches_expected(actual: Dict[str, Any], expected: Dict[str, Any]) -> bool:
    if actual.get("ruleId") != expected.get("ruleId"):
        return False
    if actual.get("file") != expected.get("file"):
        return False
    if expected.get("rejectedReason") is not None and actual.get("rejectedReason") != expected.get("rejectedReason"):
        return False
    if expected.get("severity") is not None and actual.get("severity") != expected.get("severity"):
        return False
    line = expected.get("line")
    if line is None:
        return True
    actual_lines = {actual.get("line"), actual.get("targetLine"), actual.get("markerLine")}
    return line in actual_lines


def match_expected_records(
    actuals: Sequence[Dict[str, Any]],
    expected_records: Sequence[Dict[str, Any]],
    *,
    matcher,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], List[int]]:
    matched: List[Dict[str, Any]] = []
    missing: List[Dict[str, Any]] = []
    matched_indexes: List[int] = []
    used_actuals = set()
    for expected in expected_records:
        found_index: Optional[int] = None
        for index, actual in enumerate(actuals):
            if index in used_actuals:
                continue
            if matcher(actual, expected):
                found_index = index
                break
        if found_index is None:
            missing.append(expected)
        else:
            used_actuals.add(found_index)
            matched_indexes.append(found_index)
            matched.append(actuals[found_index])
    return matched, missing, matched_indexes


def validate_fixture(fixture: Dict[str, Any], path: Path) -> List[str]:
    errors: List[str] = []
    required = {
        "caseId": str,
        "kind": str,
        "description": str,
        "patch": str,
        "expectedFindings": list,
        "allowedExtraFindings": list,
        "tags": list,
    }
    for field, expected_type in required.items():
        if field not in fixture:
            errors.append(f"{path}: missing {field}")
        elif not isinstance(fixture[field], expected_type):
            errors.append(f"{path}: {field} must be {expected_type.__name__}")
    kind = fixture.get("kind")
    if isinstance(kind, str) and kind not in VALID_KINDS:
        errors.append(f"{path}: invalid kind {kind}")
    if kind == "negative" and fixture.get("expectedFindings") != []:
        errors.append(f"{path}: negative fixtures must have empty expectedFindings")
    for field in ("expectedSuppressedFindings", "expectedRejectedSuppressions"):
        if field in fixture and not isinstance(fixture[field], list):
            errors.append(f"{path}: {field} must be list")
    known = fixture.get("knownBaselineFailure")
    if known is not None and not isinstance(known, dict):
        errors.append(f"{path}: knownBaselineFailure must be object")
    return errors


def evaluate_fixture(repo_root: Path, fixture_path: Path, fixture: Dict[str, Any], repeat: int) -> Dict[str, Any]:
    validation_errors = validate_fixture(fixture, fixture_path)
    if validation_errors:
        return {
            "actualFindings": [],
            "allowedExtraFindings": [],
            "caseId": fixture.get("caseId", fixture_path.stem),
            "description": fixture.get("description"),
            "expectedFindings": fixture.get("expectedFindings", []),
            "failedChecks": ["fixture_schema"],
            "falseNegatives": [],
            "falsePositives": [],
            "kind": fixture.get("kind"),
            "knownBaselineFailure": fixture.get("knownBaselineFailure"),
            "matchedFindings": [],
            "missingRejectedSuppressions": [],
            "missingSuppressedFindings": [],
            "path": fixture_path.as_posix(),
            "rejectedSuppressions": [],
            "scannerErrors": validation_errors,
            "severityMismatches": [],
            "status": "failed",
            "suppressedFindings": [],
            "unexpectedCriticalFindings": [],
        }

    runs = [run_scanner(repo_root, fixture["patch"]) for _ in range(repeat)]
    scanner_errors: List[str] = []
    normalized_outputs: List[Dict[str, Any]] = []
    runtime_ms = [run.runtime_ms for run in runs]

    for index, run in enumerate(runs, start=1):
        if run.returncode != 0:
            scanner_errors.append(f"run {index}: scanner exited {run.returncode}")
        if run.output_error:
            scanner_errors.append(f"run {index}: {run.output_error}")
        if run.output is not None:
            normalized_outputs.append(normalize_scanner_output(run.output))

    deterministic = bool(normalized_outputs) and all(item == normalized_outputs[0] for item in normalized_outputs[1:])
    baseline_output = normalized_outputs[0] if normalized_outputs else {
        "findings": [],
        "rejectedSuppressions": [],
        "summaryCounts": {},
        "suppressedFindings": [],
    }
    actual_findings = baseline_output["findings"]
    suppressed_findings = baseline_output["suppressedFindings"]
    rejected_suppressions = baseline_output["rejectedSuppressions"]

    expected_findings = fixture["expectedFindings"]
    allowed_extra = fixture["allowedExtraFindings"]
    matched, missing, matched_indexes = match_expected_records(
        actual_findings,
        expected_findings,
        matcher=record_matches_expected,
    )
    used_actuals = set(matched_indexes)

    allowed_indexes = set()
    allowed_actuals: List[Dict[str, Any]] = []
    for index, actual in enumerate(actual_findings):
        if index in used_actuals:
            continue
        if any(record_matches_allowed(actual, allowed) for allowed in allowed_extra):
            allowed_indexes.add(index)
            allowed_actuals.append(actual)

    false_positives = [
        actual for index, actual in enumerate(actual_findings)
        if index not in used_actuals and index not in allowed_indexes
    ]
    severity_mismatches = [
        expected for expected in missing
        if has_severity_mismatch(actual_findings, expected)
    ]

    expected_suppressed = fixture.get("expectedSuppressedFindings", [])
    matched_suppressed, missing_suppressed, _ = match_expected_records(
        suppressed_findings,
        expected_suppressed,
        matcher=record_matches_expected,
    )
    expected_rejected = fixture.get("expectedRejectedSuppressions", [])
    matched_rejected, missing_rejected, _ = match_expected_records(
        rejected_suppressions,
        expected_rejected,
        matcher=rejected_matches_expected,
    )

    unexpected_critical = [
        actual for actual in false_positives
        if fixture["kind"] == "negative" and actual.get("severity") == "CRITICAL"
    ]

    failed_checks: List[str] = []
    if scanner_errors:
        failed_checks.append("scanner_output")
    if not deterministic:
        failed_checks.append("nondeterministic_output")
    if missing:
        failed_checks.append("missing_expected_findings")
    if false_positives:
        failed_checks.append("unexpected_findings")
    if severity_mismatches:
        failed_checks.append("severity_mismatch")
    if missing_suppressed:
        failed_checks.append("missing_suppressed_findings")
    if missing_rejected:
        failed_checks.append("missing_rejected_suppressions")
    if unexpected_critical:
        failed_checks.append("unexpected_critical_negative_finding")

    known_baseline = fixture.get("knownBaselineFailure")
    if failed_checks and known_baseline:
        status = "known_baseline_failure"
    elif failed_checks:
        status = "failed"
    else:
        status = "passed"

    return {
        "actualFindings": actual_findings,
        "allowedExtraFindings": allowed_actuals,
        "caseId": fixture["caseId"],
        "description": fixture["description"],
        "deterministic": deterministic,
        "expectedFindings": expected_findings,
        "failedChecks": sorted(set(failed_checks)),
        "falseNegatives": missing,
        "falsePositives": false_positives,
        "kind": fixture["kind"],
        "knownBaselineFailure": known_baseline,
        "matchedFindings": matched,
        "matchedRejectedSuppressions": matched_rejected,
        "matchedSuppressedFindings": matched_suppressed,
        "missingRejectedSuppressions": missing_rejected,
        "missingSuppressedFindings": missing_suppressed,
        "path": fixture_path.as_posix(),
        "rejectedSuppressions": rejected_suppressions,
        "runtimeMs": [rounded_metric(value) for value in runtime_ms],
        "scannerErrors": scanner_errors,
        "severityMismatches": severity_mismatches,
        "status": status,
        "suppressedFindings": suppressed_findings,
        "tags": fixture["tags"],
        "unexpectedCriticalFindings": unexpected_critical,
    }


def ratio(numerator: int, denominator: int, empty_value: float = 1.0) -> float:
    if denominator == 0:
        return empty_value
    return numerator / denominator


def summarize(results: Sequence[Dict[str, Any]], runtimes: Sequence[float], fail_on_known: bool) -> Dict[str, Any]:
    fixture_count = len(results)
    true_positives = sum(len(result["matchedFindings"]) for result in results)
    false_positives = sum(len(result["falsePositives"]) for result in results)
    false_negatives = sum(len(result["falseNegatives"]) for result in results)
    severity_mismatches = sum(len(result["severityMismatches"]) for result in results)
    critical_false_negatives = sum(
        1
        for result in results
        for finding in result["falseNegatives"]
        if finding.get("severity") == "CRITICAL"
    )
    critical_true_positives = sum(
        1
        for result in results
        for finding in result["matchedFindings"]
        if finding.get("severity") == "CRITICAL"
    )
    unexpected_critical_findings = sum(len(result["unexpectedCriticalFindings"]) for result in results)
    deterministic_count = sum(1 for result in results if result.get("deterministic"))
    determinism_score = ratio(deterministic_count, fixture_count, empty_value=0.0)

    hard_gate_failures: List[Dict[str, Any]] = []
    for result in results:
        case_id = result["caseId"]
        known = bool(result.get("knownBaselineFailure"))
        if result["scannerErrors"]:
            hard_gate_failures.append({"caseId": case_id, "gate": "scanner_output_shape"})
        if not result.get("deterministic"):
            hard_gate_failures.append({"caseId": case_id, "gate": "determinism"})
        if result["severityMismatches"]:
            hard_gate_failures.append({"caseId": case_id, "gate": "severity_match"})
        if result["falseNegatives"]:
            if fail_on_known or not known:
                hard_gate_failures.append({"caseId": case_id, "gate": "expected_findings"})
        if result["missingSuppressedFindings"] or result["missingRejectedSuppressions"]:
            if fail_on_known or not known:
                hard_gate_failures.append({"caseId": case_id, "gate": "suppression_expectations"})
        if result["unexpectedCriticalFindings"]:
            hard_gate_failures.append({"caseId": case_id, "gate": "unexpected_critical_negative"})
        if fail_on_known and result["status"] == "known_baseline_failure":
            hard_gate_failures.append({"caseId": case_id, "gate": "known_baseline_failure"})

    precision = ratio(true_positives, true_positives + false_positives)
    recall = ratio(true_positives, true_positives + false_negatives)
    f1 = 0.0 if precision + recall == 0 else (2 * precision * recall) / (precision + recall)
    critical_recall = ratio(
        critical_true_positives,
        critical_true_positives + critical_false_negatives,
    )

    return {
        "criticalFalseNegatives": critical_false_negatives,
        "criticalRecall": rounded_metric(critical_recall),
        "determinismScore": rounded_metric(determinism_score),
        "f1": rounded_metric(f1),
        "failed": sum(1 for result in results if result["status"] != "passed"),
        "falseNegatives": false_negatives,
        "falsePositives": false_positives,
        "fixtureCount": fixture_count,
        "hardGateFailures": hard_gate_failures,
        "hardGatePassed": len(hard_gate_failures) == 0,
        "knownBaselineFailures": sum(1 for result in results if result["status"] == "known_baseline_failure"),
        "passed": sum(1 for result in results if result["status"] == "passed"),
        "precision": rounded_metric(precision),
        "recall": rounded_metric(recall),
        "runtimeMsP50": rounded_metric(percentile(runtimes, 0.50)),
        "runtimeMsP95": rounded_metric(percentile(runtimes, 0.95)),
        "severityMismatches": severity_mismatches,
        "truePositives": true_positives,
        "unexpectedCriticalFindings": unexpected_critical_findings,
    }


def collect_fixture_paths(fixtures_dir: Path) -> List[Path]:
    return sorted(
        (path for path in fixtures_dir.rglob("*.json") if path.is_file()),
        key=lambda path: path.relative_to(fixtures_dir).as_posix(),
    )


def display_fixture_path(fixture_path: Path, fixtures_dir: Path, repo_root: Path) -> Path:
    try:
        return fixture_path.relative_to(repo_root)
    except ValueError:
        try:
            return Path("fixtures") / fixture_path.relative_to(fixtures_dir)
        except ValueError:
            return Path(fixture_path.name)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run policy scanner offline eval fixtures.")
    parser.add_argument("--repo-root", default=".", help="Repository root. Defaults to current directory.")
    parser.add_argument("--fixtures-dir", help="Fixture directory. Defaults to evals/policy_scanner/fixtures.")
    parser.add_argument("--json-output", help="Optional path to write the scorecard JSON.")
    parser.add_argument("--repeat", type=int, default=2, help="Runs per fixture for determinism checks. Default: 2.")
    parser.add_argument(
        "--fail-on-known-baseline-failures",
        type=parse_bool,
        default=False,
        help="Treat documented known baseline failures as hard failures. Default: false.",
    )
    parser.add_argument("--include-timestamp", action="store_true", help="Include generatedAt timestamp in output.")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()
    fixtures_dir = resolve_path(args.fixtures_dir, repo_root, repo_root / "evals" / "policy_scanner" / "fixtures")
    repeat = max(args.repeat, 1)
    fixture_paths = collect_fixture_paths(fixtures_dir)

    results: List[Dict[str, Any]] = []
    all_runtimes: List[float] = []
    duplicate_case_ids: List[str] = []
    seen_case_ids = set()

    for fixture_path in fixture_paths:
        fixture = load_json(fixture_path)
        case_id = fixture.get("caseId", fixture_path.stem)
        if case_id in seen_case_ids:
            duplicate_case_ids.append(str(case_id))
        seen_case_ids.add(case_id)
        result = evaluate_fixture(repo_root, display_fixture_path(fixture_path, fixtures_dir, repo_root), fixture, repeat)
        results.append(result)
        all_runtimes.extend(result.get("runtimeMs", []))

    results = sorted(results, key=lambda item: (str(item.get("kind", "")), str(item.get("caseId", ""))))
    summary = summarize(results, all_runtimes, args.fail_on_known_baseline_failures)
    if not fixture_paths:
        summary["hardGateFailures"].append({"caseId": None, "gate": "no_fixtures"})
        summary["hardGatePassed"] = False
    if duplicate_case_ids:
        summary["hardGateFailures"].append({"caseId": ",".join(sorted(duplicate_case_ids)), "gate": "duplicate_case_id"})
        summary["hardGatePassed"] = False

    report: Dict[str, Any] = {
        "failOnKnownBaselineFailures": args.fail_on_known_baseline_failures,
        "repeat": repeat,
        "results": results,
        "scanner": {
            "command": "bash lib/policy-scanner.sh <temp>/combined.patch",
            "output": "<temp>/policy_scan.json",
        },
        "summary": summary,
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
    return 0 if summary["hardGatePassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
