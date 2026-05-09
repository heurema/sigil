#!/usr/bin/env python3
"""Build compact PACK-stage Codebase Awareness reuse summary evidence."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

EXIT_OK = 0
EXIT_MISSING_INPUT = 2
EXIT_INVALID_JSON = 3
EXIT_INVALID_SHAPE = 4
EXIT_INFRA = 5

SCHEMA_VERSION = "1.0"
MODES = {"off", "hint", "warn", "gate"}
STATUS_DISABLED = "disabled"
STATUS_COMPLETE = "complete"
STATUS_DEGRADED = "degraded"
STATUS_MISSING = "missing"
GATE_REQUIRED_INPUTS = {"reuseCandidates", "reuseDecision", "duplicateScan", "auditSummary"}
EVIDENCE_INPUTS = ("implementationContext", "reuseCandidates", "reuseDecision", "duplicateScan")
MAX_REASON_CHARS = 160


class SummaryError(Exception):
    def __init__(self, exit_code: int, message: str) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.message = message


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build Signum Codebase Awareness reuse_summary.json.")
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--contract", required=True)
    parser.add_argument("--implementation-context", required=True)
    parser.add_argument("--reuse-candidates", required=True)
    parser.add_argument("--reuse-decision", required=True)
    parser.add_argument("--duplicate-scan", required=True)
    parser.add_argument("--audit-summary", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--generated-at", default=None)
    return parser.parse_args(argv)


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def resolve(project_root: Path, value: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return project_root / path


def portable_input_path(value: str) -> str:
    return Path(value).name


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SummaryError(EXIT_MISSING_INPUT, f"Required {label} file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SummaryError(EXIT_INVALID_JSON, f"Invalid {label} JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise SummaryError(EXIT_INFRA, f"Unable to read {label} JSON {path}: {exc}") from exc


def load_optional_json(path: Path, label: str) -> tuple[bool, Any | None]:
    if not path.is_file():
        return False, None
    return True, load_json(path, label)


def non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def compact_text(value: Any, max_chars: int = MAX_REASON_CHARS) -> str | None:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    if not text:
        return None
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3].rstrip() + "..."


def contract_id_from(contract: Any, candidates: Any, decision: Any, audit_summary: Any, output_path: Path) -> str:
    for data in (contract, candidates, decision, audit_summary):
        if not isinstance(data, dict):
            continue
        for key in ("contractId", "id", "runId"):
            value = data.get(key)
            if non_empty_string(value):
                return str(value)
    if output_path.parent.name:
        return output_path.parent.name
    return "unknown"


def candidate_summary(reuse_candidates: Any) -> dict[str, Any]:
    if not isinstance(reuse_candidates, dict):
        raise SummaryError(EXIT_INVALID_SHAPE, "reuse_candidates.json must be a top-level object")
    candidates = reuse_candidates.get("candidates", [])
    if not isinstance(candidates, list):
        raise SummaryError(EXIT_INVALID_SHAPE, "reuse_candidates.json candidates must be an array")

    by_kind: Counter[str] = Counter()
    top_candidates: list[dict[str, Any]] = []
    normalized_candidates: list[dict[str, Any]] = []
    for item in candidates:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("kind") or "unknown")
        by_kind[kind] += 1
        normalized_candidates.append(item)

    def sort_key(item: dict[str, Any]) -> tuple[float, str]:
        score = item.get("score")
        numeric_score = float(score) if isinstance(score, (int, float)) else 0.0
        return (-numeric_score, str(item.get("candidateId") or ""))

    for item in sorted(normalized_candidates, key=sort_key)[:3]:
        reasons = item.get("whyRelevant")
        if not isinstance(reasons, list):
            reasons = item.get("reasons")
        if not isinstance(reasons, list):
            reasons = []
        score = item.get("score")
        top_candidates.append(
            {
                "candidateId": item.get("candidateId"),
                "kind": item.get("kind"),
                "path": item.get("path"),
                "symbol": item.get("symbol"),
                "score": round(float(score), 4) if isinstance(score, (int, float)) else None,
                "whyRelevantCount": len(reasons),
                "firstReason": next(
                    (
                        compacted
                        for reason in reasons
                        for compacted in [compact_text(reason)]
                        if compacted is not None
                    ),
                    None,
                ),
            }
        )

    raw_count = reuse_candidates.get("candidateCount", len(candidates))
    candidate_count = raw_count if isinstance(raw_count, int) and raw_count >= 0 else len(candidates)
    return {
        "candidateCount": candidate_count,
        "byKind": dict(sorted(by_kind.items())),
        "topCandidates": top_candidates,
    }


def decision_summary(reuse_decision: Any, present: bool) -> dict[str, Any]:
    if not present:
        return {
            "present": False,
            "decisionCount": 0,
            "byDisposition": {},
            "newCodeJustifications": 0,
        }
    if not isinstance(reuse_decision, dict):
        raise SummaryError(EXIT_INVALID_SHAPE, "reuse_decision.json must be a top-level object")
    decisions = reuse_decision.get("decisions", [])
    if not isinstance(decisions, list):
        raise SummaryError(EXIT_INVALID_SHAPE, "reuse_decision.json decisions must be an array")
    by_disposition: Counter[str] = Counter()
    for item in decisions:
        if isinstance(item, dict) and non_empty_string(item.get("disposition")):
            by_disposition[str(item["disposition"])] += 1
    justifications = reuse_decision.get("newCodeJustifications", [])
    justification_count = len(justifications) if isinstance(justifications, list) else 0
    return {
        "present": True,
        "decisionCount": len(decisions),
        "byDisposition": dict(sorted(by_disposition.items())),
        "newCodeJustifications": justification_count,
    }


def empty_counts() -> dict[str, int]:
    return {"critical": 0, "major": 0, "minor": 0, "info": 0, "total": 0}


def duplicate_audit_summary(duplicate_scan: Any, present: bool) -> dict[str, Any]:
    if not present:
        return {
            "present": False,
            "recommendedOutcome": None,
            "summaryCounts": empty_counts(),
            "unresolvedMajorFindings": 0,
            "unresolvedCriticalFindings": 0,
        }
    if not isinstance(duplicate_scan, dict):
        raise SummaryError(EXIT_INVALID_SHAPE, "duplicate_scan.json must be a top-level object")
    findings = duplicate_scan.get("findings", [])
    if not isinstance(findings, list):
        raise SummaryError(EXIT_INVALID_SHAPE, "duplicate_scan.json findings must be an array")

    unresolved_major = 0
    unresolved_critical = 0
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        severity = finding.get("severity")
        if not isinstance(severity, str):
            continue
        if finding.get("decisionAddressed") is True:
            continue
        normalized = severity.lower()
        if normalized == "major":
            unresolved_major += 1
        elif normalized == "critical":
            unresolved_critical += 1

    summary_counts = duplicate_scan.get("summaryCounts")
    if not isinstance(summary_counts, dict):
        summary_counts = empty_counts()
    else:
        summary_counts = {
            "critical": int(summary_counts.get("critical", 0) or 0),
            "major": int(summary_counts.get("major", 0) or 0),
            "minor": int(summary_counts.get("minor", 0) or 0),
            "info": int(summary_counts.get("info", 0) or 0),
            "total": int(summary_counts.get("total", 0) or 0),
        }
    result = {
        "present": True,
        "recommendedOutcome": duplicate_scan.get("recommendedOutcome"),
        "summaryCounts": summary_counts,
        "unresolvedMajorFindings": unresolved_major,
        "unresolvedCriticalFindings": unresolved_critical,
    }
    decision_status = duplicate_scan.get("decisionStatus")
    if isinstance(decision_status, dict):
        result["decisionStatus"] = {
            "present": bool(decision_status.get("present")),
            "valid": bool(decision_status.get("valid")),
            "entries": int(decision_status.get("entries", 0) or 0),
        }
    return result


def verdict_impact(audit_summary: Any, present: bool) -> dict[str, Any]:
    if not present or not isinstance(audit_summary, dict):
        return {
            "present": False,
            "appliedOutcomeCap": None,
            "reason": None,
        }
    awareness = audit_summary.get("codebaseAwareness")
    if not isinstance(awareness, dict):
        return {
            "present": False,
            "appliedOutcomeCap": None,
            "reason": None,
        }
    return {
        "present": True,
        "mode": awareness.get("mode"),
        "duplicateScanPresent": awareness.get("duplicateScanPresent"),
        "appliedOutcomeCap": awareness.get("appliedOutcomeCap"),
        "reason": awareness.get("reason"),
        "unresolvedMajorFindings": awareness.get("unresolvedMajorFindings", 0),
        "unresolvedCriticalFindings": awareness.get("unresolvedCriticalFindings", 0),
    }


def status_for(mode: str, present: dict[str, bool], notes: list[str]) -> str:
    if mode == "off":
        return STATUS_DISABLED
    evidence_present = any(present.get(name, False) for name in EVIDENCE_INPUTS)
    if not evidence_present:
        return STATUS_MISSING
    all_present = all(present.get(name, False) for name in (*EVIDENCE_INPUTS, "auditSummary"))
    if all_present and not notes:
        return STATUS_COMPLETE
    return STATUS_DEGRADED


def build_summary(args: argparse.Namespace) -> dict[str, Any]:
    mode = args.mode
    if mode not in MODES:
        raise SummaryError(EXIT_INVALID_SHAPE, f"mode must be one of {', '.join(sorted(MODES))}")

    project_root = Path(args.project_root).resolve()
    output_path = resolve(project_root, args.output)
    paths = {
        "contract": resolve(project_root, args.contract),
        "implementationContext": resolve(project_root, args.implementation_context),
        "reuseCandidates": resolve(project_root, args.reuse_candidates),
        "reuseDecision": resolve(project_root, args.reuse_decision),
        "duplicateScan": resolve(project_root, args.duplicate_scan),
        "auditSummary": resolve(project_root, args.audit_summary),
    }
    input_labels = {
        "contract": "contract",
        "implementationContext": "implementation context",
        "reuseCandidates": "reuse candidates",
        "reuseDecision": "reuse decision",
        "duplicateScan": "duplicate scan",
        "auditSummary": "audit summary",
    }
    input_args = {
        "implementationContext": args.implementation_context,
        "reuseCandidates": args.reuse_candidates,
        "reuseDecision": args.reuse_decision,
        "duplicateScan": args.duplicate_scan,
        "auditSummary": args.audit_summary,
    }

    contract = load_json(paths["contract"], "contract")
    present: dict[str, bool] = {"contract": True}
    data: dict[str, Any | None] = {"contract": contract}
    notes: list[str] = []

    for name in ("implementationContext", "reuseCandidates", "reuseDecision", "duplicateScan", "auditSummary"):
        is_present, loaded = load_optional_json(paths[name], input_labels[name])
        present[name] = is_present
        data[name] = loaded
        if not is_present:
            notes.append(f"{portable_input_path(input_args[name])} missing")

    if mode == "gate":
        missing_required = sorted(name for name in GATE_REQUIRED_INPUTS if not present.get(name, False))
        if missing_required:
            readable = ", ".join(portable_input_path(input_args[name]) for name in missing_required)
            raise SummaryError(EXIT_MISSING_INPUT, f"Missing required Codebase Awareness PACK input(s): {readable}")

    if present["reuseCandidates"]:
        candidate_part = candidate_summary(data["reuseCandidates"])
    else:
        candidate_part = {"candidateCount": 0, "byKind": {}, "topCandidates": []}
    decision_part = decision_summary(data["reuseDecision"], present["reuseDecision"])
    duplicate_part = duplicate_audit_summary(data["duplicateScan"], present["duplicateScan"])
    verdict_part = verdict_impact(data["auditSummary"], present["auditSummary"])
    status = status_for(mode, present, notes)

    evidence_refs = [
        portable_input_path(input_args[name])
        for name in EVIDENCE_INPUTS
        if present.get(name, False)
    ]
    summary = {
        "schemaVersion": SCHEMA_VERSION,
        "contractId": contract_id_from(
            data["contract"],
            data.get("reuseCandidates"),
            data.get("reuseDecision"),
            data.get("auditSummary"),
            output_path,
        ),
        "generatedAt": args.generated_at or utc_now(),
        "mode": mode,
        "status": status,
        "inputs": {
            "implementationContext": portable_input_path(args.implementation_context),
            "reuseCandidates": portable_input_path(args.reuse_candidates),
            "reuseDecision": portable_input_path(args.reuse_decision),
            "duplicateScan": portable_input_path(args.duplicate_scan),
            "auditSummary": portable_input_path(args.audit_summary),
        },
        "candidateSummary": candidate_part,
        "decisionSummary": decision_part,
        "duplicateAuditSummary": duplicate_part,
        "verdictImpact": verdict_part,
        "evidenceRefs": evidence_refs,
        "notes": notes,
    }
    return summary


def write_summary(path: Path, summary: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    project_root = Path(args.project_root).resolve()
    output_path = resolve(project_root, args.output)
    try:
        summary = build_summary(args)
        write_summary(output_path, summary)
    except SummaryError as exc:
        print(exc.message, file=sys.stderr)
        return exc.exit_code
    except OSError as exc:
        print(f"Unable to write reuse summary {output_path}: {exc}", file=sys.stderr)
        return EXIT_INFRA

    print(f"reuse_summary.json written: {output_path}")
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
