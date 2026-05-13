#!/usr/bin/env python3
"""Validate Signum test plans for required adversarial coverage."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set


REQUIRED_COVERAGE_BY_CHANGE_TYPE: Dict[str, List[str]] = {
    "cli_tooling": [
        "boundary_value",
        "idempotency",
        "path_handling",
        "config_source_of_truth",
        "generated_output_isolation",
    ],
    "eval_harness": [
        "malformed_fixture",
        "expected_violation_logic",
        "baseline_mismatch",
        "fixture_count_change",
        "deterministic_output",
    ],
    "file_archive_writer": [
        "overwrite_behavior",
        "stale_output",
        "cleanup",
        "relative_absolute_paths",
        "generated_output_isolation",
    ],
    "prompt_orchestration": [
        "false_auto_ok",
        "missing_approval",
        "reduced_coverage",
        "artifact_root_drift",
        "hidden_holdout_leak",
    ],
    "scanner_policy": [
        "critical_false_negative",
        "false_positive_budget",
        "suppression_semantics",
        "severity_accuracy",
        "runtime_budget",
    ],
}

ALLOWED_RISK_LEVELS = {"low", "medium", "high"}
ALLOWED_VERIFY_TYPES = {"exec", "manual", "test"}


def canonical_json(data: Dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def stable_unique(items: Iterable[str]) -> List[str]:
    return sorted(set(items))


def string_list(value: Any) -> Optional[List[str]]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        return None
    return list(value)


def add(violations: Set[str], condition: bool, violation_id: str) -> None:
    if condition:
        violations.add(violation_id)


def validate_verify(value: Any, prefix: str, violations: Set[str]) -> None:
    if not isinstance(value, dict):
        violations.add(f"{prefix}.verify_shape")
        return
    add(violations, set(value) != {"type", "value"}, f"{prefix}.verify_fields")
    add(violations, value.get("type") not in ALLOWED_VERIFY_TYPES, f"{prefix}.verify_type")
    add(
        violations,
        not isinstance(value.get("value"), str) or not value.get("value"),
        f"{prefix}.verify_value",
    )


def validate_checks(value: Any, *, adversarial: bool, violations: Set[str]) -> List[str]:
    prefix = "adversarial_checks" if adversarial else "happy_path_checks"
    if not isinstance(value, list):
        violations.add(f"{prefix}.shape")
        return []

    seen_ids: Set[str] = set()
    classes: List[str] = []
    for index, item in enumerate(value):
        item_prefix = f"{prefix}.{index}"
        if not isinstance(item, dict):
            violations.add(f"{item_prefix}.shape")
            continue
        check_id = item.get("id")
        add(violations, not isinstance(check_id, str) or not check_id, f"{item_prefix}.id")
        if isinstance(check_id, str):
            add(violations, check_id in seen_ids, f"{item_prefix}.duplicate_id")
            seen_ids.add(check_id)
        add(
            violations,
            not isinstance(item.get("description"), str) or not item.get("description"),
            f"{item_prefix}.description",
        )
        validate_verify(item.get("verify"), item_prefix, violations)
        if adversarial:
            coverage_class = item.get("class")
            add(
                violations,
                not isinstance(coverage_class, str) or not coverage_class,
                f"{item_prefix}.class",
            )
            if isinstance(coverage_class, str) and coverage_class:
                classes.append(coverage_class)
    return classes


def evaluate_test_plan(plan: Dict[str, Any]) -> Dict[str, Any]:
    violations: Set[str] = set()
    warnings: Set[str] = set()

    add(violations, plan.get("schemaVersion") != "1.0", "schema.schema_version")

    change_type = plan.get("changeType")
    add(violations, change_type not in REQUIRED_COVERAGE_BY_CHANGE_TYPE, "change_type.unknown")

    risk_level = plan.get("riskLevel")
    add(violations, risk_level not in ALLOWED_RISK_LEVELS, "risk_level.invalid")

    happy_checks = plan.get("happyPathChecks")
    validate_checks(happy_checks, adversarial=False, violations=violations)
    if isinstance(happy_checks, list):
        add(violations, len(happy_checks) == 0, "happy_path_checks.empty")

    adversarial_classes = validate_checks(
        plan.get("adversarialChecks"),
        adversarial=True,
        violations=violations,
    )

    required = REQUIRED_COVERAGE_BY_CHANGE_TYPE.get(change_type, [])
    covered = stable_unique(
        coverage_class for coverage_class in adversarial_classes if coverage_class in set(required)
    )
    missing = stable_unique(coverage_class for coverage_class in required if coverage_class not in covered)

    reported_required = string_list(plan.get("requiredCoverageClasses"))
    reported_covered = string_list(plan.get("coveredCoverageClasses"))
    reported_missing = string_list(plan.get("missingCoverageClasses"))
    add(violations, reported_required is None, "coverage.required_shape")
    add(violations, reported_covered is None, "coverage.covered_shape")
    add(violations, reported_missing is None, "coverage.missing_shape")
    if reported_required is not None:
        add(
            violations,
            stable_unique(reported_required) != stable_unique(required),
            "coverage.required_classes_mismatch",
        )
    if reported_covered is not None:
        add(
            violations,
            stable_unique(reported_covered) != covered,
            "coverage.covered_classes_mismatch",
        )
    if reported_missing is not None:
        add(
            violations,
            stable_unique(reported_missing) != missing,
            "coverage.missing_classes_mismatch",
        )

    unknown_classes = stable_unique(
        coverage_class
        for coverage_class in adversarial_classes
        if coverage_class not in set(REQUIRED_COVERAGE_BY_CHANGE_TYPE.get(change_type, []))
    )
    add(violations, bool(unknown_classes), "coverage.unknown_adversarial_class")

    if missing and risk_level in {"medium", "high"}:
        violations.add("coverage.missing_required_adversarial_classes")
    elif missing:
        warnings.add("coverage.missing_required_adversarial_classes")

    hard_gate_passed = not violations
    return {
        "changeType": change_type if isinstance(change_type, str) else None,
        "coveredCoverageClasses": covered,
        "hardGatePassed": hard_gate_passed,
        "missingCoverageClasses": missing,
        "requiredCoverageClasses": stable_unique(required),
        "riskLevel": risk_level if isinstance(risk_level, str) else None,
        "status": "ok" if hard_gate_passed else "error",
        "violations": sorted(violations),
        "warnings": sorted(warnings),
    }


def load_plan(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("test plan root must be a JSON object")
    return data


def error_report(message: str) -> Dict[str, Any]:
    return {
        "changeType": None,
        "coveredCoverageClasses": [],
        "hardGatePassed": False,
        "missingCoverageClasses": [],
        "requiredCoverageClasses": [],
        "riskLevel": None,
        "status": "error",
        "violations": [message],
        "warnings": [],
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Check a Signum test plan for adversarial coverage.")
    parser.add_argument("test_plan", help="Path to test_plan.json.")
    parser.add_argument("--json-output", help="Optional path to write the deterministic JSON report.")
    args = parser.parse_args(argv)

    try:
        report = evaluate_test_plan(load_plan(Path(args.test_plan)))
    except json.JSONDecodeError:
        report = error_report("input.invalid_json")
    except OSError:
        report = error_report("input.read_error")
    except ValueError as exc:
        report = error_report(str(exc))

    blob = canonical_json(report)
    if args.json_output:
        output_path = Path(args.json_output)
        if not output_path.is_absolute():
            output_path = Path.cwd() / output_path
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(blob, encoding="utf-8")
    sys.stdout.write(blob)
    return 0 if report.get("hardGatePassed") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
