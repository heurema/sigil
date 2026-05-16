"""Catalog diff helpers for signum-evolve candidate review."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

from .candidate import write_json
from .mutate import IMMUTABLE_RULE_FIELDS, rule_by_id


def _as_string_list(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    return sorted(item for item in value if isinstance(item, str))


def diff_catalogs(base_catalog: Dict[str, Any], candidate_catalog: Dict[str, Any]) -> Dict[str, Any]:
    base_rules = rule_by_id(base_catalog)
    candidate_rules = rule_by_id(candidate_catalog)
    rule_ids = sorted(set(base_rules) | set(candidate_rules))
    changes: List[Dict[str, Any]] = []
    critical_rule_changes: List[str] = []

    for rule_id in rule_ids:
        base_rule = base_rules.get(rule_id)
        candidate_rule = candidate_rules.get(rule_id)
        if base_rule is None:
            changes.append({"changeType": "rule_added", "ruleId": rule_id})
            critical_rule_changes.append(rule_id)
            continue
        if candidate_rule is None:
            changes.append({"changeType": "rule_removed", "ruleId": rule_id})
            if base_rule.get("severity") == "CRITICAL":
                critical_rule_changes.append(rule_id)
            continue

        base_prefixes = set(_as_string_list(base_rule.get("excludedPathPrefixes")))
        candidate_prefixes = set(_as_string_list(candidate_rule.get("excludedPathPrefixes")))
        added_prefixes = sorted(candidate_prefixes - base_prefixes)
        removed_prefixes = sorted(base_prefixes - candidate_prefixes)
        immutable_changes = sorted(
            field
            for field in IMMUTABLE_RULE_FIELDS
            if base_rule.get(field) != candidate_rule.get(field)
        )

        if not added_prefixes and not removed_prefixes and not immutable_changes:
            continue

        change = {
            "addedExcludedPathPrefixes": added_prefixes,
            "autoBlock": candidate_rule.get("autoBlock"),
            "immutableFieldChanges": immutable_changes,
            "pattern": candidate_rule.get("pattern"),
            "removedExcludedPathPrefixes": removed_prefixes,
            "ruleId": rule_id,
            "severity": candidate_rule.get("severity"),
            "type": candidate_rule.get("type"),
        }
        changes.append(change)

        if base_rule.get("severity") == "CRITICAL" and (
            added_prefixes or removed_prefixes or immutable_changes
        ):
            critical_rule_changes.append(rule_id)

    return {
        "changedRuleCount": len(changes),
        "changes": changes,
        "criticalRuleChanges": sorted(set(critical_rule_changes)),
        "criticalRuleChangesCount": len(set(critical_rule_changes)),
        "schemaVersion": "1.0",
    }


def write_catalog_diff(candidate_dir: Path, diff: Dict[str, Any]) -> Path:
    path = candidate_dir / "catalog_diff.json"
    write_json(path, diff)
    return path
