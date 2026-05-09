"""Candidate catalog construction for signum-evolve v0."""
from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence


DEFAULT_ALLOWED_PREFIXES = ("docs/", "examples/", "fixtures/", "tests/", "test/", "generated/")


def canonical_json(data: Dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} root must be a JSON object")
    return data


def write_json(path: Path, data: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(canonical_json(data), encoding="utf-8")


def load_catalog(path: Path) -> Dict[str, Any]:
    catalog = load_json(path)
    rules = catalog.get("rules")
    if not isinstance(rules, list) or not rules:
        raise ValueError("policy rule catalog must contain a non-empty rules array")
    return catalog


def noncritical_rules(catalog: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
    for rule in catalog.get("rules", []):
        if not isinstance(rule, dict):
            continue
        if rule.get("severity") != "CRITICAL":
            yield rule


def candidate_id(index: int) -> str:
    return f"cand_{index:06d}"


def build_candidate(
    *,
    base_catalog: Dict[str, Any],
    index: int,
    seed: int,
    operator: str,
    rule_id: str,
    prefix: str,
) -> Dict[str, Any]:
    catalog = copy.deepcopy(base_catalog)
    changed = False
    for rule in catalog["rules"]:
        if rule.get("ruleId") != rule_id:
            continue
        if rule.get("severity") == "CRITICAL":
            raise ValueError(f"critical rule cannot be mutated: {rule_id}")
        prefixes = list(rule.get("excludedPathPrefixes", []))
        if operator == "add_excluded_path_prefix":
            if prefix not in prefixes:
                prefixes.append(prefix)
                rule["excludedPathPrefixes"] = prefixes
                changed = True
        else:
            raise ValueError(f"unsupported mutation operator: {operator}")
        break
    if not changed:
        raise ValueError(f"mutation produced no catalog change: {rule_id} {prefix}")

    return {
        "candidateId": candidate_id(index),
        "catalog": catalog,
        "createdAt": None,
        "mutation": {
            "operator": operator,
            "prefix": prefix,
            "ruleId": rule_id,
        },
        "parentId": "baseline",
        "schemaVersion": "1.0",
        "seed": seed,
    }


def generate_candidates(
    catalog: Dict[str, Any],
    *,
    max_candidates: int,
    seed: int,
    allowed_prefixes: Sequence[str] = DEFAULT_ALLOWED_PREFIXES,
) -> List[Dict[str, Any]]:
    candidates: List[Dict[str, Any]] = []
    next_index = 1
    for rule in noncritical_rules(catalog):
        rule_id = str(rule.get("ruleId"))
        existing_prefixes = set(rule.get("excludedPathPrefixes", []))
        for prefix in allowed_prefixes:
            if prefix in existing_prefixes:
                continue
            candidates.append(
                build_candidate(
                    base_catalog=catalog,
                    index=next_index,
                    seed=seed,
                    operator="add_excluded_path_prefix",
                    rule_id=rule_id,
                    prefix=prefix,
                )
            )
            next_index += 1
            if len(candidates) >= max_candidates:
                return candidates
    return candidates
