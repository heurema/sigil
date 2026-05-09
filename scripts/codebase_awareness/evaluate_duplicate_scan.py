#!/usr/bin/env python3
"""Apply conservative Codebase Awareness verdict mapping to audit_summary.json."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

VALID_MODES = {"off", "hint", "warn", "gate"}
DECISION_RANK = {"AUTO_OK": 0, "HUMAN_REVIEW": 1, "AUTO_BLOCK": 2}
RELEASE_BY_DECISION = {
    "AUTO_OK": "PROMOTE",
    "HUMAN_REVIEW": "HOLD",
    "AUTO_BLOCK": "REJECT",
}
GATE_BLOCKING_MAJOR_KINDS = {
    "new-helper-similar-to-existing-candidate",
    "added-block-token-overlap",
}
STRONG_DUPLICATE_EVIDENCE_TERMS = {
    "token",
    "tokens",
    "fingerprint",
    "sequence",
    "block",
    "blocks",
    "body",
}


class ScanState:
    def __init__(
        self,
        *,
        present: bool,
        valid: bool,
        data: dict[str, Any] | None = None,
        error: str | None = None,
    ) -> None:
        self.present = present
        self.valid = valid
        self.data = data or {}
        self.error = error


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evaluate duplicate_scan.json and cap Signum audit_summary.json when required."
    )
    parser.add_argument("--audit-summary", required=True)
    parser.add_argument("--duplicate-scan", required=True)
    parser.add_argument("--mode", required=True, choices=sorted(VALID_MODES))
    parser.add_argument("--output", default=None)
    return parser.parse_args(argv)


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid {label} JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise OSError(f"Unable to read {label} JSON {path}: {exc}") from exc


def load_scan(path: Path) -> ScanState:
    if not path.is_file():
        return ScanState(present=False, valid=False, error="missing")
    try:
        data = load_json(path, "duplicate scan")
    except ValueError:
        return ScanState(present=True, valid=False, error="invalid_json")
    except OSError:
        return ScanState(present=True, valid=False, error="read_error")
    if not isinstance(data, dict) or not isinstance(data.get("findings", []), list):
        return ScanState(present=True, valid=False, error="invalid_shape")
    return ScanState(present=True, valid=True, data=data)


def severity_of(finding: Any) -> str:
    if not isinstance(finding, dict):
        return ""
    severity = finding.get("severity")
    if isinstance(severity, str):
        return severity.strip().lower()
    return ""


def score_of(finding: dict[str, Any]) -> float:
    score = finding.get("score")
    if isinstance(score, (int, float)):
        return float(score)
    return 0.0


def why_count(finding: dict[str, Any]) -> int:
    why = finding.get("why")
    if not isinstance(why, list):
        return 0
    return sum(1 for item in why if isinstance(item, str) and item.strip())


def has_strong_duplicate_evidence(finding: dict[str, Any]) -> bool:
    why = finding.get("why")
    if not isinstance(why, list):
        return False
    for item in why:
        if not isinstance(item, str):
            continue
        lowered = item.lower()
        if any(term in lowered for term in STRONG_DUPLICATE_EVIDENCE_TERMS):
            return True
    return False


def is_unresolved(finding: Any) -> bool:
    if not isinstance(finding, dict):
        return False
    return severity_of(finding) in {"major", "critical"} and finding.get("decisionAddressed") is not True


def is_gate_blocking_major(finding: dict[str, Any]) -> bool:
    return (
        severity_of(finding) == "major"
        and score_of(finding) >= 0.85
        and finding.get("decisionAddressed") is not True
        and finding.get("kind") in GATE_BLOCKING_MAJOR_KINDS
        and why_count(finding) >= 2
        and has_strong_duplicate_evidence(finding)
    )


def summarize_findings(scan: dict[str, Any]) -> dict[str, Any]:
    findings = scan.get("findings", [])
    unresolved_major = []
    unresolved_critical = []
    gate_blocking_major = []

    if isinstance(findings, list):
        for finding in findings:
            if not is_unresolved(finding):
                continue
            severity = severity_of(finding)
            if severity == "critical":
                unresolved_critical.append(finding)
            elif severity == "major":
                unresolved_major.append(finding)
                if isinstance(finding, dict) and is_gate_blocking_major(finding):
                    gate_blocking_major.append(finding)

    summary_counts = scan.get("summaryCounts")
    if not isinstance(summary_counts, dict):
        summary_counts = count_by_severity(findings if isinstance(findings, list) else [])

    return {
        "summaryCounts": summary_counts,
        "unresolvedMajorFindings": len(unresolved_major),
        "unresolvedCriticalFindings": len(unresolved_critical),
        "gateBlockingMajorFindings": len(gate_blocking_major),
    }


def count_by_severity(findings: list[Any]) -> dict[str, int]:
    counts = {"critical": 0, "major": 0, "minor": 0, "info": 0, "total": 0}
    for finding in findings:
        severity = severity_of(finding)
        if severity in counts and severity != "total":
            counts[severity] += 1
            counts["total"] += 1
    return counts


def requested_decision(mode: str, scan_state: ScanState, summary: dict[str, Any]) -> tuple[str | None, str]:
    if mode in {"off", "hint"}:
        return None, f"{mode} mode leaves duplicate scan findings informational"

    if not scan_state.present:
        if mode == "warn":
            return "HUMAN_REVIEW", "warn mode caps missing duplicate_scan.json at HUMAN_REVIEW"
        return "AUTO_BLOCK", "gate mode blocks missing duplicate_scan.json"

    if not scan_state.valid:
        if mode == "warn":
            return "HUMAN_REVIEW", "warn mode caps invalid duplicate_scan.json at HUMAN_REVIEW"
        return "AUTO_BLOCK", "gate mode blocks invalid duplicate_scan.json"

    unresolved_critical = int(summary["unresolvedCriticalFindings"])
    unresolved_major = int(summary["unresolvedMajorFindings"])
    gate_blocking_major = int(summary["gateBlockingMajorFindings"])

    if mode == "warn":
        if unresolved_critical or unresolved_major:
            return "HUMAN_REVIEW", "warn mode caps unresolved major or critical duplicate findings at HUMAN_REVIEW"
        return None, "warn mode found no unresolved major or critical duplicate findings"

    if mode == "gate":
        if unresolved_critical:
            return "AUTO_BLOCK", "gate mode blocks unresolved critical duplicate findings"
        if gate_blocking_major:
            return "AUTO_BLOCK", "gate mode blocks high-confidence unresolved major duplicate findings"
        if unresolved_major:
            return "HUMAN_REVIEW", "gate mode caps lower-confidence unresolved major duplicate findings at HUMAN_REVIEW"
        return None, "gate mode found no unresolved blocking duplicate findings"

    return None, "no Codebase Awareness verdict mapping applied"


def preserve_stricter(existing: str, requested: str | None) -> str:
    if requested is None:
        return existing if existing in DECISION_RANK else "HUMAN_REVIEW"
    existing_rank = DECISION_RANK.get(existing, DECISION_RANK["HUMAN_REVIEW"])
    requested_rank = DECISION_RANK[requested]
    return existing if existing_rank >= requested_rank and existing in DECISION_RANK else requested


def update_release_verdict(summary: dict[str, Any], old_decision: str, new_decision: str) -> None:
    if new_decision != old_decision:
        summary["releaseVerdict"] = RELEASE_BY_DECISION[new_decision]
    elif new_decision in {"HUMAN_REVIEW", "AUTO_BLOCK"}:
        summary["releaseVerdict"] = RELEASE_BY_DECISION[new_decision]


def append_reasoning(summary: dict[str, Any], reason: str, old_decision: str, new_decision: str) -> None:
    if old_decision == new_decision and "caps" not in reason and "blocks" not in reason:
        return
    current = summary.get("reasoning")
    if not isinstance(current, str):
        current = ""
    note = f"Codebase Awareness: {reason}."
    if note in current:
        return
    summary["reasoning"] = f"{current.rstrip()} {note}".strip()


def evaluate(audit_summary: dict[str, Any], duplicate_scan_path: str, mode: str, scan_state: ScanState) -> dict[str, Any]:
    scan_summary = summarize_findings(scan_state.data) if scan_state.valid else {
        "summaryCounts": {"critical": 0, "major": 0, "minor": 0, "info": 0, "total": 0},
        "unresolvedMajorFindings": 0,
        "unresolvedCriticalFindings": 0,
        "gateBlockingMajorFindings": 0,
    }
    requested, reason = requested_decision(mode, scan_state, scan_summary)

    old_decision = audit_summary.get("decision")
    if not isinstance(old_decision, str):
        old_decision = "HUMAN_REVIEW"
    new_decision = preserve_stricter(old_decision, requested)
    preserved_stricter = (
        requested is not None
        and old_decision in DECISION_RANK
        and DECISION_RANK[old_decision] > DECISION_RANK[requested]
        and new_decision == old_decision
    )
    if preserved_stricter:
        reason = f"{reason}; existing {old_decision} preserved because it is stricter than Codebase Awareness mapping"

    audit_summary["decision"] = new_decision
    update_release_verdict(audit_summary, old_decision, new_decision)
    append_reasoning(audit_summary, reason, old_decision, new_decision)
    audit_summary["codebaseAwareness"] = {
        "mode": mode,
        "duplicateScanPresent": scan_state.present,
        "duplicateScanValid": scan_state.valid,
        "duplicateScanPath": duplicate_scan_path,
        "summaryCounts": scan_summary["summaryCounts"],
        "unresolvedMajorFindings": scan_summary["unresolvedMajorFindings"],
        "unresolvedCriticalFindings": scan_summary["unresolvedCriticalFindings"],
        "gateBlockingMajorFindings": scan_summary["gateBlockingMajorFindings"],
        "appliedOutcomeCap": requested,
        "preservedStricterExistingDecision": preserved_stricter,
        "finalDecision": new_decision,
        "reason": reason,
    }
    if scan_state.error:
        audit_summary["codebaseAwareness"]["error"] = scan_state.error

    return audit_summary


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    audit_summary_path = Path(args.audit_summary)
    duplicate_scan_path = Path(args.duplicate_scan)
    output_path = Path(args.output) if args.output else audit_summary_path

    try:
        audit_summary = load_json(audit_summary_path, "audit summary")
        if not isinstance(audit_summary, dict):
            print("audit_summary.json must be a top-level object", file=sys.stderr)
            return 4
        scan_state = load_scan(duplicate_scan_path)
        updated = evaluate(audit_summary, args.duplicate_scan, args.mode, scan_state)
        write_json(output_path, updated)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 3
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        return 5

    decision = updated.get("decision", "unknown")
    awareness = updated.get("codebaseAwareness", {})
    print(
        "Codebase Awareness verdict mapping: "
        f"mode={args.mode} decision={decision} reason={awareness.get('reason', 'unknown')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
