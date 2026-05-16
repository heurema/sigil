"""Candidate catalog construction for signum-evolve."""
from __future__ import annotations

import copy
import itertools
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
    rule_id: str,
    prefixes: Sequence[str],
) -> Dict[str, Any]:
    catalog = copy.deepcopy(base_catalog)
    prefixes_to_add = list(prefixes)
    changed_prefixes: List[str] = []
    for rule in catalog["rules"]:
        if rule.get("ruleId") != rule_id:
            continue
        if rule.get("severity") == "CRITICAL":
            raise ValueError(f"critical rule cannot be mutated: {rule_id}")
        rule_prefixes = list(rule.get("excludedPathPrefixes", []))
        for prefix in prefixes_to_add:
            if prefix not in rule_prefixes:
                rule_prefixes.append(prefix)
                changed_prefixes.append(prefix)
        if changed_prefixes:
            rule["excludedPathPrefixes"] = rule_prefixes
        break
    if not changed_prefixes:
        raise ValueError(f"mutation produced no catalog change: {rule_id} {list(prefixes_to_add)}")

    mutations = [
        {
            "operator": "add_excluded_path_prefix",
            "prefix": prefix,
            "ruleId": rule_id,
        }
        for prefix in changed_prefixes
    ]
    mutation: Dict[str, Any]
    if len(mutations) == 1:
        mutation = dict(mutations[0])
    else:
        mutation = {
            "operator": "add_excluded_path_prefix_set",
            "prefixes": changed_prefixes,
            "ruleId": rule_id,
        }

    return {
        "candidateId": candidate_id(index),
        "catalog": catalog,
        "createdAt": None,
        "mutation": mutation,
        "mutationCount": len(mutations),
        "mutations": mutations,
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
    max_mutation_depth: int = 1,
) -> List[Dict[str, Any]]:
    candidates: List[Dict[str, Any]] = []
    if max_candidates <= 0 or max_mutation_depth <= 0:
        return candidates
    next_index = 1
    for rule in noncritical_rules(catalog):
        rule_id = str(rule.get("ruleId"))
        existing_prefixes = set(rule.get("excludedPathPrefixes", []))
        missing_prefixes = [prefix for prefix in allowed_prefixes if prefix not in existing_prefixes]
        max_depth = min(max_mutation_depth, len(missing_prefixes))
        for depth in range(1, max_depth + 1):
            for prefix_set in itertools.combinations(missing_prefixes, depth):
                candidates.append(
                    build_candidate(
                        base_catalog=catalog,
                        index=next_index,
                        seed=seed,
                        rule_id=rule_id,
                        prefixes=prefix_set,
                    )
                )
                next_index += 1
                if len(candidates) >= max_candidates:
                    return candidates
    return candidates
