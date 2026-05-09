"""Historical replay drift signal for signum-evolve candidates."""
from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from .candidate import load_json, write_json


COUNT_FIELDS = (
    "newFindingsCount",
    "removedFindingsCount",
    "changedSeverityCount",
    "changedRuleCount",
    "removedCriticalFindingsCount",
    "newCriticalFindingsCount",
)


def empty_replay(status: str, *, reason: Optional[str] = None) -> Dict[str, Any]:
    replay: Dict[str, Any] = {
        "changedRuleCount": 0,
        "changedSeverityCount": 0,
        "itemCount": 0,
        "items": [],
        "newCriticalFindingsCount": 0,
        "newFindingsCount": 0,
        "removedCriticalFindingsCount": 0,
        "removedFindingsCount": 0,
        "status": status,
    }
    if reason:
        replay["reason"] = reason
    return replay


def path_ref(repo_root: Path, historical_root: Path, path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(repo_root).as_posix()
    except ValueError:
        pass

    root = historical_root.resolve()
    try:
        return f"external:{root.name}/{resolved.relative_to(root).as_posix()}"
    except ValueError:
        return f"external:{resolved.name}"


def stable_finding(finding: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "file": finding.get("file"),
        "line": finding.get("line"),
        "ruleId": finding.get("ruleId"),
        "severity": finding.get("severity"),
        "snippet": finding.get("snippet"),
    }


def finding_identity(finding: Dict[str, Any]) -> Tuple[str, str, int, str, str]:
    line = finding.get("line")
    line_value = line if isinstance(line, int) else -1
    return (
        str(finding.get("ruleId", "")),
        str(finding.get("file", "")),
        line_value,
        str(finding.get("severity", "")),
        str(finding.get("snippet", "")),
    )


def severity_identity(finding: Dict[str, Any]) -> Tuple[str, str, int, str]:
    line = finding.get("line")
    line_value = line if isinstance(line, int) else -1
    return (
        str(finding.get("ruleId", "")),
        str(finding.get("file", "")),
        line_value,
        str(finding.get("snippet", "")),
    )


def rule_identity(finding: Dict[str, Any]) -> Tuple[str, int, str, str]:
    line = finding.get("line")
    line_value = line if isinstance(line, int) else -1
    return (
        str(finding.get("file", "")),
        line_value,
        str(finding.get("severity", "")),
        str(finding.get("snippet", "")),
    )


def sorted_findings(findings: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return sorted((stable_finding(item) for item in findings), key=finding_identity)


def scan_patch(repo_root: Path, patch_path: Path, catalog_path: Path) -> Tuple[List[Dict[str, Any]], Optional[str]]:
    with tempfile.TemporaryDirectory(prefix="signum-evolve-replay-") as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        temp_patch = temp_dir / "combined.patch"
        temp_patch.write_text(patch_path.read_text(encoding="utf-8"), encoding="utf-8")

        env = os.environ.copy()
        env["SIGNUM_POLICY_RULE_CATALOG"] = str(catalog_path)
        proc = subprocess.run(
            ["bash", "lib/policy-scanner.sh", str(temp_patch)],
            cwd=str(repo_root),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        output_path = temp_dir / "policy_scan.json"
        if proc.returncode != 0:
            return [], "scanner_failed"
        if not output_path.exists():
            return [], "missing_policy_scan"
        output = load_json(output_path)
        findings = output.get("findings")
        if not isinstance(findings, list):
            return [], "invalid_policy_scan"
        return sorted_findings(item for item in findings if isinstance(item, dict)), None


def changed_severity(
    baseline_findings: List[Dict[str, Any]],
    candidate_findings: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    baseline_by_identity = {severity_identity(item): item for item in baseline_findings}
    candidate_by_identity = {severity_identity(item): item for item in candidate_findings}
    changes: List[Dict[str, Any]] = []
    for identity in sorted(set(baseline_by_identity) & set(candidate_by_identity)):
        baseline = baseline_by_identity[identity]
        candidate = candidate_by_identity[identity]
        if baseline.get("severity") == candidate.get("severity"):
            continue
        changes.append(
            {
                "baselineSeverity": baseline.get("severity"),
                "candidateSeverity": candidate.get("severity"),
                "file": baseline.get("file"),
                "line": baseline.get("line"),
                "ruleId": baseline.get("ruleId"),
                "snippet": baseline.get("snippet"),
            }
        )
    return changes


def changed_rule(
    baseline_findings: List[Dict[str, Any]],
    candidate_findings: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    baseline_by_identity = {rule_identity(item): item for item in baseline_findings}
    candidate_by_identity = {rule_identity(item): item for item in candidate_findings}
    changes: List[Dict[str, Any]] = []
    for identity in sorted(set(baseline_by_identity) & set(candidate_by_identity)):
        baseline = baseline_by_identity[identity]
        candidate = candidate_by_identity[identity]
        if baseline.get("ruleId") == candidate.get("ruleId"):
            continue
        changes.append(
            {
                "baselineRuleId": baseline.get("ruleId"),
                "candidateRuleId": candidate.get("ruleId"),
                "file": baseline.get("file"),
                "line": baseline.get("line"),
                "severity": baseline.get("severity"),
                "snippet": baseline.get("snippet"),
            }
        )
    return changes


def replay_item(
    repo_root: Path,
    historical_root: Path,
    patch_path: Path,
    baseline_catalog_path: Path,
    candidate_catalog_path: Path,
) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    baseline_findings, baseline_error = scan_patch(repo_root, patch_path, baseline_catalog_path)
    if baseline_error:
        return None, baseline_error
    candidate_findings, candidate_error = scan_patch(repo_root, patch_path, candidate_catalog_path)
    if candidate_error:
        return None, candidate_error

    baseline_by_identity = {finding_identity(item): item for item in baseline_findings}
    candidate_by_identity = {finding_identity(item): item for item in candidate_findings}
    new_findings = [candidate_by_identity[key] for key in sorted(set(candidate_by_identity) - set(baseline_by_identity))]
    removed_findings = [baseline_by_identity[key] for key in sorted(set(baseline_by_identity) - set(candidate_by_identity))]

    return (
        {
            "baselineFindingCount": len(baseline_findings),
            "candidateFindingCount": len(candidate_findings),
            "changedRule": changed_rule(baseline_findings, candidate_findings),
            "changedSeverity": changed_severity(baseline_findings, candidate_findings),
            "contractId": patch_path.parent.name,
            "newFindings": new_findings,
            "patchPath": path_ref(repo_root, historical_root, patch_path),
            "removedFindings": removed_findings,
        },
        None,
    )


def summarize_items(items: List[Dict[str, Any]]) -> Dict[str, int]:
    new_findings = [finding for item in items for finding in item.get("newFindings", [])]
    removed_findings = [finding for item in items for finding in item.get("removedFindings", [])]
    changed_severity_items = [finding for item in items for finding in item.get("changedSeverity", [])]
    changed_rule_items = [finding for item in items for finding in item.get("changedRule", [])]
    return {
        "changedRuleCount": len(changed_rule_items),
        "changedSeverityCount": len(changed_severity_items),
        "newCriticalFindingsCount": sum(1 for finding in new_findings if finding.get("severity") == "CRITICAL"),
        "newFindingsCount": len(new_findings),
        "removedCriticalFindingsCount": sum(
            1 for finding in removed_findings if finding.get("severity") == "CRITICAL"
        ),
        "removedFindingsCount": len(removed_findings),
    }


def discover_patch_paths(historical_root: Path) -> List[Path]:
    if not historical_root.is_dir():
        return []
    return sorted(
        (path / "combined.patch" for path in historical_root.iterdir() if (path / "combined.patch").is_file()),
        key=lambda path: (path.parent.name, path.as_posix()),
    )


def run_historical_replay(
    repo_root: Path,
    historical_root: Path,
    baseline_catalog_path: Path,
    candidate_catalog_path: Path,
) -> Dict[str, Any]:
    if not historical_root.exists():
        return empty_replay("skipped", reason="missing_root")
    if not historical_root.is_dir():
        return empty_replay("skipped", reason="not_directory")

    items: List[Dict[str, Any]] = []
    for patch_path in discover_patch_paths(historical_root):
        item, error = replay_item(
            repo_root,
            historical_root,
            patch_path,
            baseline_catalog_path,
            candidate_catalog_path,
        )
        if error:
            replay = empty_replay("error", reason=error)
            replay["itemCount"] = len(items)
            replay["items"] = items
            return replay
        if item:
            items.append(item)

    summary = summarize_items(items)
    return {
        **summary,
        "itemCount": len(items),
        "items": items,
        "status": "ok",
    }


def write_historical_replay(candidate_dir: Path, replay: Dict[str, Any]) -> Path:
    path = candidate_dir / "historical_replay.json"
    write_json(path, replay)
    return path


def compact_historical_replay(replay: Dict[str, Any]) -> Dict[str, Any]:
    compact: Dict[str, Any] = {
        "itemCount": replay.get("itemCount", 0),
        "newFindingsCount": replay.get("newFindingsCount", 0),
        "removedCriticalFindingsCount": replay.get("removedCriticalFindingsCount", 0),
        "removedFindingsCount": replay.get("removedFindingsCount", 0),
        "status": replay.get("status"),
    }
    if replay.get("reason"):
        compact["reason"] = replay.get("reason")
    return compact


def decision_with_replay(compare: Dict[str, Any], replay: Optional[Dict[str, Any]]) -> Any:
    decision = compare.get("decision")
    if not replay or replay.get("status") == "skipped":
        return decision
    if replay.get("removedCriticalFindingsCount", 0) <= 0:
        return decision
    if decision == "reject":
        return "reject"
    return "review"
