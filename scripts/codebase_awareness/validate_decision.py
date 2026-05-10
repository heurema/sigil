#!/usr/bin/env python3
"""Validate Signum Codebase Awareness reuse decisions."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

EXIT_VALID = 0
EXIT_MISSING_DECISION = 2
EXIT_INVALID_JSON = 3
EXIT_SCHEMA = 4
EXIT_INPUT = 5

ACCEPTED_DISPOSITIONS = {
    "reuse",
    "adapt",
    "reject",
    "follow-pattern",
    "respect-boundary",
    "inspect-only",
    "defer",
}
ACTION_REQUIRED_DISPOSITIONS = {
    "reuse",
    "adapt",
    "follow-pattern",
    "respect-boundary",
}
CANDIDATE_ID_REQUIRED_DISPOSITIONS = ACTION_REQUIRED_DISPOSITIONS
COVERAGE_TOP_CANDIDATES = 3
COVERAGE_THRESHOLD = 0.75
COVERAGE_SKIP_KINDS = {"test-pattern", "config-pattern"}
MODES = {"off", "hint", "warn", "gate"}


class ValidationResult:
    def __init__(self, exit_code: int, messages: list[str]) -> None:
        self.exit_code = exit_code
        self.messages = messages

    @property
    def ok(self) -> bool:
        return self.exit_code == EXIT_VALID


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate Signum reuse_decision.json.")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--reuse-candidates", required=True)
    parser.add_argument("--reuse-decision", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--output", default=None)
    return parser.parse_args(argv)


def load_required_json(path: Path, label: str) -> tuple[Any | None, str | None]:
    if not path.is_file():
        return None, f"Required {label} JSON not found: {path}"
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except json.JSONDecodeError as exc:
        return None, f"Invalid {label} JSON in {path}: {exc}"
    except OSError as exc:
        return None, f"Unable to read {label} JSON {path}: {exc}"


def load_decision(path: Path) -> tuple[Any | None, ValidationResult | None]:
    if not path.is_file():
        return None, ValidationResult(EXIT_MISSING_DECISION, [f"reuse_decision.json not found: {path}"])
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except json.JSONDecodeError as exc:
        return None, ValidationResult(EXIT_INVALID_JSON, [f"Invalid reuse_decision.json JSON in {path}: {exc}"])
    except OSError as exc:
        return None, ValidationResult(EXIT_INPUT, [f"Unable to read reuse_decision.json {path}: {exc}"])


def non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def contract_id_from(contract: Any) -> str:
    if isinstance(contract, dict):
        for key in ("contractId", "id", "runId"):
            value = contract.get(key)
            if non_empty_string(value):
                return str(value)
    return ""


def candidate_ids_from(reuse_candidates: Any) -> tuple[set[str], int, list[str]]:
    errors: list[str] = []
    if not isinstance(reuse_candidates, dict):
        return set(), 0, ["reuse_candidates.json must be a top-level object"]

    raw_candidates = reuse_candidates.get("candidates", [])
    if not isinstance(raw_candidates, list):
        return set(), 0, ["reuse_candidates.json candidates must be an array"]

    ids: set[str] = set()
    for index, candidate in enumerate(raw_candidates, start=1):
        if not isinstance(candidate, dict):
            errors.append(f"reuse_candidates.json candidate {index} must be an object")
            continue
        candidate_id = candidate.get("candidateId")
        if non_empty_string(candidate_id):
            ids.add(str(candidate_id))

    raw_count = reuse_candidates.get("candidateCount", len(raw_candidates))
    if isinstance(raw_count, int) and raw_count >= 0:
        candidate_count = raw_count
    else:
        errors.append("reuse_candidates.json candidateCount must be a non-negative integer")
        candidate_count = len(raw_candidates)

    return ids, candidate_count, errors


def numeric_candidate_value(candidate: dict[str, Any], key: str) -> float | None:
    value = candidate.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def required_candidate_ids_from(reuse_candidates: Any) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    if not isinstance(reuse_candidates, dict):
        return [], errors

    raw_candidates = reuse_candidates.get("candidates", [])
    if not isinstance(raw_candidates, list):
        return [], errors

    required_ids: list[str] = []
    seen: set[str] = set()
    for index, candidate in enumerate(raw_candidates, start=1):
        if not isinstance(candidate, dict):
            continue

        is_top_candidate = index <= COVERAGE_TOP_CANDIDATES
        kind = str(candidate.get("kind") or "")
        score = numeric_candidate_value(candidate, "score")
        confidence = numeric_candidate_value(candidate, "confidence")
        is_strong_candidate = (
            (score is not None and score >= COVERAGE_THRESHOLD)
            or (confidence is not None and confidence >= COVERAGE_THRESHOLD)
        )
        if not is_top_candidate and kind in COVERAGE_SKIP_KINDS:
            is_strong_candidate = False
        if not is_top_candidate and not is_strong_candidate:
            continue

        candidate_id = candidate.get("candidateId")
        if not non_empty_string(candidate_id):
            errors.append(f"required reuse candidate at index {index} must have candidateId")
            continue
        candidate_id = str(candidate_id)
        if candidate_id in seen:
            continue
        seen.add(candidate_id)
        required_ids.append(candidate_id)

    return required_ids, errors


def validate_decision(
    *,
    contract: Any,
    reuse_candidates: Any,
    decision: Any,
    mode: str,
) -> ValidationResult:
    errors: list[str] = []

    if mode not in MODES:
        errors.append(f"mode must be one of {', '.join(sorted(MODES))}")

    if not isinstance(decision, dict):
        return ValidationResult(EXIT_SCHEMA, ["reuse_decision.json must be a top-level object"])

    if not non_empty_string(decision.get("schemaVersion")):
        errors.append("schemaVersion must be a non-empty string")
    elif decision.get("schemaVersion") != "1.0":
        errors.append("schemaVersion must be 1.0")

    decision_contract_id = decision.get("contractId")
    if not non_empty_string(decision_contract_id):
        errors.append("contractId must be a non-empty string")
    else:
        reuse_contract_id = reuse_candidates.get("contractId") if isinstance(reuse_candidates, dict) else None
        contract_id = contract_id_from(contract)
        if non_empty_string(reuse_contract_id) and str(reuse_contract_id) != "unknown":
            if str(decision_contract_id) != str(reuse_contract_id):
                errors.append("contractId must match reuse_candidates.json contractId")
        if non_empty_string(contract_id) and contract_id != "unknown":
            if str(decision_contract_id) != contract_id:
                errors.append("contractId must match contract.json contractId")

    summary = decision.get("summary")
    if not non_empty_string(summary):
        errors.append("summary must be a non-empty string")

    decisions = decision.get("decisions")
    if not isinstance(decisions, list):
        errors.append("decisions must be an array")
        decisions = []

    candidate_ids, candidate_count, candidate_errors = candidate_ids_from(reuse_candidates)
    errors.extend(candidate_errors)

    if candidate_count > 0 and not decisions:
        errors.append("decisions must contain at least one entry when reuse candidates are available")
    addressed_candidate_ids: set[str] = set()
    for index, item in enumerate(decisions, start=1):
        prefix = f"decisions[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue

        disposition = item.get("disposition")
        if disposition not in ACCEPTED_DISPOSITIONS:
            errors.append(f"{prefix}.disposition must be one of {', '.join(sorted(ACCEPTED_DISPOSITIONS))}")

        if not non_empty_string(item.get("rationale")):
            errors.append(f"{prefix}.rationale must be a non-empty string")

        candidate_id = item.get("candidateId")
        if candidate_id is not None:
            if not non_empty_string(candidate_id):
                errors.append(f"{prefix}.candidateId must be a non-empty string when present")
            elif str(candidate_id) not in candidate_ids:
                errors.append(f"{prefix}.candidateId {candidate_id!r} is not present in reuse_candidates.json")
            else:
                addressed_candidate_ids.add(str(candidate_id))
        elif disposition in CANDIDATE_ID_REQUIRED_DISPOSITIONS:
            errors.append(f"{prefix}.candidateId must be present for disposition {disposition}")

        if disposition in ACTION_REQUIRED_DISPOSITIONS and not non_empty_string(item.get("action")):
            errors.append(f"{prefix}.action must be a non-empty string for disposition {disposition}")

    if candidate_count > 0:
        required_candidate_ids, required_candidate_errors = required_candidate_ids_from(reuse_candidates)
        errors.extend(required_candidate_errors)
        for candidate_id in required_candidate_ids:
            if candidate_id not in addressed_candidate_ids:
                errors.append(f"required reuse candidate {candidate_id!r} is not addressed by reuse_decision.json")

    if errors:
        return ValidationResult(EXIT_SCHEMA, errors)
    return ValidationResult(EXIT_VALID, ["reuse_decision.json is valid"])


def write_report(path: Path, result: ValidationResult) -> None:
    status = "valid" if result.ok else "invalid"
    report = {
        "schemaVersion": "1.0",
        "status": status,
        "exitCode": result.exit_code,
        "messages": result.messages,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def emit_result(result: ValidationResult) -> None:
    stream = sys.stdout if result.ok else sys.stderr
    for message in result.messages:
        print(message, file=stream)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    contract_path = Path(args.contract)
    reuse_candidates_path = Path(args.reuse_candidates)
    reuse_decision_path = Path(args.reuse_decision)

    contract, contract_error = load_required_json(contract_path, "contract")
    reuse_candidates, reuse_error = load_required_json(reuse_candidates_path, "reuse-candidates")
    input_errors = [error for error in (contract_error, reuse_error) if error]
    if input_errors:
        result = ValidationResult(EXIT_INPUT, input_errors)
    else:
        decision, decision_error = load_decision(reuse_decision_path)
        if decision_error is not None:
            result = decision_error
        else:
            result = validate_decision(
                contract=contract,
                reuse_candidates=reuse_candidates,
                decision=decision,
                mode=args.mode,
            )

    if args.output:
        try:
            write_report(Path(args.output), result)
        except OSError as exc:
            result = ValidationResult(EXIT_INPUT, [f"Unable to write validation report {args.output}: {exc}"])

    emit_result(result)
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
