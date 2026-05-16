#!/usr/bin/env python3
"""Validate Codex local agent-review evidence for a Signum contract root.

This checker is intentionally stdlib-only and narrow. It is a deterministic
guard for the Codex prompt contract: medium/high-risk AUTO_OK runs need a ready
local Codex review artifact before they can be treated as fully audited.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "1.0"
REQUIRED_RISKS = {"medium", "high"}
READY_STATE = "ready"
APPROVING_VERDICTS = {"APPROVE", "CONDITIONAL"}


def _load_json(path: Path) -> tuple[Any | None, str | None]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle), None
    except FileNotFoundError:
        return None, "missing"
    except json.JSONDecodeError as exc:
        return None, f"invalid_json:{exc.lineno}:{exc.colno}:{exc.msg}"
    except OSError as exc:
        return None, f"read_error:{exc}"


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _stable_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def _repo_relative(path: Path, repo_root: Path | None) -> str:
    resolved = path.resolve()
    if repo_root is not None:
        try:
            return resolved.relative_to(repo_root.resolve()).as_posix()
        except ValueError:
            pass
    return path.name


def _contract_id_from_root(contract_root: Path) -> str | None:
    if contract_root.parent.name == "contracts" and contract_root.parent.parent.name == ".signum":
        return contract_root.name
    return None


def _audit_artifact_paths(audit: dict[str, Any]) -> set[str]:
    paths: set[str] = set()
    for item in _as_list(audit.get("agentReviewArtifacts")):
        if isinstance(item, str):
            paths.add(item)
        elif isinstance(item, dict):
            path = item.get("path") or item.get("relativePath")
            if isinstance(path, str):
                paths.add(path)
    return paths


def _path_mentions_codex_review(path: str, contract_id: str | None) -> bool:
    normalized = path.replace("\\", "/").strip()
    allowed = {"reviews/codex.json", "./reviews/codex.json"}
    if normalized in allowed:
        return True
    if contract_id:
        return normalized == f".signum/contracts/{contract_id}/reviews/codex.json"
    return normalized.endswith("/reviews/codex.json")


def _proofpack_has_codex_review(proofpack: dict[str, Any], contract_id: str | None) -> bool:
    checks = _as_dict(proofpack.get("checks"))
    reviews = _as_dict(checks.get("reviews"))
    codex_review = _as_dict(reviews.get("codex"))
    if codex_review.get("status") == "present":
        return True
    content = _as_dict(codex_review.get("content"))
    if content.get("provider") == "codex":
        return True

    for item in _as_list(proofpack.get("artifactRefs")):
        path = item if isinstance(item, str) else _as_dict(item).get("path")
        if isinstance(path, str) and _path_mentions_codex_review(path, contract_id):
            return True
    return False


def _determine_risk(contract: dict[str, Any], audit: dict[str, Any], proofpack: dict[str, Any]) -> str | None:
    for source in (proofpack, audit, contract):
        risk = source.get("riskLevel")
        if isinstance(risk, str) and risk:
            return risk
    return None


def _determine_decision(audit: dict[str, Any], proofpack: dict[str, Any]) -> str | None:
    for source in (audit, proofpack):
        decision = source.get("decision")
        if isinstance(decision, str) and decision:
            return decision
    return None


def evaluate(contract_root: Path, repo_root: Path | None = None) -> dict[str, Any]:
    violations: list[str] = []
    warnings: list[str] = []

    contract_id = _contract_id_from_root(contract_root)
    paths = {
        "contract": contract_root / "contract.json",
        "auditSummary": contract_root / "audit_summary.json",
        "proofpack": contract_root / "proofpack.json",
        "codexReview": contract_root / "reviews" / "codex.json",
    }

    if not contract_root.is_dir():
        violations.append("contract_root.missing")

    contract_raw, contract_error = _load_json(paths["contract"])
    audit_raw, audit_error = _load_json(paths["auditSummary"])
    proofpack_raw, proofpack_error = _load_json(paths["proofpack"])
    review_raw, review_error = _load_json(paths["codexReview"])

    contract = _as_dict(contract_raw)
    audit = _as_dict(audit_raw)
    proofpack = _as_dict(proofpack_raw)
    review = _as_dict(review_raw)

    if contract_error and contract_error != "missing":
        violations.append("contract.invalid_json")
    if audit_error:
        violations.append("audit_summary.missing" if audit_error == "missing" else "audit_summary.invalid_json")
    if proofpack_error:
        violations.append("proofpack.missing" if proofpack_error == "missing" else "proofpack.invalid_json")

    decision = _determine_decision(audit, proofpack)
    risk_level = _determine_risk(contract, audit, proofpack)
    required = decision == "AUTO_OK" and risk_level in REQUIRED_RISKS

    if not required:
        if review_error and review_error not in {"missing"}:
            warnings.append("codex_review.invalid_json")
        return {
            "schemaVersion": SCHEMA_VERSION,
            "status": "ok" if not violations else "error",
            "hardGatePassed": not violations,
            "required": False,
            "reason": "not_medium_high_auto_ok",
            "contractId": contract_id,
            "contractRoot": _repo_relative(contract_root, repo_root),
            "decision": decision,
            "riskLevel": risk_level,
            "violations": sorted(set(violations)),
            "warnings": sorted(set(warnings)),
            "checks": {
                "auditSummaryPresent": audit_error is None,
                "proofpackPresent": proofpack_error is None,
                "codexReviewPresent": review_error is None,
            },
        }

    if review_error:
        violations.append("codex_review.missing" if review_error == "missing" else "codex_review.invalid_json")

    coverage = _as_dict(audit.get("agentReviewCoverage"))
    artifact_paths = _audit_artifact_paths(audit)
    has_artifact_ref = any(_path_mentions_codex_review(path, contract_id) for path in artifact_paths)

    if coverage.get("codex") != READY_STATE:
        violations.append("agent_review.coverage_not_ready")
    if not has_artifact_ref:
        violations.append("agent_review.artifact_not_recorded")

    if review_error is None:
        if review.get("provider") != "codex":
            violations.append("codex_review.provider_mismatch")
        if review.get("reviewerType") != "local_agent":
            violations.append("codex_review.reviewer_type_missing")
        if review.get("state") != READY_STATE:
            violations.append("codex_review.state_not_ready")
        if review.get("verdict") not in APPROVING_VERDICTS:
            violations.append("codex_review.verdict_not_approving")
        if not isinstance(review.get("findings"), list):
            violations.append("codex_review.findings_shape")
        if not isinstance(review.get("summary"), str) or not review.get("summary", "").strip():
            violations.append("codex_review.summary_missing")

    if proofpack_error is None:
        if proofpack.get("decision") != decision:
            violations.append("proofpack.decision_mismatch")
        if not _proofpack_has_codex_review(proofpack, contract_id):
            violations.append("proofpack.codex_review_missing")

    unique_violations = sorted(set(violations))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "status": "ok" if not unique_violations else "error",
        "hardGatePassed": not unique_violations,
        "required": True,
        "contractId": contract_id,
        "contractRoot": _repo_relative(contract_root, repo_root),
        "decision": decision,
        "riskLevel": risk_level,
        "violations": unique_violations,
        "warnings": sorted(set(warnings)),
        "checks": {
            "agentReviewArtifactRecorded": has_artifact_ref,
            "agentReviewCoverageCodex": coverage.get("codex"),
            "auditSummaryPresent": audit_error is None,
            "codexReviewPresent": review_error is None,
            "proofpackIncludesCodexReview": proofpack_error is None and _proofpack_has_codex_review(proofpack, contract_id),
            "proofpackPresent": proofpack_error is None,
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate Codex local agent-review evidence")
    parser.add_argument("--contract-root", required=True, help="path to .signum/contracts/<contractId>")
    parser.add_argument("--repo-root", default=".", help="repository root for relative output paths")
    parser.add_argument("--json-output", help="optional path to write the canonical JSON report")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve() if args.repo_root else None
    report = evaluate(Path(args.contract_root), repo_root)
    payload = _stable_json(report)
    sys.stdout.write(payload)
    if args.json_output:
        Path(args.json_output).write_text(payload, encoding="utf-8")
    return 0 if report.get("hardGatePassed") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
