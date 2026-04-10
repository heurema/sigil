#!/usr/bin/env python3
"""Deterministic checks for Signum eval harness fixtures."""
from __future__ import annotations

import json
from typing import Any, Dict, List

ALLOWED_RISK_LEVELS = {"low", "medium", "high"}
ALLOWED_VERDICTS = {"AUTO_OK", "HUMAN_REVIEW", "AUTO_BLOCK"}
ALLOWED_COVERAGE_STATES = {
    "ready",
    "missing",
    "auth_error",
    "network_error",
    "timeout",
    "server_error",
    "runtime_error",
}


def canonical_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _check(ok: bool, check_id: str, detail: str) -> Dict[str, str]:
    return {
        "id": check_id,
        "status": "pass" if ok else "fail",
        "detail": detail,
    }


def _is_string_list(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def evaluate_fixture(fixture: Dict[str, Any]) -> Dict[str, Any]:
    checks: List[Dict[str, str]] = []

    case_id = fixture.get("caseId")
    risk_level = fixture.get("riskLevel")
    flags = fixture.get("flags") if isinstance(fixture.get("flags"), dict) else {}
    artifacts = fixture.get("artifacts") if isinstance(fixture.get("artifacts"), dict) else {}
    contract = artifacts.get("contract") if isinstance(artifacts.get("contract"), dict) else None
    audit = artifacts.get("auditSummary") if isinstance(artifacts.get("auditSummary"), dict) else None
    proofpack = artifacts.get("proofpack") if isinstance(artifacts.get("proofpack"), dict) else None

    checks.append(_check(isinstance(case_id, str) and bool(case_id), "fixture.case_id", "fixture must declare a non-empty caseId"))
    checks.append(_check(risk_level in ALLOWED_RISK_LEVELS, "fixture.risk_level", "riskLevel must be one of low|medium|high"))
    checks.append(_check(contract is not None, "contract.present", "contract artifact must be present"))
    checks.append(_check(audit is not None, "audit.present", "audit summary artifact must be present"))
    checks.append(_check(proofpack is not None, "proofpack.present", "proofpack artifact must be present"))

    contract_ready = False
    contract_open_questions = False
    if contract is not None:
        checks.append(_check(isinstance(contract.get("requiredInputsProvided"), bool), "contract.required_inputs_shape", "requiredInputsProvided must be boolean"))
        checks.append(_check(_is_string_list(contract.get("openQuestions")), "contract.open_questions_shape", "openQuestions must be a list of strings"))
        checks.append(_check(isinstance(contract.get("acceptanceCriteria"), list) and len(contract.get("acceptanceCriteria")) > 0, "contract.acceptance_criteria_shape", "acceptanceCriteria must be a non-empty list"))
        contract_ready = contract.get("requiredInputsProvided") is True
        contract_open_questions = isinstance(contract.get("openQuestions"), list) and len(contract.get("openQuestions")) > 0

    verdict = None
    regressions: List[Any] = []
    critical_findings: List[Any] = []
    coverage: Dict[str, str] = {}
    reduced_coverage = False
    if audit is not None:
        verdict = audit.get("verdict")
        checks.append(_check(verdict in ALLOWED_VERDICTS, "audit.verdict_shape", "verdict must be AUTO_OK | HUMAN_REVIEW | AUTO_BLOCK"))
        checks.append(_check(isinstance(audit.get("confidence"), int), "audit.confidence_shape", "confidence must be an integer"))
        checks.append(_check(isinstance(audit.get("reducedAuditCoverage"), bool), "audit.reduced_coverage_shape", "reducedAuditCoverage must be boolean"))
        checks.append(_check(isinstance(audit.get("regressions"), list), "audit.regressions_shape", "regressions must be a list"))
        checks.append(_check(isinstance(audit.get("criticalFindings"), list), "audit.critical_findings_shape", "criticalFindings must be a list"))
        checks.append(_check(_is_string_list(audit.get("notes")), "audit.notes_shape", "notes must be a list of strings"))
        checks.append(_check(isinstance(audit.get("externalAuditCoverage"), dict) and bool(audit.get("externalAuditCoverage")), "audit.coverage_shape", "externalAuditCoverage must be a non-empty object"))
        regressions = audit.get("regressions") if isinstance(audit.get("regressions"), list) else []
        critical_findings = audit.get("criticalFindings") if isinstance(audit.get("criticalFindings"), list) else []
        coverage = audit.get("externalAuditCoverage") if isinstance(audit.get("externalAuditCoverage"), dict) else {}
        invalid_states = {provider: state for provider, state in coverage.items() if state not in ALLOWED_COVERAGE_STATES}
        checks.append(_check(not invalid_states, "audit.coverage_states", "all provider coverage states must be recognized"))
        reduced_coverage = audit.get("reducedAuditCoverage") is True
        degraded = sorted(provider for provider, state in coverage.items() if state != "ready")
        checks.append(_check((not degraded) or reduced_coverage, "audit.reduced_coverage_flag", "reducedAuditCoverage must be true when any provider is degraded"))
        if contract_ready and not contract_open_questions and not regressions and not critical_findings and not (reduced_coverage and risk_level in {"medium", "high"}) and not flags.get("policySensitive"):
            checks.append(_check(verdict == "AUTO_OK", "audit.clean_case_verdict", "clean low-friction cases should land on AUTO_OK"))
        if regressions or critical_findings:
            checks.append(_check(verdict == "AUTO_BLOCK", "audit.block_on_regression", "regressions or critical findings must block"))
        if reduced_coverage and risk_level in {"medium", "high"}:
            checks.append(_check(verdict != "AUTO_OK", "audit.medium_high_reduced_coverage", "medium/high risk cases with reduced coverage must not claim AUTO_OK"))
        if (not contract_ready) or contract_open_questions:
            checks.append(_check(verdict != "AUTO_OK", "audit.contract_gap_verdict", "contract gaps must not claim AUTO_OK"))
        if flags.get("policySensitive"):
            checks.append(_check(verdict != "AUTO_OK", "audit.policy_sensitive_verdict", "policy-sensitive cases should remain gated for human review or block"))

    if proofpack is not None:
        required_sections = {
            "runMetadata": dict,
            "contractSummary": dict,
            "baselineSummary": dict,
            "implementationSummary": dict,
            "auditSummary": dict,
            "reviewSummaries": dict,
            "externalAuditCoverage": dict,
            "finalVerdict": str,
        }
        missing_sections = sorted(name for name, expected_type in required_sections.items() if not isinstance(proofpack.get(name), expected_type))
        checks.append(_check(not missing_sections, "proofpack.required_sections", "proofpack must expose all required summary sections"))
        if verdict is not None:
            checks.append(_check(proofpack.get("finalVerdict") == verdict, "proofpack.final_verdict_match", "proofpack finalVerdict must match audit verdict"))
        if coverage:
            checks.append(_check(proofpack.get("externalAuditCoverage") == coverage, "proofpack.coverage_match", "proofpack coverage must mirror audit coverage"))

    failed_checks = [check for check in checks if check["status"] == "fail"]
    degraded_providers = sorted(provider for provider, state in coverage.items() if state != "ready")

    return {
        "caseId": case_id,
        "description": fixture.get("description", ""),
        "riskLevel": risk_level,
        "policySensitive": bool(flags.get("policySensitive")),
        "observedVerdict": verdict,
        "contractReady": contract_ready and not contract_open_questions,
        "reducedAuditCoverage": reduced_coverage,
        "degradedProviders": degraded_providers,
        "failedChecks": [check["id"] for check in failed_checks],
        "failedCheckDetails": failed_checks,
        "checkCounts": {
            "total": len(checks),
            "passed": len(checks) - len(failed_checks),
            "failed": len(failed_checks),
        },
        "invariantStatus": "ok" if not failed_checks else "violated",
    }
