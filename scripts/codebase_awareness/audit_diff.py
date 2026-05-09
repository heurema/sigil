#!/usr/bin/env python3
"""Manual post-diff reuse and duplicate audit for Codebase Awareness."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

EXIT_OK = 0
EXIT_MISSING_INPUT = 2
EXIT_INVALID_JSON = 3
EXIT_INVALID_INPUT = 4
EXIT_INFRA = 5

SCHEMA_VERSION = "1.0"
SEVERITIES = ("critical", "major", "minor", "info")
SEVERITY_RANK = {"critical": 4, "major": 3, "minor": 2, "info": 1}
RECOMMENDED_OUTCOMES = {"clean", "informational", "review-recommended"}

ACCEPTED_MODES = {"off", "hint", "warn", "gate"}
POSITIVE_DISPOSITIONS = {"reuse", "adapt", "follow-pattern", "respect-boundary"}
ADDRESSED_DISPOSITIONS = POSITIVE_DISPOSITIONS | {"reject", "defer", "inspect-only"}
HELPER_CANDIDATE_KINDS = {"existing-helper", "shared-module"}

STOPWORDS = {
    "a",
    "an",
    "and",
    "are",
    "as",
    "at",
    "be",
    "by",
    "const",
    "def",
    "else",
    "export",
    "false",
    "for",
    "from",
    "function",
    "if",
    "import",
    "in",
    "is",
    "it",
    "let",
    "new",
    "not",
    "of",
    "or",
    "return",
    "src",
    "test",
    "tests",
    "the",
    "this",
    "to",
    "true",
    "type",
    "var",
    "with",
}

HELPER_PATTERNS = (
    re.compile(r"\b(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\b"),
    re.compile(r"\bdef\s+([A-Za-z_][\w]*)\s*\("),
    re.compile(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"),
    re.compile(r"\b(?:export\s+)?class\s+([A-Za-z_$][\w$]*)\b"),
)


@dataclass(frozen=True)
class AddedBlock:
    path: str
    hunk: int
    lines: tuple[str, ...]
    tokens: frozenset[str]
    helper_names: tuple[str, ...]

    @property
    def text(self) -> str:
        return "\n".join(self.lines)


class AuditError(Exception):
    def __init__(self, exit_code: int, message: str) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.message = message


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit a Signum patch for reuse and duplicate risk.")
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--contract", required=True)
    parser.add_argument("--patch", required=True)
    parser.add_argument("--codebase-index", required=True)
    parser.add_argument("--reuse-candidates", required=True)
    parser.add_argument("--reuse-decision", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--style-profile", default=None)
    parser.add_argument("--implementation-context", default=None)
    parser.add_argument("--generated-at", default=None)
    return parser.parse_args(argv)


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def split_identifier(value: str) -> list[str]:
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", value)
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", value)
    parts = [part.lower() for part in re.split(r"[^A-Za-z0-9]+", value) if part]
    expanded: list[str] = []
    for part in parts:
        if part in STOPWORDS or len(part) < 2:
            continue
        expanded.append(part)
        if part.startswith("valid"):
            expanded.append("valid")
        if part.startswith("normal"):
            expanded.append("normal")
    return expanded


def tokenize_text(value: str) -> set[str]:
    return set(split_identifier(value))


def non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def resolve_input(project_root: Path, value: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return project_root / path


def portable_path(path_arg: str | None, project_root: Path) -> str | None:
    if not path_arg:
        return None
    path = Path(path_arg)
    if not path.is_absolute():
        return path.as_posix()
    try:
        return path.resolve().relative_to(project_root.resolve()).as_posix()
    except ValueError:
        return path.name


def load_required_json(path: Path, label: str) -> Any:
    if not path.is_file():
        raise AuditError(EXIT_MISSING_INPUT, f"Required {label} file not found: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise AuditError(EXIT_INVALID_JSON, f"Invalid {label} JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise AuditError(EXIT_INFRA, f"Unable to read {label} JSON {path}: {exc}") from exc


def read_required_text(path: Path, label: str) -> str:
    if not path.is_file():
        raise AuditError(EXIT_MISSING_INPUT, f"Required {label} file not found: {path}")
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise AuditError(EXIT_INFRA, f"Unable to read {label} {path}: {exc}") from exc
    if b"\0" in data[:4096]:
        raise AuditError(EXIT_INVALID_INPUT, f"Unsupported binary {label}: {path}")
    return data.decode("utf-8", errors="replace")


def optional_json(project_root: Path, value: str | None, label: str) -> Any:
    if not value:
        return {}
    path = resolve_input(project_root, value)
    return load_required_json(path, label)


def is_comment_or_empty(line: str) -> bool:
    stripped = line.strip()
    return (
        not stripped
        or stripped.startswith("//")
        or stripped.startswith("#")
        or stripped.startswith("/*")
        or stripped.startswith("*")
        or stripped.startswith("*/")
    )


def extract_helper_names(lines: list[str]) -> tuple[str, ...]:
    text = "\n".join(lines)
    names: set[str] = set()
    for pattern in HELPER_PATTERNS:
        for match in pattern.finditer(text):
            names.add(match.group(1))
    return tuple(sorted(names))


def parse_git_path(line: str) -> str | None:
    parts = line.split()
    if len(parts) >= 4:
        candidate = parts[3]
        if candidate.startswith("b/"):
            return candidate[2:]
    return None


def parse_plus_path(line: str) -> str | None:
    value = line[4:].strip()
    if value == "/dev/null":
        return None
    if value.startswith("b/"):
        return value[2:]
    return value


def parse_patch(text: str) -> tuple[list[str], int, list[AddedBlock]]:
    if text.strip() and "diff --git " not in text and "@@" not in text:
        raise AuditError(EXIT_INVALID_INPUT, "Patch does not look like a unified diff")

    changed_files: set[str] = set()
    blocks: list[AddedBlock] = []
    current_path: str | None = None
    hunk = 0
    added_lines: list[str] = []
    added_line_count = 0

    def flush() -> None:
        nonlocal added_lines
        if not current_path or not added_lines:
            added_lines = []
            return
        tokens = tokenize_text("\n".join(added_lines))
        helper_names = extract_helper_names(added_lines)
        blocks.append(
            AddedBlock(
                path=current_path,
                hunk=hunk,
                lines=tuple(added_lines),
                tokens=frozenset(tokens),
                helper_names=helper_names,
            )
        )
        added_lines = []

    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            flush()
            current_path = parse_git_path(raw)
            if current_path:
                changed_files.add(current_path)
            hunk = 0
            continue
        if raw.startswith("+++ "):
            parsed = parse_plus_path(raw)
            if parsed:
                current_path = parsed
                changed_files.add(parsed)
            continue
        if raw.startswith("@@"):
            flush()
            hunk += 1
            continue
        if raw.startswith("Binary files ") or raw.startswith("GIT binary patch"):
            flush()
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            content = raw[1:]
            if is_comment_or_empty(content):
                continue
            added_line_count += 1
            added_lines.append(content)

    flush()
    return sorted(changed_files), added_line_count, blocks


def contract_id_from(contract: Any, reuse_candidates: Any, reuse_decision: Any) -> str:
    for document in (contract, reuse_candidates, reuse_decision):
        if isinstance(document, dict):
            for key in ("contractId", "id", "runId"):
                value = document.get(key)
                if non_empty_string(value) and value != "unknown":
                    return str(value)
    return "unknown"


def as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def load_reuse_decision(path: Path, mode: str) -> tuple[dict[str, Any], dict[str, Any]]:
    if not path.is_file():
        if mode == "gate":
            raise AuditError(EXIT_MISSING_INPUT, f"Required reuse-decision file not found in gate mode: {path}")
        note = "reuse_decision.json missing; scan ran in degraded decision-unaware mode"
        return {}, {"present": False, "valid": False, "mode": mode, "entries": 0, "notes": [note]}

    try:
        decision = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise AuditError(EXIT_INVALID_JSON, f"Invalid reuse-decision JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise AuditError(EXIT_INFRA, f"Unable to read reuse-decision JSON {path}: {exc}") from exc

    if not isinstance(decision, dict):
        raise AuditError(EXIT_INVALID_INPUT, "reuse-decision JSON must be a top-level object")

    decisions = decision.get("decisions")
    entries = len(decisions) if isinstance(decisions, list) else 0
    return decision, {"present": True, "valid": True, "mode": mode, "entries": entries, "notes": []}


def candidate_score(candidate: dict[str, Any]) -> float:
    values = []
    for key in ("score", "confidence"):
        value = candidate.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return max(values) if values else 0.0


def candidate_tokens(candidate: dict[str, Any]) -> set[str]:
    tokens: set[str] = set()
    for field in ("candidateId", "kind", "path", "symbol", "suggestedAction"):
        value = candidate.get(field)
        if isinstance(value, str):
            tokens.update(tokenize_text(value))
    raw_tokens = candidate.get("tokens")
    if isinstance(raw_tokens, list):
        tokens.update(str(token).lower() for token in raw_tokens if isinstance(token, str))
    for item in as_list(candidate.get("whyRelevant")):
        if isinstance(item, str):
            tokens.update(tokenize_text(item))
    return {token for token in tokens if token not in STOPWORDS}


def build_decision_map(reuse_decision: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in as_list(reuse_decision.get("decisions")):
        if not isinstance(item, dict):
            continue
        candidate_id = item.get("candidateId")
        if non_empty_string(candidate_id):
            result[str(candidate_id)] = item
    return result


def decision_fields(candidate_ids: list[str], decisions: dict[str, dict[str, Any]]) -> dict[str, Any]:
    addressed = False
    disposition: str | None = None
    rationale_present = False
    for candidate_id in candidate_ids:
        decision = decisions.get(candidate_id)
        if not decision:
            continue
        disposition_value = decision.get("disposition")
        addressed = disposition_value in ADDRESSED_DISPOSITIONS
        disposition = str(disposition_value) if disposition_value is not None else None
        rationale_present = non_empty_string(decision.get("rationale"))
        break
    return {
        "decisionAddressed": addressed,
        "decisionDisposition": disposition,
        "decisionRationalePresent": rationale_present,
    }


def token_overlap(left: set[str], right: set[str]) -> float:
    if not left or not right:
        return 0.0
    intersection = len(left & right)
    union = len(left | right)
    overlap = intersection / min(len(left), len(right))
    jaccard = intersection / union
    return round(min(1.0, (0.65 * overlap) + (0.35 * jaccard)), 4)


def round_score(value: float) -> float:
    return round(max(0.0, min(1.0, value)), 4)


def adjusted_severity(base: str, candidate_ids: list[str], decisions: dict[str, dict[str, Any]]) -> str:
    fields = decision_fields(candidate_ids, decisions)
    if not fields["decisionAddressed"]:
        return base
    disposition = fields["decisionDisposition"]
    if disposition in POSITIVE_DISPOSITIONS:
        return "info"
    if base == "major":
        return "minor"
    return base


def candidate_match(candidate: dict[str, Any]) -> dict[str, Any]:
    match = {
        "candidateId": candidate.get("candidateId"),
        "path": candidate.get("path"),
    }
    symbol = candidate.get("symbol")
    if non_empty_string(symbol):
        match["symbol"] = symbol
    return {key: value for key, value in match.items() if value is not None}


def index_records(codebase_index: dict[str, Any]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for item in as_list(codebase_index.get("sharedCandidates")):
        if not isinstance(item, dict):
            continue
        tokens = set(str(token).lower() for token in as_list(item.get("tokens")) if isinstance(token, str))
        tokens.update(tokenize_text(str(item.get("path", ""))))
        for symbol in as_list(item.get("symbols")):
            if isinstance(symbol, str):
                tokens.update(tokenize_text(symbol))
        records.append(
            {
                "source": "sharedCandidates",
                "path": item.get("path"),
                "symbol": ", ".join(str(symbol) for symbol in as_list(item.get("symbols")) if isinstance(symbol, str)),
                "tokens": tokens,
            }
        )
    for item in as_list(codebase_index.get("symbols")):
        if not isinstance(item, dict):
            continue
        tokens = set(str(token).lower() for token in as_list(item.get("tokens")) if isinstance(token, str))
        tokens.update(tokenize_text(str(item.get("path", ""))))
        tokens.update(tokenize_text(str(item.get("name", ""))))
        records.append(
            {
                "source": "symbols",
                "path": item.get("path"),
                "symbol": item.get("name"),
                "tokens": tokens,
            }
        )
    for item in as_list(codebase_index.get("duplicateFingerprints")):
        if not isinstance(item, dict):
            continue
        tokens = tokenize_text(str(item.get("symbol", "")))
        records.append(
            {
                "source": "duplicateFingerprints",
                "path": ", ".join(str(path) for path in as_list(item.get("paths")) if isinstance(path, str)),
                "symbol": item.get("symbol"),
                "tokens": tokens,
            }
        )
    return records


def helper_reinvention_findings(
    blocks: list[AddedBlock],
    candidates: list[dict[str, Any]],
    decisions: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for block in blocks:
        if not block.helper_names:
            continue
        helper_tokens = tokenize_text(" ".join(block.helper_names))
        path_tokens = tokenize_text(block.path)
        for candidate in candidates:
            if candidate.get("kind") not in HELPER_CANDIDATE_KINDS:
                continue
            candidate_id = str(candidate.get("candidateId", ""))
            if not candidate_id:
                continue
            tokens = candidate_tokens(candidate)
            code_tokens = set(block.tokens) - helper_tokens
            overlap = token_overlap(set(block.tokens) | helper_tokens, tokens)
            body_overlap = token_overlap(code_tokens, tokens)
            symbol_tokens = tokenize_text(str(candidate.get("symbol", "")))
            symbol_match = bool((helper_tokens | set(block.tokens)) & symbol_tokens)
            path_overlap = bool(path_tokens & tokenize_text(str(candidate.get("path", ""))))
            high_confidence = candidate_score(candidate) >= 0.5
            if not ((symbol_match and overlap >= 0.12) or overlap >= 0.28):
                continue

            strong_body_overlap = body_overlap >= 0.08
            axes = sum(
                (
                    strong_body_overlap,
                    symbol_match and strong_body_overlap,
                    high_confidence and strong_body_overlap,
                    candidate_id not in decisions and strong_body_overlap,
                )
            )
            base_severity = "major" if axes >= 2 else "minor"
            severity = adjusted_severity(base_severity, [candidate_id], decisions)
            why = []
            if symbol_match:
                why.append("added helper tokens overlap existing candidate symbol")
            if strong_body_overlap:
                why.append("added helper body tokens overlap existing candidate")
            elif overlap >= 0.28:
                why.append("added helper block has strong token overlap with candidate")
            else:
                why.append("added helper block has token overlap with candidate")
            if high_confidence:
                why.append("candidate is high-confidence existing reusable code")
            if path_overlap:
                why.append("changed path overlaps candidate domain tokens")
            if candidate_id not in decisions:
                why.append("reuse_decision does not address candidate")
            else:
                why.append("reuse_decision addresses candidate")
            candidate_ids = [candidate_id]
            finding = {
                "kind": "new-helper-similar-to-existing-candidate",
                "severity": severity,
                "path": block.path,
                "candidateIds": candidate_ids,
                "score": round_score(max(overlap, candidate_score(candidate))),
                "why": why,
                "matches": [candidate_match(candidate)],
                **decision_fields(candidate_ids, decisions),
                "recommendedAction": "reuse-existing-or-justify",
            }
            findings.append(finding)
    return findings


def added_block_overlap_findings(
    blocks: list[AddedBlock],
    codebase_index: dict[str, Any],
    decisions: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    records = index_records(codebase_index)
    for block in blocks:
        if not block.tokens:
            continue
        best_record: dict[str, Any] | None = None
        best_score = 0.0
        for record in records:
            if record.get("path") == block.path:
                continue
            score = token_overlap(set(block.tokens), set(record.get("tokens", set())))
            if score > best_score:
                best_score = score
                best_record = record
        if best_record is None or best_score < 0.34:
            continue
        finding = {
            "kind": "added-block-token-overlap",
            "severity": "minor",
            "path": block.path,
            "candidateIds": [],
            "score": round_score(best_score),
            "why": [
                "added block tokens overlap existing indexed code",
                f"overlap source: {best_record.get('source')}",
            ],
            "matches": [
                {
                    key: value
                    for key, value in {
                        "path": best_record.get("path"),
                        "symbol": best_record.get("symbol"),
                        "source": best_record.get("source"),
                    }.items()
                    if value
                }
            ],
            **decision_fields([], decisions),
            "recommendedAction": "inspect-overlap-before-merge",
        }
        findings.append(finding)
    return findings


def unaddressed_candidate_findings(
    blocks: list[AddedBlock],
    candidates: list[dict[str, Any]],
    decisions: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    added_tokens = set().union(*(set(block.tokens) | tokenize_text(block.path) for block in blocks)) if blocks else set()
    for candidate in candidates:
        candidate_id = str(candidate.get("candidateId", ""))
        if not candidate_id or candidate_id in decisions or candidate_score(candidate) < 0.65:
            continue
        tokens = candidate_tokens(candidate)
        score = token_overlap(added_tokens, tokens)
        if score < 0.22:
            continue
        findings.append(
            {
                "kind": "unaddressed-high-confidence-candidate",
                "severity": "info",
                "path": str(candidate.get("path") or ""),
                "candidateIds": [candidate_id],
                "score": round_score(score),
                "why": [
                    "high-confidence candidate overlaps changed code tokens",
                    "reuse_decision does not address candidate",
                ],
                "matches": [candidate_match(candidate)],
                **decision_fields([candidate_id], decisions),
                "recommendedAction": "address-candidate-or-document-rationale",
            }
        )
    return findings


def style_values(style_profile: dict[str, Any], key: str) -> list[str]:
    result: list[str] = []
    for item in as_list(style_profile.get(key)):
        if isinstance(item, str):
            result.append(item)
        elif isinstance(item, dict):
            for value in item.values():
                if isinstance(value, str):
                    result.append(value)
                elif isinstance(value, list):
                    result.extend(str(entry) for entry in value if isinstance(entry, str))
    return result


def is_test_path(path: str) -> bool:
    name = Path(path).name
    parts = set(Path(path).parts)
    return "test" in parts or "tests" in parts or name.startswith("test_") or name.endswith("_test.py") or ".test." in name or ".spec." in name


def convention_drift_findings(
    changed_files: list[str],
    style_profile: dict[str, Any],
    implementation_context: dict[str, Any],
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    test_conventions = " ".join(style_values(style_profile, "testConventions")).lower()
    context_conventions = json.dumps(implementation_context.get("dominantConventions", {}), sort_keys=True).lower()
    convention_text = f"{test_conventions} {context_conventions}"
    if not convention_text.strip():
        return findings
    dominant_uses_test_suffix = "*.test.*" in convention_text or ".test." in convention_text
    dominant_tests_dir = "tests/" in convention_text or "tests" in convention_text
    for path in changed_files:
        if not is_test_path(path):
            continue
        why: list[str] = []
        if dominant_uses_test_suffix and ".spec." in Path(path).name:
            why.append("patch adds .spec. test while dominant convention uses .test.")
        if dominant_tests_dir and "tests" not in Path(path).parts:
            why.append("patch adds test outside dominant tests directory")
        if not why:
            continue
        findings.append(
            {
                "kind": "possible-convention-drift",
                "severity": "info",
                "path": path,
                "candidateIds": [],
                "score": 0.5,
                "why": why,
                "matches": [],
                "decisionAddressed": False,
                "decisionDisposition": None,
                "decisionRationalePresent": False,
                "recommendedAction": "follow-existing-convention-or-justify",
            }
        )
    return findings


def dedupe_findings(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deduped: dict[tuple[Any, ...], dict[str, Any]] = {}
    for finding in findings:
        candidate_ids = tuple(finding.get("candidateIds") or [])
        key = (finding.get("kind"), finding.get("path"), candidate_ids)
        current = deduped.get(key)
        if current is None:
            deduped[key] = finding
            continue
        if float(finding.get("score", 0.0)) > float(current.get("score", 0.0)):
            deduped[key] = finding
    return list(deduped.values())


def sort_and_number_findings(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    sorted_findings = sorted(
        findings,
        key=lambda item: (
            -SEVERITY_RANK.get(str(item.get("severity")), 0),
            -float(item.get("score", 0.0)),
            str(item.get("kind", "")),
            str(item.get("path", "")),
            str((item.get("candidateIds") or [""])[0]),
        ),
    )
    for index, finding in enumerate(sorted_findings, start=1):
        finding["findingId"] = f"dup-{index:03d}"
    return sorted_findings


def summary_counts(findings: list[dict[str, Any]]) -> dict[str, int]:
    counter = Counter(str(finding.get("severity")) for finding in findings)
    result = {severity: counter.get(severity, 0) for severity in SEVERITIES}
    result["total"] = len(findings)
    return result


def recommended_outcome(counts: dict[str, int]) -> str:
    if counts.get("total", 0) == 0:
        return "clean"
    if counts.get("critical", 0) or counts.get("major", 0):
        return "review-recommended"
    return "informational"


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    project_root = Path(args.project_root).resolve()
    generated_at = args.generated_at or utc_now()
    if args.mode not in ACCEPTED_MODES:
        raise AuditError(EXIT_INVALID_INPUT, f"mode must be one of {', '.join(sorted(ACCEPTED_MODES))}")

    contract_path = resolve_input(project_root, args.contract)
    patch_path = resolve_input(project_root, args.patch)
    index_path = resolve_input(project_root, args.codebase_index)
    candidates_path = resolve_input(project_root, args.reuse_candidates)
    decision_path = resolve_input(project_root, args.reuse_decision)

    contract = load_required_json(contract_path, "contract")
    patch_text = read_required_text(patch_path, "patch")
    codebase_index = load_required_json(index_path, "codebase-index")
    reuse_candidates = load_required_json(candidates_path, "reuse-candidates")
    reuse_decision, decision_status = load_reuse_decision(decision_path, args.mode)
    style_profile = optional_json(project_root, args.style_profile, "style-profile")
    implementation_context = optional_json(project_root, args.implementation_context, "implementation-context")

    for label, document in (
        ("contract", contract),
        ("codebase-index", codebase_index),
        ("reuse-candidates", reuse_candidates),
    ):
        if not isinstance(document, dict):
            raise AuditError(EXIT_INVALID_INPUT, f"{label} JSON must be a top-level object")

    changed_files, added_line_count, blocks = parse_patch(patch_text)
    candidates = [candidate for candidate in as_list(reuse_candidates.get("candidates")) if isinstance(candidate, dict)]
    decisions = build_decision_map(reuse_decision)

    findings = []
    findings.extend(helper_reinvention_findings(blocks, candidates, decisions))
    findings.extend(added_block_overlap_findings(blocks, codebase_index, decisions))
    findings.extend(unaddressed_candidate_findings(blocks, candidates, decisions))
    findings.extend(convention_drift_findings(changed_files, as_dict(style_profile), as_dict(implementation_context)))
    findings = sort_and_number_findings(dedupe_findings(findings))
    counts = summary_counts(findings)

    inputs = {
        "patch": portable_path(args.patch, project_root),
        "codebaseIndex": portable_path(args.codebase_index, project_root),
        "reuseCandidates": portable_path(args.reuse_candidates, project_root),
        "reuseDecision": portable_path(args.reuse_decision, project_root),
    }
    if args.style_profile:
        inputs["styleProfile"] = portable_path(args.style_profile, project_root)
    if args.implementation_context:
        inputs["implementationContext"] = portable_path(args.implementation_context, project_root)

    return {
        "schemaVersion": SCHEMA_VERSION,
        "contractId": contract_id_from(contract, reuse_candidates, reuse_decision),
        "generatedAt": generated_at,
        "mode": args.mode,
        "inputs": inputs,
        "decisionStatus": decision_status,
        "scanStats": {
            "changedFiles": len(changed_files),
            "addedLines": added_line_count,
            "addedBlocks": len(blocks),
            "candidatesConsidered": len(candidates),
            "decisionEntries": decision_status["entries"],
        },
        "summaryCounts": counts,
        "findings": findings,
        "recommendedOutcome": recommended_outcome(counts),
    }


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv or sys.argv[1:])
        report = build_report(args)
        output_path = resolve_input(Path(args.project_root).resolve(), args.output)
        write_report(output_path, report)
        for note in report.get("decisionStatus", {}).get("notes", []):
            print(f"Warning: {note}", file=sys.stderr)
        print(
            f"duplicate scan completed: {report['summaryCounts']['total']} finding(s), "
            f"recommendedOutcome={report['recommendedOutcome']}"
        )
        return EXIT_OK
    except AuditError as exc:
        print(exc.message, file=sys.stderr)
        return exc.exit_code
    except OSError as exc:
        print(f"Unable to write duplicate scan output: {exc}", file=sys.stderr)
        return EXIT_INFRA


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
