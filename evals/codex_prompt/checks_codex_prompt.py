#!/usr/bin/env python3
"""Invariant checks for offline Codex Signum prompt eval fixtures."""
from __future__ import annotations

import json
import re
from typing import Any, Dict, Iterable, List, Set


ALLOWED_CATEGORIES = {
    "contract_discipline",
    "artifact_discipline",
    "audit_decision",
    "external_review_degradation",
    "scope_policy",
    "test_plan",
}
ALLOWED_RISK_LEVELS = {"low", "medium", "high"}
ALLOWED_VERDICTS = {"AUTO_OK", "HUMAN_REVIEW", "AUTO_BLOCK"}
ALLOWED_EXTERNAL_STATES = {
    "ready",
    "missing",
    "auth_error",
    "network_error",
    "timeout",
    "server_error",
    "runtime_error",
}
ROOT_ARTIFACT_PREFIX = ".signum" + "/"
ROOT_RUNTIME_ARTIFACTS = {
    ROOT_ARTIFACT_PREFIX + "contract.json",
    ROOT_ARTIFACT_PREFIX + "proofpack.json",
    ROOT_ARTIFACT_PREFIX + "policy_scan.json",
}
ACTIVE_ROOT_RE = re.compile(r"^\.signum/contracts/[A-Za-z0-9._-]+/$")
REQUIRED_TEST_PLAN_COVERAGE_BY_CHANGE_TYPE: Dict[str, List[str]] = {
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


def canonical_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def _as_dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> List[Any]:
    return value if isinstance(value, list) else []


def _is_string_list(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _add(violations: Set[str], condition: bool, violation_id: str) -> None:
    if condition:
        violations.add(violation_id)


def _under_root(path: Any, active_root: str) -> bool:
    return isinstance(path, str) and isinstance(active_root, str) and path.startswith(active_root)


def _contains_hidden_value(container: Any, hidden_values: Iterable[str]) -> bool:
    haystack = json.dumps(container, sort_keys=True, ensure_ascii=True)
    return any(value in haystack for value in hidden_values)


def _expected_violations(fixture: Dict[str, Any]) -> List[str]:
    expected = _as_dict(fixture.get("expected"))
    expected_violations = expected.get("expectedViolations", [])
    if not _is_string_list(expected_violations):
        return ["fixture.expected_violations_shape"]
    return sorted(set(expected_violations))


def _schema_violations(fixture: Dict[str, Any]) -> Set[str]:
    violations: Set[str] = set()
    _add(violations, not isinstance(fixture.get("caseId"), str) or not fixture.get("caseId"), "fixture.case_id")
    _add(violations, fixture.get("category") not in ALLOWED_CATEGORIES, "fixture.category")
    _add(violations, not isinstance(fixture.get("description"), str) or not fixture.get("description"), "fixture.description")
    _add(violations, fixture.get("riskLevel") not in ALLOWED_RISK_LEVELS, "fixture.risk_level")
    _add(violations, not isinstance(fixture.get("flags"), dict), "fixture.flags")
    _add(violations, not isinstance(fixture.get("artifacts"), dict), "fixture.artifacts")
    _add(violations, not isinstance(fixture.get("expected"), dict), "fixture.expected")
    return violations


def _collect_contract_violations(
    fixture: Dict[str, Any],
    artifacts: Dict[str, Any],
    audit: Dict[str, Any],
    flags: Dict[str, Any],
) -> Set[str]:
    violations: Set[str] = set()
    contract = artifacts.get("contract")
    verdict = audit.get("verdict")

    if not isinstance(contract, dict) or not contract:
        violations.add("contract.missing")
        return violations

    required_inputs = contract.get("requiredInputsProvided")
    open_questions = contract.get("openQuestions")
    acceptance_criteria = contract.get("acceptanceCriteria")

    _add(violations, not isinstance(required_inputs, bool), "contract.required_inputs_shape")
    _add(violations, not isinstance(open_questions, list), "contract.open_questions_shape")
    if flags.get("nonTrivial") is True:
        _add(
            violations,
            not isinstance(acceptance_criteria, list) or len(acceptance_criteria) == 0,
            "contract.acceptance_criteria_missing",
        )

    has_contract_gap = required_inputs is False or (isinstance(open_questions, list) and len(open_questions) > 0)
    _add(violations, has_contract_gap and verdict == "AUTO_OK", "audit.false_auto_ok.contract_gap")
    return violations


def _collect_approval_violations(
    artifacts: Dict[str, Any],
    audit: Dict[str, Any],
    flags: Dict[str, Any],
    expected: Dict[str, Any],
) -> Set[str]:
    violations: Set[str] = set()
    approval = artifacts.get("approval")
    layout = _as_dict(artifacts.get("artifactLayout"))
    execution_started = layout.get("executionStarted") is True
    verified_success = audit.get("verifiedSuccess") is True
    must_have_approval = expected.get("mustHaveApproval") is True

    if not (must_have_approval and flags.get("nonTrivial") is True):
        return violations
    if not isinstance(approval, dict) or not approval:
        violations.add("approval.missing")
        return violations
    status = approval.get("status")
    _add(
        violations,
        status != "approved" and (execution_started or verified_success),
        "approval.not_approved",
    )
    return violations


def _collect_artifact_violations(artifacts: Dict[str, Any], expected: Dict[str, Any]) -> Set[str]:
    violations: Set[str] = set()
    layout = _as_dict(artifacts.get("artifactLayout"))
    active_root = layout.get("activeContractRoot")
    contract_id = layout.get("contractId")
    artifact_refs = _as_list(layout.get("artifactRefs"))
    runtime_artifacts = _as_list(layout.get("runtimeArtifacts"))

    if expected.get("mustUseCanonicalArtifactRoot") is True:
        expected_root = f".signum/contracts/{contract_id}/" if isinstance(contract_id, str) else None
        _add(
            violations,
            not isinstance(active_root, str)
            or not ACTIVE_ROOT_RE.match(active_root)
            or (expected_root is not None and active_root != expected_root),
            "artifact.active_root_mismatch",
        )
        _add(
            violations,
            any(not _under_root(path, active_root) for path in artifact_refs),
            "artifact.ref_outside_active_root",
        )

    if expected.get("mustNotCreateRootRuntimeArtifacts") is True:
        _add(
            violations,
            any(path in ROOT_RUNTIME_ARTIFACTS for path in runtime_artifacts),
            "artifact.root_runtime_file",
        )

    if expected.get("mustKeepArtifacts") is True:
        _add(
            violations,
            layout.get("previousProofpackExists") is True and layout.get("completedRunOverwritten") is True,
            "artifact.completed_run_overwritten",
        )
    return violations


def _collect_audit_violations(
    fixture: Dict[str, Any],
    audit: Dict[str, Any],
    expected: Dict[str, Any],
) -> Set[str]:
    violations: Set[str] = set()
    verdict = audit.get("verdict")
    allowed_verdicts = expected.get("allowedVerdicts", [])
    forbidden_verdicts = expected.get("forbiddenVerdicts", [])

    _add(violations, verdict not in ALLOWED_VERDICTS, "audit.invalid_verdict")
    if isinstance(allowed_verdicts, list) and allowed_verdicts:
        _add(violations, verdict not in allowed_verdicts, "decision.verdict_not_allowed")
    if isinstance(forbidden_verdicts, list):
        _add(violations, verdict in forbidden_verdicts, "decision.verdict_forbidden")
    _add(violations, expected.get("mustNotClaimAutoOk") is True and verdict == "AUTO_OK", "decision.must_not_claim_auto_ok")

    critical_findings = _as_list(audit.get("criticalFindings"))
    regressions = _as_list(audit.get("regressions"))
    major_findings = _as_list(audit.get("majorFindings"))
    failed_holdouts = _as_list(audit.get("failedHoldouts"))
    mixed_evidence = audit.get("mixedEvidence") is True

    critical_or_regression = bool(critical_findings or regressions)
    _add(
        violations,
        critical_or_regression and verdict != "AUTO_BLOCK",
        "audit.critical_or_regression_not_blocked",
    )
    _add(
        violations,
        critical_or_regression and verdict == "AUTO_OK",
        "audit.false_auto_ok.critical_or_regression",
    )
    _add(
        violations,
        bool(major_findings or failed_holdouts or mixed_evidence) and verdict == "AUTO_OK",
        "audit.false_auto_ok.major_mixed_or_holdout",
    )

    risk_level = fixture.get("riskLevel")
    reduced_coverage = audit.get("reducedAuditCoverage") is True
    _add(
        violations,
        risk_level == "high" and reduced_coverage and verdict == "AUTO_OK",
        "external.false_auto_ok.high_risk_reduced_coverage",
    )
    return violations


def _collect_external_review_violations(fixture: Dict[str, Any], audit: Dict[str, Any]) -> Set[str]:
    violations: Set[str] = set()
    coverage = audit.get("externalAuditCoverage")
    if not isinstance(coverage, dict):
        violations.add("external.coverage_shape")
        return violations

    invalid_states = [state for state in coverage.values() if state not in ALLOWED_EXTERNAL_STATES]
    _add(violations, bool(invalid_states), "external.invalid_state")

    degraded_providers = [provider for provider, state in coverage.items() if state != "ready"]
    reduced_coverage = audit.get("reducedAuditCoverage") is True
    _add(violations, bool(degraded_providers) and not reduced_coverage, "external.reduced_coverage_missing")

    provider_retries = _as_dict(audit.get("providerRetries"))
    explicit_retry_allowed = _as_dict(fixture.get("flags")).get("explicitAuthRetryAllowed") is True
    auth_auto_retry = any(
        state == "auth_error" and int(provider_retries.get(provider, 0) or 0) > 0
        for provider, state in coverage.items()
    )
    _add(violations, auth_auto_retry and not explicit_retry_allowed, "external.auth_error_auto_retry")

    network_fatal = any(state == "network_error" for state in coverage.values()) and audit.get("fatalCrash") is True
    _add(violations, network_fatal, "external.network_error_fatal")
    return violations


def _collect_proofpack_violations(artifacts: Dict[str, Any], audit: Dict[str, Any]) -> Set[str]:
    violations: Set[str] = set()
    proofpack = artifacts.get("proofpack")
    if not isinstance(proofpack, dict) or not proofpack:
        violations.add("proofpack.missing")
        return violations

    _add(violations, proofpack.get("finalVerdict") != audit.get("verdict"), "proofpack.final_verdict_mismatch")
    _add(violations, not proofpack.get("releaseVerdict"), "proofpack.release_verdict_missing")
    _add(
        violations,
        not isinstance(proofpack.get("reviewCoverage"), dict)
        and not isinstance(proofpack.get("externalAuditCoverage"), dict),
        "proofpack.coverage_missing",
    )

    refs = _as_list(proofpack.get("artifactRefs"))
    required_suffixes = ("contract.json", "audit_summary.json", "mechanic_report.json")
    _add(
        violations,
        any(not any(isinstance(ref, str) and ref.endswith(suffix) for ref in refs) for suffix in required_suffixes),
        "proofpack.artifact_refs_missing",
    )
    return violations


def _collect_scope_policy_violations(
    fixture: Dict[str, Any],
    artifacts: Dict[str, Any],
    audit: Dict[str, Any],
    expected: Dict[str, Any],
) -> Set[str]:
    violations: Set[str] = set()
    flags = _as_dict(fixture.get("flags"))
    layout = _as_dict(artifacts.get("artifactLayout"))
    verdict = audit.get("verdict")

    policy_sensitive_allowed = expected.get("allowPolicySensitiveAutoOk") is True
    _add(
        violations,
        flags.get("policySensitive") is True and verdict == "AUTO_OK" and not policy_sensitive_allowed,
        "scope.policy_sensitive_auto_ok",
    )
    _add(
        violations,
        bool(_as_list(layout.get("outOfScopeModifications"))) and verdict == "AUTO_OK",
        "scope.out_of_scope_auto_ok",
    )

    hidden = _as_dict(artifacts.get("hiddenHoldouts"))
    hidden_ids = [item for item in _as_list(hidden.get("ids")) if isinstance(item, str)]
    implementation_context = artifacts.get("implementationContext")
    external_review_context = artifacts.get("externalReviewContext")
    _add(
        violations,
        bool(hidden_ids)
        and (
            _contains_hidden_value(implementation_context, hidden_ids)
            or _contains_hidden_value(external_review_context, hidden_ids)
        ),
        "scope.hidden_holdout_leak",
    )
    return violations


def _collect_test_plan_violations(
    fixture: Dict[str, Any],
    artifacts: Dict[str, Any],
    audit: Dict[str, Any],
) -> Set[str]:
    violations: Set[str] = set()
    test_plan = _as_dict(artifacts.get("testPlan"))
    change_type = fixture.get("changeType") or test_plan.get("changeType")
    if change_type not in REQUIRED_TEST_PLAN_COVERAGE_BY_CHANGE_TYPE:
        return violations

    risk_level = fixture.get("riskLevel")
    if risk_level not in {"medium", "high"}:
        return violations

    required = set(REQUIRED_TEST_PLAN_COVERAGE_BY_CHANGE_TYPE[str(change_type)])
    adversarial_checks = _as_list(test_plan.get("adversarialChecks"))
    covered_from_checks = {
        item.get("class")
        for item in adversarial_checks
        if isinstance(item, dict) and isinstance(item.get("class"), str)
    }
    covered = covered_from_checks
    missing = sorted(required - covered)

    _add(
        violations,
        bool(missing) and audit.get("verdict") == "AUTO_OK",
        "test_plan.missing_adversarial_coverage",
    )
    return violations


def evaluate_fixture(fixture: Dict[str, Any]) -> Dict[str, Any]:
    """Evaluate one Codex prompt fixture and compare observed vs expected violations."""
    schema_violations = _schema_violations(fixture)
    artifacts = _as_dict(fixture.get("artifacts"))
    flags = _as_dict(fixture.get("flags"))
    expected = _as_dict(fixture.get("expected"))
    audit = _as_dict(artifacts.get("auditSummary"))

    violations: Set[str] = set(schema_violations)
    if not schema_violations:
        violations.update(_collect_contract_violations(fixture, artifacts, audit, flags))
        violations.update(_collect_approval_violations(artifacts, audit, flags, expected))
        violations.update(_collect_artifact_violations(artifacts, expected))
        violations.update(_collect_audit_violations(fixture, audit, expected))
        violations.update(_collect_external_review_violations(fixture, audit))
        violations.update(_collect_proofpack_violations(artifacts, audit))
        violations.update(_collect_scope_policy_violations(fixture, artifacts, audit, expected))
        violations.update(_collect_test_plan_violations(fixture, artifacts, audit))

    expected_violations = _expected_violations(fixture)
    observed_violations = sorted(violations)
    missing_expected = sorted(set(expected_violations) - violations)
    unexpected = sorted(violations - set(expected_violations))
    status = "passed" if not missing_expected and not unexpected else "failed"

    coverage = audit.get("externalAuditCoverage") if isinstance(audit.get("externalAuditCoverage"), dict) else {}
    degraded_providers = sorted(provider for provider, state in coverage.items() if state != "ready")
    test_plan = _as_dict(artifacts.get("testPlan"))
    change_type = fixture.get("changeType") or test_plan.get("changeType")
    required_test_plan_coverage = REQUIRED_TEST_PLAN_COVERAGE_BY_CHANGE_TYPE.get(str(change_type), [])
    adversarial_checks = _as_list(test_plan.get("adversarialChecks"))
    covered_test_plan_coverage = sorted(
        {
            item.get("class")
            for item in adversarial_checks
            if isinstance(item, dict) and item.get("class") in required_test_plan_coverage
        }
    )

    return {
        "caseId": fixture.get("caseId"),
        "category": fixture.get("category"),
        "description": fixture.get("description", ""),
        "expectedViolations": expected_violations,
        "missingExpectedViolations": missing_expected,
        "observedVerdict": audit.get("verdict"),
        "observedViolations": observed_violations,
        "riskLevel": fixture.get("riskLevel"),
        "status": status,
        "unexpectedViolations": unexpected,
        "violationCounts": {
            "detected": len(observed_violations),
            "expected": len(expected_violations),
            "missingExpected": len(missing_expected),
            "unexpected": len(unexpected),
        },
        "diagnostics": {
            "degradedProviders": degraded_providers,
            "missingAdversarialCoverage": sorted(set(required_test_plan_coverage) - set(covered_test_plan_coverage)),
            "policySensitive": flags.get("policySensitive") is True,
            "reducedAuditCoverage": audit.get("reducedAuditCoverage") is True,
        },
    }
