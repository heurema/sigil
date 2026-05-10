#!/usr/bin/env python3
"""Build contract-aware reuse candidates from local scanner artifacts."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STOPWORDS = {
    "a",
    "an",
    "and",
    "are",
    "as",
    "be",
    "by",
    "can",
    "do",
    "for",
    "from",
    "if",
    "in",
    "into",
    "is",
    "it",
    "new",
    "not",
    "of",
    "on",
    "or",
    "our",
    "should",
    "that",
    "the",
    "this",
    "to",
    "use",
    "using",
    "when",
    "where",
    "with",
}

PATH_RE = re.compile(
    r"(?:[\w.@+-]+/)+[\w.@+-]+(?:\.[A-Za-z0-9]+)?|"
    r"[\w.@+-]+\.(?:cjs|cts|go|js|jsx|json|mjs|mts|py|rs|sh|toml|ts|tsx|yaml|yml)"
)

LANGUAGE_BY_SUFFIX = {
    ".go": "go",
    ".js": "javascript",
    ".jsx": "javascript",
    ".mjs": "javascript",
    ".cjs": "javascript",
    ".py": "python",
    ".rs": "rust",
    ".sh": "shell",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".mts": "typescript",
    ".cts": "typescript",
}

SUMMARY_KEYS = {"goal", "objective", "summary", "task", "title"}
SCOPE_KEYS = {"acceptancecriteria", "acceptance", "inscope", "scope"}
RISK_KEYS = {"policy", "policyhints", "risk", "risklevel", "risks"}
SHARED_DIR_HINTS = {"common", "lib", "shared", "utils"}
VALIDATION_TOKENS = {"assert", "check", "parse", "schema", "valid", "validate", "validation", "validator"}
GENERIC_DOMAIN_TOKENS = {
    "add",
    "code",
    "existing",
    "flow",
    "go",
    "golang",
    "helper",
    "helpers",
    "javascript",
    "python",
    "rust",
    "shell",
    "task",
    "typescript",
}

SUGGESTED_ACTION_BY_KIND = {
    "config-pattern": "follow-pattern",
    "duplicate-risk": "check-duplicate-risk",
    "error-handling-pattern": "follow-pattern",
    "existing-helper": "reuse-or-extend",
    "local-pattern": "follow-pattern",
    "module-boundary": "respect-boundary",
    "shared-module": "reuse-or-extend",
    "test-pattern": "follow-pattern",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build Signum reuse candidates from scanner artifacts.")
    parser.add_argument("--project-root", default=".")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--contract-engineer", default=None)
    parser.add_argument("--codebase-index", required=True)
    parser.add_argument("--style-profile", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--implementation-context", required=True)
    parser.add_argument("--max-candidates", type=int, default=8)
    parser.add_argument("--generated-at", default=None)
    return parser.parse_args(argv)


def portable_project_root(project_root_arg: str) -> str:
    if Path(project_root_arg).is_absolute():
        return "."
    return project_root_arg or "."


def portable_cli_path(value: str, project_root: Path) -> str:
    path = Path(value)
    if not path.is_absolute():
        return value
    try:
        return path.relative_to(project_root).as_posix()
    except ValueError:
        return path.name


def load_json(path: Path, label: str, required: bool = True) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        if required:
            raise SystemExit(f"Required {label} JSON not found: {path}")
        return {}
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid {label} JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        return {}
    return data


def split_identifier(value: str) -> list[str]:
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", value)
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", value)
    raw = re.split(r"[^A-Za-z0-9]+", value)
    tokens = []
    for item in raw:
        token = item.lower()
        if len(token) < 2 or token in STOPWORDS:
            continue
        tokens.append(token)
    return tokens


def tokenize_text(value: str) -> set[str]:
    return set(split_identifier(value))


def collect_strings(value: Any) -> list[str]:
    strings: list[str] = []
    if isinstance(value, str):
        strings.append(value)
    elif isinstance(value, list):
        for item in value:
            strings.extend(collect_strings(item))
    elif isinstance(value, dict):
        for key, item in sorted(value.items(), key=lambda pair: str(pair[0])):
            strings.append(str(key))
            strings.extend(collect_strings(item))
    return strings


def strings_for_keys(value: Any, keys: set[str]) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, item in sorted(value.items(), key=lambda pair: str(pair[0])):
            normalized = re.sub(r"[^a-z0-9]", "", str(key).lower())
            if normalized in keys:
                found.extend(collect_strings(item))
            found.extend(strings_for_keys(item, keys))
    elif isinstance(value, list):
        for item in value:
            found.extend(strings_for_keys(item, keys))
    return found


def extract_paths(strings: list[str]) -> list[str]:
    paths: set[str] = set()
    for value in strings:
        for match in PATH_RE.findall(value):
            paths.add(match.strip(".,;:()[]{}\"'"))
    return sorted(paths)


def infer_contract_id(contract: dict[str, Any], engineer_contract: dict[str, Any], contract_path: Path) -> str:
    for data in (contract, engineer_contract):
        for key in ("contractId", "id", "runId"):
            value = data.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    if contract_path.name in {"contract.json", "contract-engineer.json"} and contract_path.parent.name:
        return contract_path.parent.name
    if contract_path.stem:
        return contract_path.stem
    return "unknown"


def extract_task_intent(
    contract: dict[str, Any], engineer_contract: dict[str, Any], contract_path: Path
) -> dict[str, Any]:
    merged = [contract, engineer_contract]
    all_strings: list[str] = []
    summary_strings: list[str] = []
    scope_strings: list[str] = []
    risk_strings: list[str] = []
    for data in merged:
        if not data:
            continue
        all_strings.extend(collect_strings(data))
        summary_strings.extend(strings_for_keys(data, SUMMARY_KEYS))
        scope_strings.extend(strings_for_keys(data, SCOPE_KEYS))
        risk_strings.extend(strings_for_keys(data, RISK_KEYS))

    summary = ""
    for value in summary_strings:
        stripped = " ".join(value.split())
        if stripped:
            summary = stripped
            break
    if not summary:
        for value in all_strings:
            stripped = " ".join(value.split())
            if len(stripped) > 12:
                summary = stripped
                break

    token_counter: Counter[str] = Counter()
    for value in all_strings:
        token_counter.update(split_identifier(value))
    tokens = [
        token
        for token, _count in sorted(token_counter.items(), key=lambda item: (-item[1], item[0]))
    ]
    target_paths = extract_paths(all_strings)
    mentioned_modules = sorted(
        {
            Path(path).stem
            for path in target_paths
            if Path(path).stem and Path(path).stem not in {".", ""}
        }
    )
    return {
        "contractId": infer_contract_id(contract, engineer_contract, contract_path),
        "summary": summary,
        "tokens": tokens,
        "targetPaths": target_paths,
        "mentionedModules": mentioned_modules,
        "scopeTerms": sorted(tokenize_text(" ".join(scope_strings))),
        "riskHints": sorted(tokenize_text(" ".join(risk_strings))),
    }


def as_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [{"name": key, "value": item} for key, item in sorted(value.items())]
    if value is None:
        return []
    return [value]


def language_for_path(path: str | None) -> str | None:
    if not path:
        return None
    return LANGUAGE_BY_SUFFIX.get(Path(path).suffix)


def record_path(record: Any) -> str | None:
    if isinstance(record, dict):
        for key in ("path", "file", "modulePath", "resolvedPath"):
            value = record.get(key)
            if isinstance(value, str) and value:
                return value
        evidence = record.get("evidence")
        if isinstance(evidence, list):
            for item in evidence:
                if isinstance(item, str) and PATH_RE.search(item):
                    return item
        paths = record.get("paths")
        if isinstance(paths, list):
            for item in paths:
                if isinstance(item, str):
                    return item
    elif isinstance(record, str) and PATH_RE.search(record):
        return record
    return None


def record_symbol(record: Any) -> str | None:
    if not isinstance(record, dict):
        return None
    symbol = record.get("symbol")
    if isinstance(symbol, str) and symbol:
        return symbol
    if isinstance(symbol, dict):
        name = symbol.get("name")
        if isinstance(name, str) and name:
            return name
    name = record.get("name")
    if isinstance(name, str) and name and not PATH_RE.fullmatch(name):
        return name
    return None


def record_language(record: Any, path: str | None) -> str | None:
    if isinstance(record, dict):
        language = record.get("language")
        if isinstance(language, str) and language:
            return language
    return language_for_path(path)


def record_tokens(record: Any) -> set[str]:
    if isinstance(record, dict):
        tokens = record.get("tokens")
        if isinstance(tokens, list) and all(isinstance(item, str) for item in tokens):
            return {item.lower() for item in tokens if item.lower() not in STOPWORDS}
    return tokenize_text(" ".join(collect_strings(record)))


def usage_count(record: Any) -> int:
    if not isinstance(record, dict):
        return 0
    for key in ("usageCount", "importCount", "fanIn", "callsiteCount"):
        value = record.get(key)
        if isinstance(value, int):
            return value
    for key in ("importedBy", "callsites", "exampleCallsites"):
        value = record.get(key)
        if isinstance(value, list):
            return len(value)
    return 0


def record_callsites(record: Any) -> list[str]:
    if not isinstance(record, dict):
        return []
    values: list[str] = []
    for key in ("importedBy", "callsites", "exampleCallsites"):
        item = record.get(key)
        if isinstance(item, list):
            values.extend(str(value) for value in item if isinstance(value, str))
    source_path = record.get("path")
    resolved = record.get("resolvedPath")
    if isinstance(source_path, str) and isinstance(resolved, str) and source_path != resolved:
        values.append(source_path)
    return sorted(set(values))[:8]


def paired_tests(record: Any) -> list[str]:
    if not isinstance(record, dict):
        return []
    value = record.get("pairedTests")
    if isinstance(value, list):
        return sorted(str(item) for item in value if isinstance(item, str))
    return []


def has_shared_dir(path: str | None) -> bool:
    return bool(path and set(Path(path).parts) & SHARED_DIR_HINTS)


def is_test_path(path: str | None) -> bool:
    if not path:
        return False
    name = Path(path).name
    parts = set(Path(path).parts)
    return (
        "test" in parts
        or "tests" in parts
        or "testdata" in parts
        or name.startswith("test_")
        or name.endswith("_test.go")
        or name.endswith("_test.py")
        or name.endswith("_test.rs")
        or ".test." in name
        or ".spec." in name
    )


def add_draft(
    drafts: dict[tuple[str, str, str], dict[str, Any]],
    *,
    kind: str,
    path: str | None,
    symbol: str | None,
    language: str | None,
    source_artifact: str,
    source_section: str,
    record: Any,
    base_why: list[str] | None = None,
) -> None:
    if not path:
        return
    stable_path = path or ""
    stable_symbol = symbol or ""
    key = (kind, stable_path, stable_symbol)
    draft = drafts.setdefault(
        key,
        {
            "kind": kind,
            "path": stable_path,
            "symbol": symbol,
            "language": language,
            "source": {"artifact": source_artifact, "section": source_section},
            "sourceSections": [],
            "tokens": set(),
            "why": [],
            "exampleCallsites": [],
            "risks": [],
            "usageCount": 0,
            "pairedTests": [],
            "exported": False,
            "sharedDir": has_shared_dir(stable_path),
            "record": [],
        },
    )
    if language and not draft.get("language"):
        draft["language"] = language
    source_ref = f"{source_artifact}:{source_section}"
    if source_ref not in draft["sourceSections"]:
        draft["sourceSections"].append(source_ref)
    draft["tokens"].update(record_tokens(record))
    if path:
        draft["tokens"].update(tokenize_text(path))
    if symbol:
        draft["tokens"].update(tokenize_text(symbol))
    if base_why:
        for why in base_why:
            if why not in draft["why"]:
                draft["why"].append(why)
    draft["usageCount"] = max(int(draft.get("usageCount", 0)), usage_count(record))
    for callsite in record_callsites(record):
        if callsite not in draft["exampleCallsites"]:
            draft["exampleCallsites"].append(callsite)
    for test_path in paired_tests(record):
        if test_path not in draft["pairedTests"]:
            draft["pairedTests"].append(test_path)
    if isinstance(record, dict) and record.get("exported") is True:
        draft["exported"] = True
    if isinstance(record, dict) and "exported-symbols" in as_list(record.get("reasons")):
        draft["exported"] = True
    if isinstance(record, dict):
        for hint in as_list(record.get("boundaryHints")):
            if not isinstance(hint, dict):
                continue
            kind_value = str(hint.get("kind") or "")
            if kind_value == "go-internal":
                risk = "Go internal package boundary; verify the importing path is allowed before reuse."
                if risk not in draft["risks"]:
                    draft["risks"].append(risk)
            elif kind_value == "go-pkg":
                why = "pkg/ is a weak Go reusable package convention"
                if why not in draft["why"]:
                    draft["why"].append(why)
            elif kind_value == "go-cmd":
                risk = "Go cmd/ package is an executable entrypoint boundary, not a generic helper."
                if risk not in draft["risks"]:
                    draft["risks"].append(risk)
            elif kind_value == "rust-binary-crate-root":
                risk = "Rust binary src/main.rs is not a generic helper."
                if risk not in draft["risks"]:
                    draft["risks"].append(risk)
            elif kind_value == "rust-crate-local-visibility" and kind != "existing-helper":
                risk = "Rust module contains crate-local visibility; inspect symbol visibility before cross-crate reuse."
                if risk not in draft["risks"]:
                    draft["risks"].append(risk)
        boundary_risk = record.get("risk")
        if isinstance(boundary_risk, str) and boundary_risk and boundary_risk not in draft["risks"]:
            draft["risks"].append(boundary_risk)
        visibility = str(record.get("visibility") or "")
        record_language = str(record.get("language") or language or "")
        if record_language == "rust":
            if visibility.startswith("pub("):
                risk = "Rust crate-local visibility may not be reusable outside its crate"
                if risk not in draft["risks"]:
                    draft["risks"].append(risk)
            elif visibility == "private" and kind == "existing-helper":
                risk = "Rust private symbol is not reusable outside its module without changing visibility"
                if risk not in draft["risks"]:
                    draft["risks"].append(risk)
        for risk in as_list(record.get("visibilityRisks")):
            if kind == "existing-helper":
                continue
            if isinstance(risk, str) and risk and risk not in draft["risks"]:
                draft["risks"].append(risk)
    if (language == "rust" or stable_path.endswith(".rs")) and stable_path.endswith("/src/main.rs"):
        risk = "Rust binary src/main.rs is not a generic helper"
        if risk not in draft["risks"]:
            draft["risks"].append(risk)
    if kind == "duplicate-risk":
        reason = "similar or repeated code fingerprint reported by scanner"
        if reason not in draft["risks"]:
            draft["risks"].append(reason)
    draft["record"].append(record)


def shared_symbol_record(record: dict[str, Any], name: str) -> dict[str, Any]:
    symbol_record = dict(record)
    symbol_record["name"] = name
    symbol_record["tokens"] = split_identifier(name)
    symbol_record["symbols"] = [name]
    symbol_record.pop("visibilityRisks", None)
    symbol_record.pop("crateLocalSymbols", None)
    symbol_record["boundaryHints"] = [
        hint
        for hint in as_list(record.get("boundaryHints"))
        if not (isinstance(hint, dict) and hint.get("kind") == "rust-crate-local-visibility")
    ]
    return symbol_record


def build_drafts(codebase_index: dict[str, Any], style_profile: dict[str, Any]) -> dict[tuple[str, str, str], dict[str, Any]]:
    drafts: dict[tuple[str, str, str], dict[str, Any]] = {}

    for record in as_list(codebase_index.get("sharedCandidates")):
        path = record_path(record)
        language = record_language(record, path)
        reasons = ["scanner marked module as a shared candidate"]
        if isinstance(record, dict) and record.get("reasons"):
            reasons.extend(f"shared candidate reason: {reason}" for reason in as_list(record.get("reasons")))
        add_draft(
            drafts,
            kind="shared-module",
            path=path,
            symbol=None,
            language=language,
            source_artifact="codebase-index-v1.json",
            source_section="sharedCandidates",
            record=record,
            base_why=reasons,
        )
        if isinstance(record, dict):
            for symbol in as_list(record.get("symbols")):
                name = symbol if isinstance(symbol, str) else record_symbol(symbol)
                if not name:
                    continue
                add_draft(
                    drafts,
                    kind="existing-helper",
                    path=path,
                    symbol=name,
                    language=language,
                    source_artifact="codebase-index-v1.json",
                    source_section="sharedCandidates",
                    record=shared_symbol_record(record, name),
                    base_why=["symbol is exposed from a shared candidate module"],
                )

    for record in as_list(codebase_index.get("symbols")):
        path = record_path(record)
        if is_test_path(path):
            continue
        if isinstance(record, dict) and record.get("testOnly"):
            continue
        symbol = record_symbol(record)
        if not path and not symbol:
            continue
        why = ["exported symbol"] if isinstance(record, dict) and record.get("exported") else []
        add_draft(
            drafts,
            kind="existing-helper",
            path=path,
            symbol=symbol,
            language=record_language(record, path),
            source_artifact="codebase-index-v1.json",
            source_section="symbols",
            record=record,
            base_why=why,
        )

    for record in as_list(codebase_index.get("modules")):
        path = record_path(record)
        if not path:
            continue
        if isinstance(record, dict) and record.get("kind") == "test":
            continue
        add_draft(
            drafts,
            kind="module-boundary",
            path=path,
            symbol=None,
            language=record_language(record, path),
            source_artifact="codebase-index-v1.json",
            source_section="modules",
            record=record,
            base_why=["module is present in scanner index"],
        )

    for record in as_list(codebase_index.get("moduleBoundaries")):
        path = record_path(record)
        if not path:
            continue
        add_draft(
            drafts,
            kind="module-boundary",
            path=path,
            symbol=None,
            language=record_language(record, path),
            source_artifact="codebase-index-v1.json",
            source_section="moduleBoundaries",
            record=record,
            base_why=["scanner reported module boundary convention"],
        )

    for record in as_list(codebase_index.get("imports")):
        if not isinstance(record, dict):
            continue
        resolved = record.get("resolvedPath")
        if not isinstance(resolved, str) or not resolved:
            continue
        add_draft(
            drafts,
            kind="local-pattern",
            path=resolved,
            symbol=None,
            language=record_language(record, resolved),
            source_artifact="codebase-index-v1.json",
            source_section="imports",
            record=record,
            base_why=["referenced by local import"],
        )

    for record in as_list(codebase_index.get("tests")):
        path = record_path(record)
        if not path:
            continue
        add_draft(
            drafts,
            kind="test-pattern",
            path=path,
            symbol=None,
            language=record_language(record, path),
            source_artifact="codebase-index-v1.json",
            source_section="tests",
            record=record,
            base_why=["existing test file can guide verification style"],
        )

    conventions = codebase_index.get("conventions")
    if isinstance(conventions, dict):
        for section, value in sorted(conventions.items()):
            kind = "test-pattern" if "test" in section.lower() else "local-pattern"
            for item in as_list(value):
                path = item if isinstance(item, str) and PATH_RE.search(item) else record_path(item)
                add_draft(
                    drafts,
                    kind=kind,
                    path=path,
                    symbol=None,
                    language=record_language(item, path),
                    source_artifact="codebase-index-v1.json",
                    source_section=f"conventions.{section}",
                    record=item,
                    base_why=[f"scanner convention matched {section}"],
                )

    for record in as_list(codebase_index.get("duplicateFingerprints")):
        path = record_path(record)
        add_draft(
            drafts,
            kind="duplicate-risk",
            path=path,
            symbol=record_symbol(record),
            language=record_language(record, path),
            source_artifact="codebase-index-v1.json",
            source_section="duplicateFingerprints",
            record=record,
            base_why=["scanner reported duplicate pressure"],
        )

    for record in as_list(codebase_index.get("manifests")):
        path = record_path(record)
        add_draft(
            drafts,
            kind="config-pattern",
            path=path,
            symbol=None,
            language=record_language(record, path),
            source_artifact="codebase-index-v1.json",
            source_section="manifests",
            record=record,
            base_why=["manifest may define workspace or runtime conventions"],
        )

    style_sections = {
        "boundaries": "module-boundary",
        "testConventions": "test-pattern",
        "errorHandling": "error-handling-pattern",
        "logging": "local-pattern",
        "config": "config-pattern",
        "validation": "local-pattern",
    }
    for section, kind in style_sections.items():
        for record in as_list(style_profile.get(section)):
            path = record_path(record)
            add_draft(
                drafts,
                kind=kind,
                path=path,
                symbol=record_symbol(record),
                language=record_language(record, path),
                source_artifact="style-profile-v1.json",
                source_section=section,
                record=record,
                base_why=[f"style profile reports {section} convention"],
            )

    return drafts


def desired_languages(task_intent: dict[str, Any], codebase_index: dict[str, Any]) -> set[str]:
    languages: set[str] = set()
    for path in task_intent.get("targetPaths", []):
        language = language_for_path(str(path))
        if language:
            languages.add(language)
    token_map = {
        "javascript": "javascript",
        "cargo": "rust",
        "go": "go",
        "golang": "go",
        "js": "javascript",
        "py": "python",
        "python": "python",
        "rs": "rust",
        "rust": "rust",
        "ts": "typescript",
        "typescript": "typescript",
    }
    for token in task_intent.get("tokens", []):
        if token in token_map:
            languages.add(token_map[token])
    if not languages:
        for language in codebase_index.get("primaryLanguages", []):
            if isinstance(language, str):
                languages.add(language)
    return languages


def go_internal_allowed(candidate_path: str, target_paths: list[str]) -> bool | None:
    parts = Path(candidate_path).parts
    if "internal" not in parts:
        return None
    internal_index = parts.index("internal")
    allowed_root = "/".join(parts[:internal_index])
    if not target_paths:
        return None
    if not allowed_root:
        return True
    for target in target_paths:
        normalized = str(target).strip("/")
        if normalized == allowed_root or normalized.startswith(f"{allowed_root}/"):
            return True
    return False


def validation_domain_overlap(intent_tokens: set[str], candidate_tokens: set[str]) -> list[str]:
    return sorted((intent_tokens & candidate_tokens) - VALIDATION_TOKENS - GENERIC_DOMAIN_TOKENS)


def validation_symbol_tokens(draft: dict[str, Any], symbol_text: str, candidate_tokens: set[str]) -> set[str]:
    tokens = tokenize_text(symbol_text)
    if tokens:
        if tokens & VALIDATION_TOKENS:
            return tokens
        if candidate_tokens & VALIDATION_TOKENS:
            return tokens | (candidate_tokens & VALIDATION_TOKENS)
        return set()

    helper_tokens: set[str] = set()
    for record in draft.get("record", []):
        if not isinstance(record, dict):
            continue
        for symbol in as_list(record.get("symbols")):
            name = symbol if isinstance(symbol, str) else record_symbol(symbol)
            symbol_tokens = tokenize_text(name or "")
            if symbol_tokens & VALIDATION_TOKENS:
                helper_tokens.update(symbol_tokens)
    if helper_tokens:
        return helper_tokens
    if candidate_tokens & VALIDATION_TOKENS:
        return candidate_tokens
    return set()


def score_draft(draft: dict[str, Any], task_intent: dict[str, Any], languages: set[str]) -> dict[str, Any] | None:
    intent_tokens = set(task_intent.get("tokens", []))
    target_paths = [str(path) for path in task_intent.get("targetPaths", [])]
    path = str(draft.get("path") or "")
    symbol = draft.get("symbol")
    symbol_text = str(symbol or "")
    candidate_tokens = set(draft.get("tokens", set()))
    candidate_tokens.update(tokenize_text(path))
    candidate_tokens.update(tokenize_text(symbol_text))

    score = 0.05
    confidence = 0.32
    why: list[str] = []
    risks = [str(risk) for risk in draft.get("risks", []) if risk]
    kind = str(draft.get("kind"))
    for item in draft.get("why", []):
        if item and item not in why:
            why.append(str(item))

    overlap = sorted(intent_tokens & candidate_tokens)
    if overlap:
        shown = ",".join(overlap[:6])
        why.insert(0, f"contract terms matched candidate: {shown}")
        score += min(0.34, 0.055 * len(overlap))
        confidence += min(0.18, 0.03 * len(overlap))

    symbol_overlap = sorted(intent_tokens & tokenize_text(symbol_text))
    if symbol_overlap:
        why.insert(0, f"contract terms matched symbol: {','.join(symbol_overlap[:6])}")
        score += min(0.22, 0.075 * len(symbol_overlap))
        confidence += min(0.16, 0.045 * len(symbol_overlap))

    path_overlap = sorted(intent_tokens & tokenize_text(path))
    if path_overlap:
        score += min(0.12, 0.03 * len(path_overlap))
        confidence += min(0.08, 0.02 * len(path_overlap))

    for target in target_paths:
        if not path:
            continue
        target_parent = Path(target).parent.as_posix()
        path_parent = Path(path).parent.as_posix()
        if path == target or (target_parent and target_parent == path_parent):
            why.append("near contract target path")
            score += 0.12
            confidence += 0.08
            break
        if set(Path(target).parts) & set(Path(path).parts):
            score += 0.04
            confidence += 0.02
            break

    usage = int(draft.get("usageCount", 0))
    if usage > 0:
        if usage > 1:
            why.append("imported by multiple files")
        else:
            why.append("imported by local code")
        score += min(0.12, 0.035 * usage)
        confidence += min(0.1, 0.025 * usage)

    if draft.get("exported"):
        if "exported symbol" not in why:
            why.append("exported symbol")
        score += 0.08
        confidence += 0.05

    if draft.get("pairedTests"):
        why.append("paired test exists")
        score += 0.07
        confidence += 0.06

    if draft.get("sharedDir"):
        why.append("shared/common directory hint")
        score += 0.03
        confidence += 0.015

    validation_tokens = validation_symbol_tokens(draft, symbol_text, candidate_tokens)
    if kind in {"existing-helper", "shared-module"} and (intent_tokens & VALIDATION_TOKENS) and validation_tokens:
        why.append("validation helper signal")
        domain_overlap = validation_domain_overlap(intent_tokens, validation_tokens)
        if domain_overlap:
            why.append(f"domain terms matched validation helper: {','.join(domain_overlap[:6])}")
            score += 0.12 + min(0.12, 0.06 * len(domain_overlap))
            confidence += 0.06 + min(0.06, 0.03 * len(domain_overlap))
        else:
            score += 0.08
            confidence += 0.04

    internal_allowed = go_internal_allowed(path, target_paths)
    if internal_allowed is True:
        why.append("within Go internal package boundary")
        confidence += 0.02
    elif internal_allowed is False:
        risks.append("Go internal package boundary may reject imports from the contract target path.")
        score -= 0.08
        confidence -= 0.04

    if kind in {"test-pattern", "error-handling-pattern", "config-pattern", "local-pattern"}:
        score += 0.08
        confidence += 0.05
    if kind == "duplicate-risk":
        score += 0.1
        confidence += 0.04
    if kind == "module-boundary":
        score += 0.03

    language = draft.get("language")
    if isinstance(language, str) and language in languages:
        why.append(f"language matches task context: {language}")
        score += 0.05
        confidence += 0.04

    generic_only = not overlap and not symbol_overlap and not target_paths and kind not in {
        "test-pattern",
        "error-handling-pattern",
        "config-pattern",
        "duplicate-risk",
    }
    if generic_only and score < 0.24:
        return None
    if not why:
        return None

    normalized_score = min(0.99, score)
    normalized_confidence = min(0.99, max(0.1, confidence + min(0.08, 0.015 * len(why))))
    return {
        "kind": kind,
        "language": language,
        "path": path,
        "symbol": symbol if symbol else None,
        "score": round(normalized_score, 4),
        "confidence": round(normalized_confidence, 4),
        "whyRelevant": dedupe_preserve_order(why),
        "suggestedAction": SUGGESTED_ACTION_BY_KIND.get(kind, "inspect-before-editing"),
        "exampleCallsites": sorted(set(draft.get("exampleCallsites", [])))[:8],
        "risks": sorted(set(risks))[:8],
        "source": draft.get("source"),
    }


def dedupe_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


def sort_candidates(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        candidates,
        key=lambda item: (
            -float(item.get("score", 0.0)),
            -float(item.get("confidence", 0.0)),
            str(item.get("kind") or ""),
            str(item.get("path") or ""),
            str(item.get("symbol") or ""),
        ),
    )


def assign_candidate_ids(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    assigned = []
    for index, candidate in enumerate(candidates, start=1):
        item = {"candidateId": f"cand-{index:03d}"}
        item.update(candidate)
        assigned.append(item)
    return assigned


def summarize_convention(record: Any) -> str:
    if isinstance(record, dict):
        name = str(record.get("name") or "convention")
        value = str(record.get("value") or record.get("kind") or "")
        language = str(record.get("language") or "").strip()
        evidence = record.get("evidence")
        evidence_text = ""
        if isinstance(evidence, list) and evidence:
            evidence_text = f" ({', '.join(str(item) for item in evidence[:3])})"
        prefix = f"{language} " if language else ""
        return f"{prefix}{name}: {value}{evidence_text}".strip()
    return str(record)


def dominant_conventions(style_profile: dict[str, Any]) -> dict[str, list[str]]:
    return {
        "tests": [summarize_convention(item) for item in as_list(style_profile.get("testConventions"))][:6],
        "errorHandling": [summarize_convention(item) for item in as_list(style_profile.get("errorHandling"))][:6],
        "logging": [summarize_convention(item) for item in as_list(style_profile.get("logging"))][:6],
        "config": [summarize_convention(item) for item in as_list(style_profile.get("config"))][:6],
        "validation": [summarize_convention(item) for item in as_list(style_profile.get("validation"))][:6],
        "go": [summarize_convention(item) for item in as_list(style_profile.get("goConventions"))][:6],
    }


def target_areas(task_intent: dict[str, Any], candidates: list[dict[str, Any]]) -> list[str]:
    areas: set[str] = set()
    for path in task_intent.get("targetPaths", []):
        parent = Path(str(path)).parent.as_posix()
        areas.add(parent if parent != "." else str(path))
    for candidate in candidates[:5]:
        path = str(candidate.get("path") or "")
        if not path:
            continue
        parent = Path(path).parent.as_posix()
        areas.add(parent if parent != "." else path)
    return sorted(area for area in areas if area)


def nearby_modules(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    nearby = []
    for candidate in candidates:
        if candidate.get("kind") not in {"existing-helper", "shared-module", "module-boundary", "local-pattern"}:
            continue
        nearby.append(
            {
                "kind": candidate.get("kind"),
                "path": candidate.get("path"),
                "symbol": candidate.get("symbol"),
                "score": candidate.get("score"),
            }
        )
        if len(nearby) >= 8:
            break
    return nearby


def module_boundaries(candidates: list[dict[str, Any]], codebase_index: dict[str, Any]) -> list[dict[str, Any]]:
    boundaries = []
    seen: set[tuple[str, str]] = set()
    for candidate in candidates:
        if candidate.get("kind") != "module-boundary":
            continue
        key = (str(candidate.get("path") or ""), "")
        seen.add(key)
        boundaries.append(
            {
                "path": candidate.get("path"),
                "language": candidate.get("language"),
                "score": candidate.get("score"),
                "whyRelevant": candidate.get("whyRelevant", [])[:3],
            }
        )
        if len(boundaries) >= 6:
            return boundaries
    for record in as_list(codebase_index.get("moduleBoundaries")):
        if not isinstance(record, dict):
            continue
        path = str(record.get("path") or "")
        kind = str(record.get("kind") or "")
        key = (path, kind)
        if not path or key in seen:
            continue
        seen.add(key)
        entry = {
            "path": path,
            "language": record.get("language"),
            "kind": kind,
            "whyRelevant": [str(record.get("value") or kind)],
        }
        if "weak" in record:
            entry["weak"] = record.get("weak")
        boundaries.append(entry)
        if len(boundaries) >= 6:
            break
    return boundaries


def candidate_summary(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    counts = Counter(str(candidate.get("kind")) for candidate in candidates)
    return {
        "total": len(candidates),
        "byKind": {kind: counts[kind] for kind in sorted(counts)},
    }


def primary_languages(codebase_index: dict[str, Any], style_profile: dict[str, Any]) -> list[str]:
    for source in (style_profile, codebase_index):
        values = source.get("primaryLanguages")
        if isinstance(values, list):
            return [str(value) for value in values if isinstance(value, str)]
    modules = as_list(codebase_index.get("modules"))
    counts = Counter(
        str(module.get("language"))
        for module in modules
        if isinstance(module, dict) and isinstance(module.get("language"), str)
    )
    return [language for language, _count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))]


def build_outputs(
    *,
    args: argparse.Namespace,
    project_root: Path,
    generated_at: str,
    task_intent: dict[str, Any],
    codebase_index: dict[str, Any],
    style_profile: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    drafts = build_drafts(codebase_index, style_profile)
    languages = desired_languages(task_intent, codebase_index)
    scored = []
    for draft in drafts.values():
        candidate = score_draft(draft, task_intent, languages)
        if candidate:
            scored.append(candidate)
    sorted_candidates = sort_candidates(scored)
    max_candidates = max(0, int(args.max_candidates))
    candidates = assign_candidate_ids(sorted_candidates[:max_candidates])

    notes = ["PR1B matcher output is manual and not wired into EXECUTE."]
    if not candidates:
        notes.append("No reuse candidates exceeded the deterministic matcher threshold.")
    elif float(candidates[0].get("confidence", 0.0)) < 0.5:
        notes.append("Top candidate confidence is low; inspect candidates before editing.")
    if not style_profile:
        notes.append("Style profile was unavailable or empty; convention context is sparse.")
    if not codebase_index:
        notes.append("Codebase index was unavailable or empty; reuse context is sparse.")

    reuse_candidates = {
        "schemaVersion": "1.0",
        "contractId": task_intent.get("contractId") or "unknown",
        "generatedAt": generated_at,
        "maxCandidates": max_candidates,
        "candidateCount": len(candidates),
        "taskIntent": {
            "summary": task_intent.get("summary", ""),
            "tokens": task_intent.get("tokens", []),
            "targetPaths": task_intent.get("targetPaths", []),
            "mentionedModules": task_intent.get("mentionedModules", []),
            "riskHints": task_intent.get("riskHints", []),
        },
        "candidates": candidates,
    }

    implementation_context = {
        "schemaVersion": "1.0",
        "contractId": task_intent.get("contractId") or "unknown",
        "generatedAt": generated_at,
        "projectRoot": portable_project_root(args.project_root),
        "codebaseIndexPath": portable_cli_path(args.codebase_index, project_root),
        "styleProfilePath": portable_cli_path(args.style_profile, project_root),
        "goalSummary": task_intent.get("summary", ""),
        "primaryLanguages": primary_languages(codebase_index, style_profile),
        "targetAreas": target_areas(task_intent, candidates),
        "nearbyModules": nearby_modules(candidates),
        "dominantConventions": dominant_conventions(style_profile),
        "moduleBoundaries": module_boundaries(candidates, codebase_index),
        "candidateSummary": candidate_summary(candidates),
        "notes": notes,
    }
    return reuse_candidates, implementation_context


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    project_root = Path(args.project_root).resolve()
    generated_at = args.generated_at or utc_now()
    contract_path = project_root / args.contract
    engineer_path = project_root / args.contract_engineer if args.contract_engineer else None
    codebase_index_path = project_root / args.codebase_index
    style_profile_path = project_root / args.style_profile

    contract = load_json(contract_path, "contract")
    engineer_contract = load_json(engineer_path, "contract-engineer") if engineer_path else {}
    codebase_index = load_json(codebase_index_path, "codebase-index")
    style_profile = load_json(style_profile_path, "style-profile")
    task_intent = extract_task_intent(contract, engineer_contract, contract_path)
    reuse_candidates, implementation_context = build_outputs(
        args=args,
        project_root=project_root,
        generated_at=generated_at,
        task_intent=task_intent,
        codebase_index=codebase_index,
        style_profile=style_profile,
    )
    write_json(project_root / args.output, reuse_candidates)
    write_json(project_root / args.implementation_context, implementation_context)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
