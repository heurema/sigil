"""Mutation policy helpers for signum-evolve v0."""
from __future__ import annotations

from typing import Any, Dict, Iterable, List


IMMUTABLE_RULE_FIELDS = {
    "autoBlock",
    "engine",
    "pattern",
    "regex",
    "ruleId",
    "severity",
    "type",
}


def rule_by_id(catalog: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {str(rule.get("ruleId")): rule for rule in catalog.get("rules", []) if isinstance(rule, dict)}


def validate_scope_only_mutation(base_catalog: Dict[str, Any], candidate_catalog: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    base_rules = rule_by_id(base_catalog)
    candidate_rules = rule_by_id(candidate_catalog)

    if set(base_rules) != set(candidate_rules):
        errors.append("candidate must preserve the exact baseline rule IDs")
        return errors

    for rule_id in sorted(base_rules):
        base_rule = base_rules[rule_id]
        candidate_rule = candidate_rules[rule_id]
        for field in IMMUTABLE_RULE_FIELDS:
            if base_rule.get(field) != candidate_rule.get(field):
                errors.append(f"{rule_id} changed immutable field {field}")
        if base_rule.get("severity") == "CRITICAL":
            if base_rule.get("excludedPathPrefixes") != candidate_rule.get("excludedPathPrefixes"):
                errors.append(f"{rule_id} changed CRITICAL rule scope")
    return errors


def mutation_summary(candidate: Dict[str, Any]) -> str:
    mutation = candidate.get("mutation", {})
    if not isinstance(mutation, dict):
        return "unknown mutation"
    return "{operator} {ruleId} {prefix}".format(
        operator=mutation.get("operator", "unknown"),
        ruleId=mutation.get("ruleId", "unknown"),
        prefix=mutation.get("prefix", ""),
    ).strip()
