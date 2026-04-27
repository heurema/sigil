#!/usr/bin/env python3
"""Deterministic Signum proofpack validator.

Uses Python stdlib only. This is intentionally a focused validator for the
proofpack shape Signum currently emits; it is not a full JSON Schema engine.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable

DECISIONS = {"AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW"}
CONTRACT_SOURCES = {"interactive", "file", "template"}
ENVELOPE_STATUSES = {"present", "omitted", "error"}
REQUIRED_TOP_LEVEL = {
    "schemaVersion": str,
    "signumVersion": str,
    "createdAt": str,
    "runId": str,
    "contractId": str,
    "decision": str,
    "releaseVerdict": str,
    "riskLevel": str,
    "summary": str,
    "confidence": dict,
    "timing": dict,
    "reviewCoverage": dict,
    "contractSource": str,
    "auditChain": dict,
    "contract": dict,
    "diff": dict,
    "baseline": dict,
    "executeLog": dict,
    "approval": dict,
    "checks": dict,
}
REQUIRED_CHECKS = ("mechanic", "holdout", "policy_scan", "reviews", "auditSummary")
TOP_LEVEL_ENVELOPES = ("contract", "diff", "baseline", "executeLog", "approval")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REMOVAL_ID_RE = re.compile(r"^RM[0-9]+$")
OBLIGATION_ID_RE = re.compile(r"^CO[0-9]+$")


class Validator:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.error(message)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return (isinstance(value, int) or isinstance(value, float)) and not isinstance(value, bool)


def _script_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _candidate_roots(repo_root: Path | None) -> list[Path]:
    # Resolve Signum-owned metadata (plugin.json, schema, command file) from the
    # Signum install location first. A scanned project may ship its own
    # .claude-plugin/plugin.json, which would otherwise hijack signumVersion
    # source-of-truth checks and produce false mismatches.
    roots: list[Path] = []
    script_root = _script_root()
    roots.append(script_root)
    # When running a mirrored platform script, script_root is platforms/claude-code.
    # When running root script, this duplicate is harmless.
    roots.append(script_root.parent)
    if repo_root is not None:
        roots.append(repo_root)

    unique: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        try:
            resolved = root.resolve()
        except OSError:
            resolved = root
        if resolved not in seen:
            unique.append(resolved)
            seen.add(resolved)
    return unique


def _load_json_file(path: Path, validator: Validator) -> Any | None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        validator.error(f"file not found: {path}")
    except json.JSONDecodeError as exc:
        validator.error(f"invalid JSON: {path}: line {exc.lineno} column {exc.colno}: {exc.msg}")
    except OSError as exc:
        validator.error(f"cannot read {path}: {exc}")
    return None


def _read_plugin_version(repo_root: Path | None, validator: Validator) -> str | None:
    for root in _candidate_roots(repo_root):
        plugin = root / ".claude-plugin" / "plugin.json"
        if not plugin.exists():
            continue
        data = _load_json_file(plugin, validator)
        if isinstance(data, dict) and isinstance(data.get("version"), str) and data["version"]:
            return data["version"]
        validator.error(f"invalid plugin version metadata: {plugin}")
        return None
    if repo_root is not None:
        validator.warn("plugin metadata not found; skipping signumVersion source-of-truth check")
    return None


def _read_runtime_schema_version(repo_root: Path | None, validator: Validator) -> str | None:
    for root in _candidate_roots(repo_root):
        command = root / "commands" / "signum.md"
        if command.exists():
            text = command.read_text(encoding="utf-8", errors="ignore")
            match = re.search(r'--arg\s+schemaVersion\s+"([^"]+)"', text)
            if match:
                return match.group(1)

        schema = root / "lib" / "schemas" / "proofpack.schema.json"
        if schema.exists():
            data = _load_json_file(schema, validator)
            enum = None
            if isinstance(data, dict):
                enum = (
                    data.get("properties", {})
                    .get("schemaVersion", {})
                    .get("enum")
                )
            if isinstance(enum, list) and enum and all(isinstance(item, str) for item in enum):
                return enum[-1]
    validator.warn("proofpack schema source not found; skipping schemaVersion source-of-truth check")
    return None


def _type_name(expected: type) -> str:
    if expected is str:
        return "string"
    if expected is dict:
        return "object"
    if expected is list:
        return "array"
    return expected.__name__


def _check_required_top_level(proofpack: dict[str, Any], validator: Validator) -> None:
    for field, expected_type in REQUIRED_TOP_LEVEL.items():
        if field not in proofpack:
            validator.error(f"missing required field: {field}")
            continue
        value = proofpack[field]
        if expected_type is str:
            if not isinstance(value, str) or not value:
                validator.error(f"{field} must be a non-empty string")
        elif not isinstance(value, expected_type):
            validator.error(f"{field} must be {_type_name(expected_type)}")


def _check_top_level_values(
    proofpack: dict[str, Any],
    expected_schema: str | None,
    expected_signum: str | None,
    validator: Validator,
) -> None:
    if isinstance(proofpack.get("schemaVersion"), str) and expected_schema:
        if proofpack["schemaVersion"] != expected_schema:
            validator.error(
                f"schemaVersion mismatch: proofpack={proofpack['schemaVersion']} expected={expected_schema}"
            )
    if isinstance(proofpack.get("signumVersion"), str) and expected_signum:
        if proofpack["signumVersion"] != expected_signum:
            validator.error(
                f"signumVersion mismatch: proofpack={proofpack['signumVersion']} expected={expected_signum}"
            )
    decision = proofpack.get("decision")
    if isinstance(decision, str) and decision not in DECISIONS:
        validator.error(f"decision must be one of {sorted(DECISIONS)}")
    contract_source = proofpack.get("contractSource")
    if isinstance(contract_source, str) and contract_source not in CONTRACT_SOURCES:
        validator.error(f"contractSource must be one of {sorted(CONTRACT_SOURCES)}")
    run_id = proofpack.get("runId")
    if isinstance(run_id, str) and not run_id.startswith("signum-"):
        validator.error("runId must start with 'signum-'")
    contract_id = proofpack.get("contractId")
    if isinstance(contract_id, str) and not contract_id.startswith("sig-"):
        validator.error("contractId must start with 'sig-'")

    confidence = proofpack.get("confidence")
    if isinstance(confidence, dict):
        overall = confidence.get("overall")
        if not _is_number(overall):
            validator.error("confidence.overall must be number")
        elif overall < 0 or overall > 100:
            validator.error("confidence.overall must be between 0 and 100")

    timing = proofpack.get("timing")
    if isinstance(timing, dict):
        for key in ("startedAt", "completedAt"):
            if key in timing and not isinstance(timing[key], str):
                validator.error(f"timing.{key} must be string")
        if "durationMs" in timing and not _is_number(timing["durationMs"]):
            validator.error("timing.durationMs must be number")

    coverage = proofpack.get("reviewCoverage")
    if isinstance(coverage, dict):
        available = coverage.get("availableReviews")
        if available is not None and not _is_int(available):
            validator.error("reviewCoverage.availableReviews must be integer")



def _check_envelope(name: str, value: Any, validator: Validator, require_full_sha: bool = False) -> None:
    if not isinstance(value, dict):
        validator.error(f"{name} must be object")
        return
    for field in ("sha256", "sizeBytes", "status"):
        if field not in value:
            validator.error(f"{name} missing envelope field: {field}")
    status = value.get("status")
    if isinstance(status, str):
        if status not in ENVELOPE_STATUSES:
            validator.error(f"{name}.status must be one of {sorted(ENVELOPE_STATUSES)}")
    elif "status" in value:
        validator.error(f"{name}.status must be string")

    size = value.get("sizeBytes")
    if "sizeBytes" in value and (not _is_int(size) or size < 0):
        validator.error(f"{name}.sizeBytes must be non-negative integer")

    sha = value.get("sha256")
    if sha is not None and not isinstance(sha, str):
        validator.error(f"{name}.sha256 must be string or null")
    if status == "present":
        if not isinstance(sha, str) or not sha:
            validator.error(f"{name}.sha256 required when status is present")
        elif not SHA256_RE.match(sha):
            validator.error(f"{name}.sha256 must be lowercase sha256 hex")
    if require_full_sha:
        full_sha = value.get("fullSha256")
        if not isinstance(full_sha, str) or not SHA256_RE.match(full_sha):
            validator.error(f"{name}.fullSha256 must be lowercase sha256 hex")



def _check_envelopes(proofpack: dict[str, Any], validator: Validator) -> None:
    for key in TOP_LEVEL_ENVELOPES:
        if key in proofpack:
            _check_envelope(key, proofpack[key], validator, require_full_sha=(key == "contract"))

    checks = proofpack.get("checks")
    if not isinstance(checks, dict):
        return
    for field in REQUIRED_CHECKS:
        if field not in checks:
            validator.error(f"checks missing required field: {field}")
    for field in ("mechanic", "holdout", "policy_scan", "auditSummary"):
        if field in checks:
            _check_envelope(f"checks.{field}", checks[field], validator)
    reviews = checks.get("reviews")
    if isinstance(reviews, dict):
        for provider, envelope in reviews.items():
            if not isinstance(provider, str) or not provider:
                validator.error("checks.reviews provider names must be non-empty strings")
                continue
            _check_envelope(f"checks.reviews.{provider}", envelope, validator)
    elif "reviews" in checks:
        validator.error("checks.reviews must be object")

    audit_summary = checks.get("auditSummary")
    if isinstance(audit_summary, dict):
        content = audit_summary.get("content")
        if isinstance(content, dict) and isinstance(content.get("decision"), str):
            if content["decision"] != proofpack.get("decision"):
                validator.error("checks.auditSummary.content.decision must match top-level decision")



def _safe_relative_path(path_value: str) -> bool:
    if not path_value:
        return False
    if path_value.startswith(("/", "~")):
        return False
    normalized = path_value.replace("\\", "/")
    parts = normalized.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        return False
    return True


def _iter_path_refs(value: Any, location: str) -> Iterable[tuple[str, str]]:
    if isinstance(value, str):
        yield location, value
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _iter_path_refs(item, f"{location}[{index}]")
    elif isinstance(value, dict):
        if isinstance(value.get("path"), str):
            yield f"{location}.path", value["path"]
        elif isinstance(value.get("relativePath"), str):
            yield f"{location}.relativePath", value["relativePath"]
        else:
            for key, item in value.items():
                if isinstance(item, str):
                    yield f"{location}.{key}", item
                elif isinstance(item, (dict, list)):
                    yield from _iter_path_refs(item, f"{location}.{key}")


def _collect_artifact_refs(proofpack: dict[str, Any]) -> list[tuple[str, str]]:
    refs: list[tuple[str, str]] = []
    for key in ("artifactRefs", "artifacts"):
        if key in proofpack:
            refs.extend(_iter_path_refs(proofpack[key], key))

    for key in TOP_LEVEL_ENVELOPES:
        value = proofpack.get(key)
        if isinstance(value, dict) and isinstance(value.get("path"), str):
            refs.append((f"{key}.path", value["path"]))

    checks = proofpack.get("checks")
    if isinstance(checks, dict):
        for key, value in checks.items():
            if key == "reviews" and isinstance(value, dict):
                for provider, review in value.items():
                    if isinstance(review, dict) and isinstance(review.get("path"), str):
                        refs.append((f"checks.reviews.{provider}.path", review["path"]))
            elif isinstance(value, dict) and isinstance(value.get("path"), str):
                refs.append((f"checks.{key}.path", value["path"]))
    return refs


def _infer_contract_root(
    proofpack_path: Path,
    proofpack: dict[str, Any] | None,
    repo_root: Path | None,
    explicit_contract_root: Path | None,
    validator: Validator,
) -> Path | None:
    if explicit_contract_root is not None:
        if not explicit_contract_root.is_dir():
            validator.error(f"contract root is not a directory: {explicit_contract_root}")
            return None
        return explicit_contract_root.resolve()

    path = proofpack_path.resolve()
    if path.name == "proofpack.json" and path.parent.parent.name == "contracts" and path.parent.parent.parent.name == ".signum":
        return path.parent

    contract_id = proofpack.get("contractId") if isinstance(proofpack, dict) else None
    if repo_root is not None and isinstance(contract_id, str) and contract_id:
        candidate = repo_root / ".signum" / "contracts" / contract_id
        if candidate.is_dir():
            return candidate.resolve()

    return None


def _check_artifact_refs(
    proofpack: dict[str, Any],
    contract_root: Path | None,
    validator: Validator,
) -> None:
    refs = _collect_artifact_refs(proofpack)
    if not refs:
        return

    resolved_root = contract_root.resolve() if contract_root is not None else None
    if resolved_root is None:
        validator.warn("contract root unavailable; skipping artifact reference existence checks")

    for location, ref in refs:
        if not _safe_relative_path(ref):
            validator.error(f"unsafe artifact path at {location}: {ref!r}")
            continue
        if resolved_root is None:
            continue
        candidate = (resolved_root / ref).resolve()
        try:
            candidate.relative_to(resolved_root)
        except ValueError:
            validator.error(f"artifact path escapes contract root at {location}: {ref!r}")
            continue
        if not candidate.exists():
            validator.error(f"referenced artifact missing at {location}: {ref}")


def _check_removal_evidence(proofpack: dict[str, Any], validator: Validator) -> None:
    if "removalEvidence" not in proofpack:
        return

    evidence = proofpack["removalEvidence"]
    if not isinstance(evidence, dict):
        validator.error("removalEvidence must be object")
        return

    removals = evidence.get("removals")
    if removals is not None:
        if not isinstance(removals, list):
            validator.error("removalEvidence.removals must be array")
        else:
            for index, item in enumerate(removals):
                location = f"removalEvidence.removals[{index}]"
                if not isinstance(item, dict):
                    validator.error(f"{location} must be object")
                    continue
                rid = item.get("id")
                if not isinstance(rid, str) or not REMOVAL_ID_RE.match(rid):
                    validator.error(f"{location}.id must match RM<number>")
                path = item.get("path")
                if not isinstance(path, str) or not _safe_relative_path(path):
                    validator.error(f"{location}.path must be a safe relative path")
                if not isinstance(item.get("removed"), bool):
                    validator.error(f"{location}.removed must be boolean")
                if "type" in item and item["type"] not in {"file", "directory"}:
                    validator.error(f"{location}.type must be file or directory")
                orphan_refs = item.get("orphanReferences")
                if orphan_refs is not None and (not _is_int(orphan_refs) or orphan_refs < 0):
                    validator.error(f"{location}.orphanReferences must be non-negative integer")
                modules_updated = item.get("modulesYamlUpdated")
                if modules_updated is not None and not isinstance(modules_updated, bool):
                    validator.error(f"{location}.modulesYamlUpdated must be boolean")

    obligations = evidence.get("obligations")
    if obligations is not None:
        if not isinstance(obligations, list):
            validator.error("removalEvidence.obligations must be array")
        else:
            for index, item in enumerate(obligations):
                location = f"removalEvidence.obligations[{index}]"
                if not isinstance(item, dict):
                    validator.error(f"{location} must be object")
                    continue
                oid = item.get("id")
                if not isinstance(oid, str) or not OBLIGATION_ID_RE.match(oid):
                    validator.error(f"{location}.id must match CO<number>")
                if not isinstance(item.get("fulfilled"), bool):
                    validator.error(f"{location}.fulfilled must be boolean")
                if "action" in item and not isinstance(item["action"], str):
                    validator.error(f"{location}.action must be string")
                if "blocking" in item and not isinstance(item["blocking"], bool):
                    validator.error(f"{location}.blocking must be boolean")
                if "verifyOutput" in item and not isinstance(item["verifyOutput"], str):
                    validator.error(f"{location}.verifyOutput must be string")


def validate(args: argparse.Namespace) -> int:
    validator = Validator()
    proofpack_path = Path(args.proofpack)
    repo_root = Path(args.repo_root).resolve() if args.repo_root else None
    explicit_contract_root = Path(args.contract_root).resolve() if args.contract_root else None

    data = _load_json_file(proofpack_path, validator)
    if data is None:
        _emit(validator)
        return 1
    if not isinstance(data, dict):
        validator.error("proofpack top-level value must be object")
        _emit(validator)
        return 1

    expected_schema = _read_runtime_schema_version(repo_root, validator)
    expected_signum = _read_plugin_version(repo_root, validator)
    contract_root = _infer_contract_root(proofpack_path, data, repo_root, explicit_contract_root, validator)

    _check_required_top_level(data, validator)
    _check_top_level_values(data, expected_schema, expected_signum, validator)
    _check_envelopes(data, validator)
    _check_artifact_refs(data, contract_root, validator)
    _check_removal_evidence(data, validator)

    _emit(validator)
    return 1 if validator.errors else 0


def _emit(validator: Validator) -> None:
    for warning in validator.warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    for error in validator.errors:
        print(f"ERROR: {error}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate a Signum proofpack.json artifact")
    parser.add_argument("proofpack", help="path to proofpack.json")
    parser.add_argument("--repo-root", help="project/repository root for version metadata", default=None)
    parser.add_argument("--contract-root", help="canonical .signum/contracts/<contractId> artifact root", default=None)
    args = parser.parse_args(argv)
    return validate(args)


if __name__ == "__main__":
    raise SystemExit(main())
