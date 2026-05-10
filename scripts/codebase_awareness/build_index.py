#!/usr/bin/env python3
"""Build local deterministic codebase awareness scanner artifacts.

This is intentionally shallow: it records file, symbol, import, test, manifest,
and convention signals that later deterministic steps can explain. It does not
parse ASTs or call external tools.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from scripts.codebase_awareness.adapters import csharp, go, rust, typescript_js
from scripts.codebase_awareness.adapters.common import (
    is_test_fixture_path,
    is_test_path,
    normalize_rel_parts,
    split_identifier,
    tokens_for_path,
)

DEFAULT_MAX_FILES = 10_000
DEFAULT_MAX_BYTES = 50_000_000
DEFAULT_MAX_FILE_SIZE = 1_048_576
TEXT_EXTRACTION_LIMIT = 800_000
INDEX_SCAN_MODE = "shallow-regex-v1"
DIGEST_SCAN_MODE = "lexical-symbol"
EXTRACTS_SCHEMA_VERSION = "1.0"
EXTRACTOR_VERSION = "codebase-awareness-extracts-v1"

IGNORE_DIRS = {
    ".git",
    ".signum",
    ".venv",
    ".mypy_cache",
    ".pytest_cache",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "target",
    "vendor",
    "venv",
}
BUILD_OUTPUT_DIRS = {"bin", "obj"}
SOURCE_ROOT_DIRS = {"lib", "source", "src", "test", "tests"}
GENERATED_MARKER_SCAN_BYTES = 8192
GENERATED_MARKER_SCAN_LINES = 40
GENERATED_MARKER_RE = re.compile(
    r"""
    ^
    \s*
    (?:
      (?://+|/\*+|\*+|\#+|;|--|<!--)\s*
    )?
    (?:
      @generated\b
      | auto-generated\b
      | automatically\ generated\b
      | code\ generated\b
      | generated\ by\b
      | this\ file\ (?:is|was)\ generated\b
      | do\ not\ edit\b
    )
    """,
    re.IGNORECASE | re.VERBOSE,
)

LANGUAGE_BY_SUFFIX = {
    ".cjs": "javascript",
    ".cs": "csharp",
    ".csproj": "csharp",
    ".cts": "typescript",
    ".go": "go",
    ".js": "javascript",
    ".jsx": "javascript",
    ".json": "json",
    ".mjs": "javascript",
    ".mts": "typescript",
    ".py": "python",
    ".props": "csharp",
    ".rs": "rust",
    ".sh": "shell",
    ".sln": "csharp",
    ".targets": "csharp",
    ".toml": "toml",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".yaml": "yaml",
    ".yml": "yaml",
}

SOURCE_LANGUAGES = {"csharp", "go", "javascript", "python", "rust", "shell", "typescript"}
LANGUAGE_ADAPTERS = (go, rust, csharp, typescript_js)

MANIFEST_NAMES = {
    "package-lock.json": "npm",
    "package.json": "npm",
    "pnpm-lock.yaml": "npm",
    "pyproject.toml": "python",
    "requirements.txt": "python",
    "setup.cfg": "python",
    "setup.py": "python",
    "yarn.lock": "npm",
}
SHARED_DIR_HINTS = {"common", "lib", "shared", "utils"}
VALIDATION_TOKENS = {"assert", "check", "parse", "schema", "valid", "validate", "validation", "validator"}


@dataclass(frozen=True)
class ScanFile:
    path: Path
    rel: str
    language: str | None
    size_bytes: int
    mtime_ns: int
    sha256: str | None
    indexed: bool
    reason: str
    text: str


@dataclass(frozen=True)
class ScanResult:
    files: list[ScanFile]
    scan_stats: dict[str, Any]
    unsupported_files_summary: dict[str, int]


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def non_negative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"expected integer, got {value!r}") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be greater than or equal to 0")
    return parsed


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build Signum codebase awareness index artifacts.")
    parser.add_argument("--project-root", default=".")
    parser.add_argument("--output", default=".signum/cache/codebase-index-v1.json")
    parser.add_argument("--style-output", default=None)
    parser.add_argument("--style-profile", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--digests-output", default=None)
    parser.add_argument("--previous-digests", default=None)
    parser.add_argument("--extracts-output", default=None)
    parser.add_argument("--previous-extracts", default=None)
    parser.add_argument("--max-files", type=non_negative_int, default=DEFAULT_MAX_FILES)
    parser.add_argument("--max-bytes", type=non_negative_int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--max-file-size", type=non_negative_int, default=DEFAULT_MAX_FILE_SIZE)
    parser.add_argument("--generated-at", default=None)
    args = parser.parse_args(argv)
    args.style_output = args.style_output or args.style_profile or ".signum/cache/style-profile-v1.json"
    return args


def portable_project_root(project_root_arg: str) -> str:
    if Path(project_root_arg).is_absolute():
        return "."
    return project_root_arg or "."


def relpath(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def should_ignore_dir(rel: str) -> bool:
    parts = rel.split("/") if rel else []
    for index, part in enumerate(parts):
        if part in IGNORE_DIRS:
            return True
        if part in BUILD_OUTPUT_DIRS:
            if index == 0:
                return True
            parent = parts[index - 1]
            if parent not in SOURCE_ROOT_DIRS:
                return True
    return False


def iter_candidate_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        rel_dir = "" if current == root else relpath(current, root)
        dirnames[:] = sorted(
            dirname
            for dirname in dirnames
            if not should_ignore_dir(f"{rel_dir}/{dirname}".strip("/"))
        )
        for filename in sorted(filenames):
            path = current / filename
            rel = relpath(path, root)
            if should_ignore_dir(rel):
                continue
            if path.is_file():
                files.append(path)
    return files


def manifest_kind_for_path(rel: str) -> str | None:
    path = Path(rel)
    for adapter in LANGUAGE_ADAPTERS:
        adapter_manifest_kind = getattr(adapter, "manifest_kind_for_path", None)
        if callable(adapter_manifest_kind):
            kind = adapter_manifest_kind(rel)
            if kind:
                return kind
        kinds = adapter.manifest_kinds()
        if path.name in kinds:
            return kinds[path.name]
    if path.name in MANIFEST_NAMES:
        return MANIFEST_NAMES[path.name]
    return None


def language_for_path(rel: str) -> str | None:
    path = Path(rel)
    manifest_kind = manifest_kind_for_path(rel)
    if manifest_kind:
        for adapter in LANGUAGE_ADAPTERS:
            language = adapter.language_for_manifest(manifest_kind)
            if language:
                return language
        return {
            "npm": "json" if path.suffix == ".json" else "yaml",
            "python": "toml" if path.suffix == ".toml" else "python",
        }.get(manifest_kind)
    return LANGUAGE_BY_SUFFIX.get(path.suffix)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_binary_data(data: bytes) -> bool:
    return b"\0" in data[:4096]


def has_generated_marker(data: bytes) -> bool:
    try:
        prefix = data[:GENERATED_MARKER_SCAN_BYTES].decode("utf-8", errors="replace")
    except OSError:
        return False
    lines = prefix.splitlines()[:GENERATED_MARKER_SCAN_LINES]
    return any(GENERATED_MARKER_RE.match(line) for line in lines)


def decode_text_for_extraction(data: bytes) -> str:
    return data[:TEXT_EXTRACTION_LIMIT].decode("utf-8", errors="replace")


def skipped_scan_file(path: Path, rel: str, language: str | None, size_bytes: int, mtime_ns: int, reason: str) -> ScanFile:
    return ScanFile(
        path=path,
        rel=rel,
        language=language,
        size_bytes=size_bytes,
        mtime_ns=mtime_ns,
        sha256=None,
        indexed=False,
        reason=reason,
        text="",
    )


def build_scan(
    root: Path,
    *,
    max_files: int,
    max_bytes: int,
    max_file_size: int,
) -> ScanResult:
    files: list[ScanFile] = []
    unsupported: Counter[str] = Counter()
    files_seen = 0
    files_indexed = 0
    bytes_indexed = 0
    truncated = False
    notes: list[str] = []

    for path in iter_candidate_files(root):
        rel = relpath(path, root)
        language = language_for_path(rel)
        try:
            stat = path.stat()
        except OSError:
            files_seen += 1
            unsupported["read-error"] += 1
            files.append(skipped_scan_file(path, rel, language, 0, 0, "read-error"))
            continue

        size_bytes = int(stat.st_size)
        mtime_ns = int(stat.st_mtime_ns)
        files_seen += 1

        if size_bytes > max_file_size:
            unsupported["oversized"] += 1
            files.append(skipped_scan_file(path, rel, language, size_bytes, mtime_ns, "oversized"))
            continue

        if files_indexed >= max_files:
            unsupported["max-files"] += 1
            truncated = True
            notes.append(f"max-files cap reached at {max_files}")
            files.append(skipped_scan_file(path, rel, language, size_bytes, mtime_ns, "max-files"))
            break

        if bytes_indexed + size_bytes > max_bytes:
            unsupported["max-bytes"] += 1
            truncated = True
            notes.append(f"max-bytes cap reached at {max_bytes}")
            files.append(skipped_scan_file(path, rel, language, size_bytes, mtime_ns, "max-bytes"))
            break

        try:
            data = path.read_bytes()
        except OSError:
            unsupported["read-error"] += 1
            files.append(skipped_scan_file(path, rel, language, size_bytes, mtime_ns, "read-error"))
            continue

        digest = sha256_bytes(data)
        if is_binary_data(data):
            unsupported["binary"] += 1
            files.append(
                ScanFile(
                    path=path,
                    rel=rel,
                    language=language,
                    size_bytes=size_bytes,
                    mtime_ns=mtime_ns,
                    sha256=digest,
                    indexed=False,
                    reason="binary",
                    text="",
                )
            )
            continue

        if has_generated_marker(data):
            unsupported["generated"] += 1
            files.append(
                ScanFile(
                    path=path,
                    rel=rel,
                    language=language,
                    size_bytes=size_bytes,
                    mtime_ns=mtime_ns,
                    sha256=digest,
                    indexed=False,
                    reason="generated",
                    text="",
                )
            )
            continue

        files_indexed += 1
        bytes_indexed += size_bytes
        files.append(
            ScanFile(
                path=path,
                rel=rel,
                language=language,
                size_bytes=size_bytes,
                mtime_ns=mtime_ns,
                sha256=digest,
                indexed=True,
                reason="indexed",
                text=decode_text_for_extraction(data),
            )
        )

    files_skipped = sum(1 for file in files if not file.indexed)
    scan_stats = {
        "filesSeen": files_seen,
        "filesIndexed": files_indexed,
        "filesReused": 0,
        "filesSkipped": files_skipped,
        "bytesIndexed": bytes_indexed,
        "truncated": truncated,
    }
    if notes:
        scan_stats["notes"] = sorted(set(notes))
    return ScanResult(
        files=files,
        scan_stats=scan_stats,
        unsupported_files_summary=dict(sorted(unsupported.items())),
    )


def scan_stats_add_note(scan_stats: dict[str, Any], note: str) -> None:
    notes = [str(item) for item in scan_stats.get("notes", []) if item]
    notes.append(note)
    scan_stats["notes"] = sorted(set(notes))


def clone_jsonable(value: Any) -> Any:
    return copy.deepcopy(value)


def extract_file_text_signals(rel: str, language: str | None, text: str) -> dict[str, Any]:
    signals: dict[str, Any] = {
        "lineCount": len(text.splitlines()) if text else 0,
        "tokens": tokens_for_path(rel),
        "style": {
            "throwCatch": bool(re.search(r"\bthrow\s+new\s+Error\b|\btry\s*\{|\bcatch\s*\(", text)),
            "tryExceptRaise": bool(re.search(r"^\s*(try:|except\b|raise\b)", text, flags=re.MULTILINE)),
            "runtimeLoggingCall": bool(re.search(r"\bconsole\.(log|warn|error)\b|\blogger\.|\blogging\.getLogger\b", text)),
            "environmentVariableAccess": bool(re.search(r"\b(process\.env|os\.environ|getenv)\b", text)),
        },
    }
    if language == "go":
        package_name = go.extract_package_name(text)
        if package_name:
            signals["packageName"] = package_name
    if language == "rust":
        signals["hasInlineCfgTest"] = bool(re.search(r"#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]", text))
    if language == "csharp" and Path(rel).suffix == ".cs":
        framework = csharp.test_framework_for_text(rel, text)
        if framework:
            signals["csharpTestFramework"] = framework
    if language in {"javascript", "typescript"}:
        signals.update(typescript_js.file_text_signals(rel, text, language))
    return signals


def basic_module_record(rel: str, language: str | None, signals: dict[str, Any]) -> dict[str, Any]:
    module: dict[str, Any] = {
        "path": rel,
        "name": Path(rel).stem,
        "directory": Path(rel).parent.as_posix() if Path(rel).parent.as_posix() != "." else "",
        "language": language,
        "kind": module_kind(rel),
        "tokens": tokens_for_path(rel),
        "lineCount": int(signals.get("lineCount", 0)),
    }
    package_name = signals.get("packageName")
    if isinstance(package_name, str) and package_name:
        module["package"] = package_name
    return module


def text_only_test_info(rel: str, text: str, language: str | None) -> dict[str, Any]:
    if language == "go":
        return go.test_info(rel, text, language)
    if language == "rust":
        info = rust.test_info(rel, text, language)
        info["framework"] = rust.test_framework(text) if info.get("hasTests") else None
        return info
    if language == "csharp":
        return csharp.test_info(rel, text, language, None)
    if language in {"javascript", "typescript"}:
        return typescript_js.test_info(rel, text, language)
    return {
        "hasTests": is_test_path(rel),
        "framework": test_framework_for_path(rel, text, language) if is_test_path(rel) else None,
        "testFunctions": [],
    }


def cached_test_records(
    rel: str,
    language: str | None,
    signals: dict[str, Any],
    test_info: dict[str, Any],
) -> list[dict[str, Any]]:
    if not (is_test_path(rel) or test_info.get("hasTests")):
        return []
    record: dict[str, Any] = {
        "path": rel,
        "language": language,
        "framework": test_info.get("framework"),
        "tokens": sorted(set(tokens_for_path(rel)) | ({"test"} if language == "rust" else set())),
    }
    package_name = signals.get("packageName")
    if language == "go" and isinstance(package_name, str) and package_name:
        record["package"] = package_name
        record["targetPackage"] = package_name[: -len("_test")] if package_name.endswith("_test") else package_name
    if test_info.get("testFunctions"):
        record["testFunctions"] = test_info["testFunctions"]
    if test_info.get("hasCfgTest"):
        record["inlineCfgTest"] = True
    return [record]


def fresh_extraction_payload(scanned_file: ScanFile) -> dict[str, Any]:
    signals = extract_file_text_signals(scanned_file.rel, scanned_file.language, scanned_file.text)
    test_info = text_only_test_info(scanned_file.rel, scanned_file.text, scanned_file.language)
    manifest = extract_manifest(scanned_file.rel, scanned_file.text)
    return {
        "sha256": scanned_file.sha256,
        "sizeBytes": scanned_file.size_bytes,
        "language": scanned_file.language,
        "indexed": True,
        "reason": scanned_file.reason,
        "module": basic_module_record(scanned_file.rel, scanned_file.language, signals),
        "symbols": extract_symbols(scanned_file.rel, scanned_file.language, scanned_file.text),
        "imports": extract_import_records(scanned_file.language, scanned_file.text),
        "tests": cached_test_records(scanned_file.rel, scanned_file.language, signals, test_info),
        "manifest": manifest,
        "fileTextSignals": signals,
        "testInfo": test_info,
    }


def skipped_extraction_payload(scanned_file: ScanFile) -> dict[str, Any]:
    return {
        "sha256": scanned_file.sha256,
        "sizeBytes": scanned_file.size_bytes,
        "language": scanned_file.language,
        "indexed": False,
        "reason": scanned_file.reason,
        "module": {},
        "symbols": [],
        "imports": [],
        "tests": [],
        "manifest": None,
        "fileTextSignals": {
            "lineCount": 0,
            "tokens": tokens_for_path(scanned_file.rel),
        },
        "testInfo": {
            "hasTests": False,
            "framework": None,
            "testFunctions": [],
        },
    }


def extraction_cache_is_compatible(cache: dict[str, Any]) -> tuple[bool, str | None]:
    if not cache:
        return False, "missing"
    if cache.get("schemaVersion") != EXTRACTS_SCHEMA_VERSION:
        return False, "schemaVersion"
    if cache.get("scanMode") != INDEX_SCAN_MODE:
        return False, "scanMode"
    if cache.get("extractorVersion") != EXTRACTOR_VERSION:
        return False, "extractorVersion"
    files = cache.get("files")
    if not isinstance(files, dict):
        return False, "files"
    return True, None


def previous_extraction_record_is_reusable(
    scanned_file: ScanFile,
    record: Any,
) -> bool:
    if not scanned_file.indexed or not isinstance(record, dict):
        return False
    if record.get("sha256") != scanned_file.sha256:
        return False
    if record.get("sizeBytes") != scanned_file.size_bytes:
        return False
    if record.get("indexed") is not True:
        return False
    required_types = {
        "module": dict,
        "symbols": list,
        "imports": list,
        "tests": list,
        "fileTextSignals": dict,
        "testInfo": dict,
    }
    for key, expected_type in required_types.items():
        if not isinstance(record.get(key), expected_type):
            return False
    manifest = record.get("manifest")
    if manifest is not None and not isinstance(manifest, dict):
        return False
    return True


def build_extractions(
    scan: ScanResult,
    previous_extracts: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    compatible, reason = extraction_cache_is_compatible(previous_extracts)
    if previous_extracts and not compatible and reason != "missing":
        scan_stats_add_note(scan.scan_stats, f"previous-extracts ignored: incompatible {reason}")

    previous_files = previous_extracts.get("files") if compatible else {}
    if not isinstance(previous_files, dict):
        previous_files = {}

    files_reused = 0
    files_extracted = 0
    extracted: dict[str, dict[str, Any]] = {}
    for scanned_file in sorted(scan.files, key=lambda item: item.rel):
        if not scanned_file.indexed:
            extracted[scanned_file.rel] = skipped_extraction_payload(scanned_file)
            continue
        previous_record = previous_files.get(scanned_file.rel)
        if previous_extraction_record_is_reusable(scanned_file, previous_record):
            payload = clone_jsonable(previous_record)
            payload["sha256"] = scanned_file.sha256
            payload["sizeBytes"] = scanned_file.size_bytes
            payload["language"] = scanned_file.language
            payload["indexed"] = True
            payload["reason"] = scanned_file.reason
            extracted[scanned_file.rel] = payload
            files_reused += 1
            continue
        extracted[scanned_file.rel] = fresh_extraction_payload(scanned_file)
        files_extracted += 1

    scan.scan_stats["filesReused"] = files_reused
    scan.scan_stats["filesExtracted"] = files_extracted
    return extracted


def build_extracts_cache(
    generated_at: str,
    project_root_arg: str,
    scan: ScanResult,
    extractions: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    cache: dict[str, Any] = {
        "schemaVersion": EXTRACTS_SCHEMA_VERSION,
        "generatedAt": generated_at,
        "projectRoot": project_root_arg,
        "scanMode": INDEX_SCAN_MODE,
        "extractorVersion": EXTRACTOR_VERSION,
        "files": {rel: clone_jsonable(extractions[rel]) for rel in sorted(extractions)},
        "scanStats": scan.scan_stats,
    }
    if scan.unsupported_files_summary:
        cache["unsupportedFilesSummary"] = scan.unsupported_files_summary
    return cache


def module_kind(rel: str) -> str:
    if manifest_kind_for_path(rel):
        return "manifest"
    if is_test_path(rel):
        return "test"
    if language_for_path(rel) in SOURCE_LANGUAGES:
        return "source"
    return "support"


def extract_symbols(rel: str, language: str | None, text: str) -> list[dict[str, Any]]:
    if language == "csharp" and Path(rel).suffix == ".cs":
        return csharp.extract_symbols(rel, text)
    if language == "go":
        return go.extract_symbols(rel, text)
    if language == "rust":
        return rust.extract_symbols(rel, text)
    if language in {"javascript", "typescript"} and Path(rel).suffix in typescript_js.SOURCE_EXTENSIONS:
        return typescript_js.extract_symbols(rel, text)

    patterns: list[tuple[str, str, str]] = []
    if language == "python":
        patterns = [
            ("function", r"^\s*def\s+([A-Za-z_][\w]*)\s*\(", "local"),
            ("class", r"^\s*class\s+([A-Za-z_][\w]*)\b", "local"),
        ]
    elif language == "shell":
        patterns = [
            ("function", r"^\s*([A-Za-z_][\w-]*)\s*\(\)\s*\{", "local"),
            ("function", r"^\s*function\s+([A-Za-z_][\w-]*)\b", "local"),
        ]

    seen: set[tuple[str, str]] = set()
    symbols: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        for kind, pattern, export_state in patterns:
            match = re.search(pattern, line)
            if not match:
                continue
            name = match.group(1)
            key = (kind, name)
            if key in seen:
                continue
            seen.add(key)
            exported = export_state == "exported" or bool(
                language == "python" and not name.startswith("_")
            )
            symbols.append(
                {
                    "name": name,
                    "kind": kind,
                    "language": language,
                    "path": rel,
                    "line": line_number,
                    "exported": exported,
                    "tokens": sorted(set(split_identifier(name))),
                }
            )
    return symbols


def extract_import_specs(language: str | None, text: str) -> list[str]:
    specs: list[str] = []
    if language in {"javascript", "typescript"}:
        patterns = [
            r"\bfrom\s+['\"]([^'\"]+)['\"]",
            r"\bimport\s+['\"]([^'\"]+)['\"]",
            r"\brequire\(\s*['\"]([^'\"]+)['\"]\s*\)",
        ]
    elif language == "python":
        patterns = [
            r"^\s*from\s+([A-Za-z_][\w.]*)\s+import\b",
            r"^\s*import\s+([A-Za-z_][\w.]*)\b",
        ]
    else:
        patterns = []
    for pattern in patterns:
        for match in re.finditer(pattern, text, flags=re.MULTILINE):
            specs.append(match.group(1))
    return sorted(set(specs))


def extract_import_records(language: str | None, text: str) -> list[dict[str, Any]]:
    if language == "csharp":
        return csharp.extract_import_records(text)
    if language == "go":
        return go.extract_import_records(text)
    if language == "rust":
        return rust.extract_import_records(text)
    if language in {"javascript", "typescript"}:
        return typescript_js.extract_import_records(text)
    return [
        {
            "imported": spec,
            "tokens": sorted(set(split_identifier(spec))),
        }
        for spec in extract_import_specs(language, text)
    ]


def extract_manifest(rel: str, text: str) -> dict[str, Any] | None:
    path = Path(rel)
    manifest_kind = manifest_kind_for_path(rel)
    if not manifest_kind:
        return None
    for adapter in LANGUAGE_ADAPTERS:
        manifest = adapter.extract_manifest(rel, text, manifest_kind)
        if manifest:
            return manifest
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": manifest_kind,
        "language": language_for_path(rel),
        "tokens": tokens_for_path(rel),
    }
    if path.name == "package.json":
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            data = {}
        if isinstance(data, dict):
            scripts = data.get("scripts")
            deps = data.get("dependencies")
            dev_deps = data.get("devDependencies")
            if isinstance(scripts, dict):
                manifest["scripts"] = sorted(str(key) for key in scripts)
            if isinstance(deps, dict):
                manifest["dependencies"] = sorted(str(key) for key in deps)
            if isinstance(dev_deps, dict):
                manifest["devDependencies"] = sorted(str(key) for key in dev_deps)
    return manifest


def resolve_import(
    source_rel: str,
    spec: str,
    known_files: set[str],
    *,
    language: str | None,
    go_modules: list[tuple[str, str]],
    go_package_dirs: set[str],
    rust_context: dict[str, Any] | None = None,
    csharp_context: dict[str, Any] | None = None,
    typescript_context: dict[str, Any] | None = None,
) -> str | None:
    if language == "csharp":
        if isinstance(csharp_context, dict):
            return csharp.resolve_import(source_rel, spec, csharp_context)
        return None
    if language == "go":
        return go.resolve_import(spec, go_modules, go_package_dirs)
    if language == "rust":
        if isinstance(rust_context, dict):
            return rust.resolve_import(source_rel, spec, known_files, rust_context)
        return None
    if language in {"javascript", "typescript"}:
        if isinstance(typescript_context, dict):
            return typescript_js.resolve_import(source_rel, spec, known_files, typescript_context)
        return None
    if not spec.startswith("."):
        return None
    base = (Path(source_rel).parent / spec).as_posix()
    candidates = [
        base,
        f"{base}.ts",
        f"{base}.tsx",
        f"{base}.mts",
        f"{base}.cts",
        f"{base}.js",
        f"{base}.jsx",
        f"{base}.mjs",
        f"{base}.cjs",
        f"{base}.py",
        f"{base}/index.ts",
        f"{base}/index.tsx",
        f"{base}/index.mts",
        f"{base}/index.cts",
        f"{base}/index.js",
        f"{base}/index.mjs",
        f"{base}/index.cjs",
        f"{base}/__init__.py",
    ]
    normalized = [normalize_rel_parts(candidate) for candidate in candidates]
    for candidate in normalized:
        if candidate in known_files:
            return candidate
    return None


def test_framework_for_path(rel: str, text: str, language: str | None) -> str | None:
    if language == "csharp":
        return csharp.test_framework_for_text(rel, text)
    if language == "go" and go.is_test_path(rel):
        return "go-test"
    if language in {"javascript", "typescript"}:
        return typescript_js.test_info(rel, text, language).get("framework")
    if language == "python":
        if "pytest" in text or Path(rel).name.startswith("test_"):
            return "pytest"
        return "python-test"
    if language == "shell":
        return "shell"
    if language == "rust":
        return rust.test_framework(text)
    return None


def paired_tests_for(rel: str, tests: list[dict[str, Any]]) -> list[str]:
    path = Path(rel)
    if path.suffix == "" or str(rel).endswith("/"):
        package_dir = str(rel).rstrip("/")
        return sorted(
            str(test.get("path"))
            for test in tests
            if Path(str(test.get("path"))).parent.as_posix() == package_dir
        )
    stem = path.stem
    if stem.endswith("_test"):
        stem = stem[: -len("_test")]
    if stem.endswith(".test") or stem.endswith(".spec"):
        stem = stem.rsplit(".", 1)[0]
    pairs: list[str] = []
    for test in tests:
        test_path = str(test.get("path", ""))
        if stem and stem in tokens_for_path(test_path):
            pairs.append(test_path)
    return sorted(set(pairs))


def convention_entry(name: str, value: str, language: str | None, evidence: list[str]) -> dict[str, Any]:
    return {
        "name": name,
        "value": value,
        "language": language,
        "evidence": sorted(set(evidence))[:8],
    }


def build_style_profile(
    generated_at: str,
    project_root_arg: str,
    modules: list[dict[str, Any]],
    symbols: list[dict[str, Any]],
    manifests: list[dict[str, Any]],
    file_text_signals: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    language_counts = Counter(
        str(module.get("language"))
        for module in modules
        if module.get("kind") in {"source", "test"} and module.get("language") in SOURCE_LANGUAGES
    )
    primary_languages = [
        language for language, _count in sorted(language_counts.items(), key=lambda item: (-item[1], item[0]))
    ]

    tests = [module for module in modules if module.get("kind") == "test"]
    test_conventions: list[dict[str, Any]] = []
    by_pattern: dict[tuple[str, str], list[str]] = defaultdict(list)
    for test in tests:
        path = str(test.get("path", ""))
        language = str(test.get("language") or "")
        name = Path(path).name
        if name.endswith("_test.go"):
            by_pattern[(language, "*_test.go")].append(path)
        elif ".test." in name:
            by_pattern[(language, "*.test.*")].append(path)
            if language in {"javascript", "typescript"} and "tests" not in Path(path).parts:
                by_pattern[(language, "colocated test convention")].append(path)
        elif ".spec." in name:
            by_pattern[(language, "*.spec.*")].append(path)
            if language in {"javascript", "typescript"} and "tests" not in Path(path).parts:
                by_pattern[(language, "colocated test convention")].append(path)
        elif name.startswith("test_"):
            by_pattern[(language, "test_*.py")].append(path)
        elif name.endswith("_test.py"):
            by_pattern[(language, "*_test.py")].append(path)
        elif language == "csharp" and name.endswith("Tests.cs"):
            by_pattern[(language, "*Tests.cs")].append(path)
        elif "tests" in Path(path).parts:
            by_pattern[(language, "tests/ directory")].append(path)
    for rel, signals in sorted(file_text_signals.items()):
        language = language_for_path(rel)
        if language == "rust" and signals.get("hasInlineCfgTest"):
            by_pattern[(language, "inline #[cfg(test)]")].append(rel)
    for (language, pattern), evidence in sorted(by_pattern.items()):
        test_conventions.append(convention_entry("test-file-pattern", pattern, language or None, evidence))

    error_handling: list[dict[str, Any]] = []
    logging: list[dict[str, Any]] = []
    validation: list[dict[str, Any]] = []
    config: list[dict[str, Any]] = []
    go_conventions: list[dict[str, Any]] = []
    csharp_conventions: list[dict[str, Any]] = []
    tsjs_conventions: list[dict[str, Any]] = []
    rust_boundaries: list[dict[str, Any]] = []
    modules_by_path = {str(module.get("path")): module for module in modules}
    for rel, signals in sorted(file_text_signals.items()):
        language = language_for_path(rel)
        style_signals = signals.get("style") if isinstance(signals.get("style"), dict) else {}
        if style_signals.get("throwCatch"):
            error_handling.append(convention_entry("error-handling", "throw/catch", language, [rel]))
        if style_signals.get("tryExceptRaise"):
            error_handling.append(convention_entry("error-handling", "try/except/raise", language, [rel]))
        if style_signals.get("runtimeLoggingCall"):
            logging.append(convention_entry("logging", "runtime logging call", language, [rel]))
        if style_signals.get("environmentVariableAccess"):
            config.append(convention_entry("config", "environment variable access", language, [rel]))
        if language == "go" and go.is_test_path(rel):
            go_conventions.append(convention_entry("go-test-command", "go test", "go", [rel]))
            module = modules_by_path.get(rel, {})
            package_name = module.get("package") or signals.get("packageName")
            if package_name and not package_name.endswith("_test"):
                go_conventions.append(convention_entry("go-test-scope", "package-local tests", "go", [rel]))
        if language == "csharp" and Path(rel).suffix == ".cs":
            if Path(rel).name.endswith("Tests.cs"):
                csharp_conventions.append(convention_entry("test-file-pattern", "*Tests.cs", "csharp", [rel]))
            framework = signals.get("csharpTestFramework")
            if framework:
                csharp_conventions.append(convention_entry("test-framework", framework, "csharp", [rel]))
        if language in {"javascript", "typescript"}:
            framework = signals.get("testFramework")
            if framework:
                tsjs_conventions.append(convention_entry("test-framework", str(framework), language, [rel]))
            module = modules_by_path.get(rel, {})
            for hint in module.get("boundaryHints", []):
                if isinstance(hint, dict):
                    tsjs_conventions.append(
                        convention_entry(
                            "boundary",
                            str(hint.get("value") or hint.get("kind")),
                            language,
                            [rel],
                        )
                    )
        if language == "rust":
            if rel.endswith("/src/lib.rs") or rel == "src/lib.rs":
                rust_boundaries.append(convention_entry("boundary", "Rust library crate root", "rust", [rel]))
            if rel.endswith("/src/main.rs") or rel == "src/main.rs":
                rust_boundaries.append(convention_entry("boundary", "Rust binary crate root", "rust", [rel]))
            if "tests" in Path(rel).parts:
                rust_boundaries.append(convention_entry("boundary", "Rust integration tests directory", "rust", [rel]))

    for manifest in manifests:
        config.append(convention_entry("config", f"{manifest.get('kind')} manifest", manifest.get("language"), [str(manifest.get("path"))]))
        if manifest.get("kind") == "cargo" and manifest.get("workspaceMembers"):
            rust_boundaries.append(
                convention_entry(
                    "boundary",
                    "Cargo workspace members",
                    "rust",
                    [str(manifest.get("path"))] + [str(item) for item in manifest.get("workspaceMembers", [])],
                )
            )
        if manifest.get("kind") == "dotnet-solution":
            csharp_conventions.append(convention_entry("boundary", "C# solution", "csharp", [str(manifest.get("path"))]))
        if manifest.get("kind") == "dotnet-project":
            path = str(manifest.get("path"))
            if manifest.get("projectReferences"):
                csharp_conventions.append(convention_entry("project-reference", "ProjectReference", "csharp", [path]))
                rust_boundaries.append(convention_entry("boundary", "C# project references", "csharp", [path]))
            if manifest.get("isTestProject"):
                csharp_conventions.append(convention_entry("test-project", "*.Tests project or test packages", "csharp", [path]))
                rust_boundaries.append(convention_entry("boundary", "C# test project", "csharp", [path]))
            if str(manifest.get("outputType") or "").lower() == "exe":
                rust_boundaries.append(convention_entry("boundary", "C# executable project", "csharp", [path]))
            for hint in manifest.get("testPackageHints", []):
                if isinstance(hint, dict) and hint.get("framework"):
                    csharp_conventions.append(
                        convention_entry("test-framework", str(hint.get("framework")), "csharp", [path])
                    )
        if manifest.get("kind") == "npm-package":
            path = str(manifest.get("path"))
            package_name = str(manifest.get("packageName") or path)
            tsjs_conventions.append(convention_entry("boundary", f"npm package {package_name}", "javascript", [path]))
            if manifest.get("workspaces"):
                tsjs_conventions.append(convention_entry("boundary", "npm workspaces", "javascript", [path]))
            if manifest.get("bin"):
                tsjs_conventions.append(convention_entry("boundary", "package.json bin entrypoint", "javascript", [path]))
            for hint in manifest.get("testFrameworkHints", []):
                if isinstance(hint, dict) and hint.get("framework"):
                    tsjs_conventions.append(
                        convention_entry("test-framework", str(hint.get("framework")), "javascript", [path])
                    )
            for runtime in manifest.get("runtimeHints", []):
                tsjs_conventions.append(convention_entry("runtime", str(runtime), "javascript", [path]))
        if manifest.get("kind") in {"tsconfig", "jsconfig"}:
            path = str(manifest.get("path"))
            tsjs_conventions.append(convention_entry("boundary", str(manifest.get("kind")), "typescript", [path]))
            if manifest.get("paths"):
                tsjs_conventions.append(convention_entry("path-alias", "compilerOptions.paths", "typescript", [path]))
            if manifest.get("references"):
                tsjs_conventions.append(convention_entry("project-reference", "tsconfig references", "typescript", [path]))

    validation_paths: set[str] = set()
    for symbol in symbols:
        if set(symbol.get("tokens", [])) & VALIDATION_TOKENS:
            validation_paths.add(str(symbol.get("path")))
    for module in modules:
        path = str(module.get("path"))
        if set(module.get("tokens", [])) & VALIDATION_TOKENS:
            validation_paths.add(path)
        if module.get("language") == "go":
            for hint in module.get("boundaryHints", []):
                if isinstance(hint, dict):
                    go_conventions.append(
                        convention_entry(
                            "go-boundary",
                            str(hint.get("value") or hint.get("kind")),
                            "go",
                            [path],
                        )
                    )
    for path in sorted(validation_paths):
        validation.append(convention_entry("validation", "validation naming or helper", language_for_path(path), [path]))
    crate_local_paths = sorted(
        {
            str(symbol.get("path"))
            for symbol in symbols
            if str(symbol.get("language")) == "rust"
            and str(symbol.get("visibility") or "").startswith("pub(")
        }
    )
    for path in crate_local_paths:
        rust_boundaries.append(convention_entry("boundary", "Rust crate-local visibility", "rust", [path]))

    csharp_public_paths = sorted(
        {
            str(symbol.get("path"))
            for symbol in symbols
            if str(symbol.get("language")) == "csharp" and symbol.get("exported")
        }
    )
    for path in csharp_public_paths:
        csharp_conventions.append(convention_entry("api-visibility", "public API symbols", "csharp", [path]))
    csharp_internal_paths = sorted(
        {
            str(symbol.get("path"))
            for symbol in symbols
            if str(symbol.get("language")) == "csharp" and str(symbol.get("visibility") or "") == "internal"
        }
    )
    for path in csharp_internal_paths:
        csharp_conventions.append(convention_entry("api-visibility", "internal assembly-local symbols", "csharp", [path]))
        rust_boundaries.append(convention_entry("boundary", "C# internal assembly-local visibility", "csharp", [path]))

    compact_error_handling = compact_conventions(error_handling)
    compact_logging = compact_conventions(logging)
    compact_config = compact_conventions(config)
    compact_validation = compact_conventions(validation)
    compact_go_conventions = compact_conventions(go_conventions)
    compact_csharp_conventions = compact_conventions(csharp_conventions)
    compact_tsjs_conventions = compact_conventions(tsjs_conventions)
    compact_rust_boundaries = compact_conventions(rust_boundaries)
    confidence = 0.45
    for section in (test_conventions, compact_error_handling, compact_logging, compact_config, compact_validation, compact_go_conventions, compact_csharp_conventions, compact_tsjs_conventions, compact_rust_boundaries):
        if section:
            confidence += 0.08
    if primary_languages:
        confidence += 0.06

    return {
        "schemaVersion": "1.0",
        "generatedAt": generated_at,
        "projectRoot": project_root_arg,
        "confidence": round(min(0.95, confidence), 4),
        "primaryLanguages": primary_languages,
        "testConventions": test_conventions,
        "errorHandling": compact_error_handling,
        "logging": compact_logging,
        "config": compact_config,
        "validation": compact_validation,
        "goConventions": compact_go_conventions,
        "csharpConventions": compact_csharp_conventions,
        "typescriptJavascriptConventions": compact_tsjs_conventions,
        "boundaries": compact_rust_boundaries,
    }


def compact_conventions(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], set[str]] = defaultdict(set)
    for entry in entries:
        key = (
            str(entry.get("name") or ""),
            str(entry.get("value") or ""),
            str(entry.get("language") or ""),
        )
        for evidence in entry.get("evidence", []):
            grouped[key].add(str(evidence))
    return [
        convention_entry(name, value, language or None, sorted(evidence))
        for (name, value, language), evidence in sorted(grouped.items())
    ]


def collect_module_boundaries(modules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    boundaries: list[dict[str, Any]] = []
    for module in modules:
        for hint in module.get("boundaryHints", []):
            if not isinstance(hint, dict):
                continue
            entry = {
                "path": hint.get("path") or module.get("path"),
                "language": module.get("language"),
                "kind": hint.get("kind"),
                "value": hint.get("value"),
                "weak": hint.get("weak", False),
            }
            if hint.get("allowedRoot"):
                entry["allowedRoot"] = hint.get("allowedRoot")
            if hint.get("risk"):
                entry["risk"] = hint.get("risk")
            if hint.get("sourceProject"):
                entry["sourceProject"] = hint.get("sourceProject")
            boundaries.append(entry)
    return sorted(
        boundaries,
        key=lambda item: (str(item.get("path")), str(item.get("kind")), str(item.get("value"))),
    )


def final_test_info(
    rel: str,
    language: str | None,
    payload: dict[str, Any],
    csharp_project: dict[str, Any] | None,
) -> dict[str, Any]:
    base_info = payload.get("testInfo") if isinstance(payload.get("testInfo"), dict) else {}
    if language != "csharp":
        return clone_jsonable(base_info)

    test_functions = sorted(str(item) for item in base_info.get("testFunctions", []) if isinstance(item, str))
    frameworks = {str(base_info.get("framework"))} if base_info.get("framework") else set()
    if csharp_project:
        for package in csharp_project.get("packageReferences", []):
            framework = csharp.TEST_PACKAGE_FRAMEWORKS.get(str(package).lower())
            if framework:
                frameworks.add(framework)
    framework_order = ("xunit", "nunit", "mstest", "dotnet-test")
    framework = next((item for item in framework_order if item in frameworks), None)
    if framework is None and csharp_project and csharp_project.get("isTestProject"):
        framework = "dotnet-test"
    has_tests = bool(
        test_functions
        or frameworks
        or is_test_path(rel)
        or (csharp_project and csharp_project.get("isTestProject"))
    )
    return {
        "hasTests": has_tests,
        "framework": framework,
        "testFunctions": test_functions,
    }


def build_index(
    project_root_arg: str,
    generated_at: str,
    scan: ScanResult,
    extractions: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]:
    indexed_files = [file for file in scan.files if file.indexed]
    known_files = {file.rel for file in indexed_files}
    go_package_dirs = {
        Path(file.rel).parent.as_posix() if Path(file.rel).parent.as_posix() != "." else ""
        for file in indexed_files
        if file.language == "go" and file.rel.endswith(".go") and not is_test_fixture_path(file.rel)
    }
    file_text_signals: dict[str, dict[str, Any]] = {}
    modules: list[dict[str, Any]] = []
    symbols: list[dict[str, Any]] = []
    imports: list[dict[str, Any]] = []
    tests: list[dict[str, Any]] = []
    manifest_by_path: dict[str, dict[str, Any]] = {}
    for scanned_file in indexed_files:
        payload = extractions.get(scanned_file.rel, {})
        manifest = payload.get("manifest")
        if manifest:
            manifest_by_path[scanned_file.rel] = clone_jsonable(manifest)
    manifests: list[dict[str, Any]] = list(manifest_by_path.values())
    go_modules = go.collect_modules_from_manifests(manifests)
    rust_context = rust.build_context(manifests, known_files)
    csharp_context = csharp.build_context(manifests, known_files)
    typescript_context = typescript_js.build_context(manifests, known_files)
    csharp_project_by_path = csharp_context.get("projectByPath")
    if isinstance(csharp_project_by_path, dict):
        for manifest in manifests:
            if manifest.get("kind") != "dotnet-project":
                continue
            project = csharp_project_by_path.get(str(manifest.get("path") or ""))
            if isinstance(project, dict) and project.get("referencedBy"):
                manifest["referencedBy"] = project.get("referencedBy")
                manifest["projectReferenceFanIn"] = len(project.get("referencedBy", []))

    for scanned_file in indexed_files:
        rel = scanned_file.rel
        language = scanned_file.language
        payload = extractions.get(rel, {})
        signals = payload.get("fileTextSignals") if isinstance(payload.get("fileTextSignals"), dict) else {}
        file_text_signals[rel] = clone_jsonable(signals)
        kind = module_kind(rel)
        csharp_project = csharp.project_for_path(rel, csharp_context) if language == "csharp" else None
        if language == "csharp" and Path(rel).suffix == ".cs" and csharp_project and csharp_project.get("isTestProject"):
            kind = "test"
        package_name = signals.get("packageName") if language == "go" else None
        boundary_hints = go.boundary_hints_for_path(rel) if language == "go" or is_test_fixture_path(rel) else []
        module = {
            "path": rel,
            "name": Path(rel).stem,
            "directory": Path(rel).parent.as_posix() if Path(rel).parent.as_posix() != "." else "",
            "language": language,
            "kind": kind,
            "tokens": tokens_for_path(rel),
            "lineCount": int(signals.get("lineCount", 0)),
        }
        if isinstance(package_name, str) and package_name:
            module["package"] = package_name
        if language == "go" and kind == "test" and package_name:
            module["targetPackage"] = package_name[: -len("_test")] if package_name.endswith("_test") else package_name
        if language == "go" and boundary_hints:
            module["boundaryHints"] = boundary_hints
            module["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in boundary_hints)
        if language == "rust":
            module.update(rust.module_fields(rel, "", rust_context, signals))
        if language == "csharp":
            module.update(csharp.module_fields(rel, "", csharp_context, manifest_by_path.get(rel)))
        if language in {"javascript", "typescript", "json", "yaml"}:
            module.update(typescript_js.module_fields(rel, typescript_context))
        if is_test_fixture_path(rel):
            module["testFixture"] = True
        modules.append(module)
        symbols.extend(clone_jsonable(payload.get("symbols", [])))
        for import_record in clone_jsonable(payload.get("imports", [])):
            spec = str(import_record.get("imported") or "")
            if not spec:
                continue
            resolved_path = resolve_import(
                rel,
                spec,
                known_files,
                language=language,
                go_modules=go_modules,
                go_package_dirs=go_package_dirs,
                rust_context=rust_context,
                csharp_context=csharp_context,
                typescript_context=typescript_context,
            )
            item = {
                "path": rel,
                "language": language,
                "imported": spec,
                "resolvedPath": resolved_path,
                "tokens": import_record.get("tokens", sorted(set(split_identifier(spec)))),
            }
            for key in ("alias", "importKind", "kind", "visibility", "exported", "line", "static", "global"):
                if key in import_record:
                    item[key] = import_record.get(key)
            for key in ("symbols",):
                if key in import_record:
                    item[key] = import_record.get(key)
            imports.append(item)
        test_info = final_test_info(rel, language, payload, csharp_project)
        if kind == "test" or test_info.get("hasTests"):
            test_entry = {
                "path": rel,
                "language": language,
                "framework": test_info.get("framework"),
                "tokens": sorted(set(tokens_for_path(rel)) | ({"test"} if language == "rust" else set())),
            }
            if language == "go":
                if isinstance(package_name, str) and package_name:
                    test_entry["package"] = package_name
                    test_entry["targetPackage"] = package_name[: -len("_test")] if package_name.endswith("_test") else package_name
            if test_info.get("testFunctions"):
                test_entry["testFunctions"] = test_info["testFunctions"]
            if test_info.get("hasCfgTest"):
                test_entry["inlineCfgTest"] = True
            if language == "csharp" and csharp_project:
                test_entry["projectPath"] = csharp_project.get("path")
                test_entry["projectName"] = csharp_project.get("projectName")
            tests.append(test_entry)

    importers_by_target: dict[str, list[str]] = defaultdict(list)
    for item in imports:
        resolved = item.get("resolvedPath")
        if isinstance(resolved, str) and resolved:
            importers_by_target[resolved].append(str(item.get("path")))

    tests_by_path = {str(test.get("path")): test for test in tests}
    for module in modules:
        path = str(module.get("path"))
        imported_by = sorted(set(importers_by_target.get(path, [])))
        if imported_by:
            module["importedBy"] = imported_by
            module["importCount"] = len(imported_by)
        paired_tests = paired_tests_for(path, tests)
        if paired_tests and (path not in tests_by_path or tests_by_path.get(path, {}).get("inlineCfgTest")):
            module["pairedTests"] = paired_tests

    typescript_js.update_package_usage(modules, manifests, imports, typescript_context)

    modules.extend(go.build_package_modules(modules, symbols, tests, importers_by_target))
    modules.extend(csharp.build_project_modules(modules, symbols, tests, importers_by_target, csharp_context))

    symbols_by_path: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for symbol in symbols:
        symbols_by_path[str(symbol.get("path"))].append(symbol)

    rust.update_module_boundaries(modules, symbols_by_path)
    csharp.update_module_boundaries(modules, symbols_by_path)

    shared_candidates: list[dict[str, Any]] = []
    for module in modules:
        path = str(module.get("path"))
        parts = set(Path(path).parts)
        if module.get("language") == "go" and module.get("kind") != "package":
            continue
        if module.get("language") == "go" and module.get("kind") == "package":
            exported_symbols = [
                symbol
                for symbol in module.get("symbols", [])
                if isinstance(symbol, str)
            ]
        elif module.get("language") == "csharp" and module.get("kind") == "project":
            exported_symbols = [
                symbol
                for symbol in module.get("symbols", [])
                if isinstance(symbol, str)
            ]
        else:
            exported_symbols = [
                symbol.get("name")
                for symbol in symbols_by_path.get(path, [])
                if symbol.get("exported") and isinstance(symbol.get("name"), str)
        ]
        reasons = []
        if parts & SHARED_DIR_HINTS:
            if module.get("language") in {"javascript", "typescript"}:
                reasons.append("shared-directory-name-weak")
            else:
                reasons.append("shared-directory-name")
        if module.get("language") == "go" and module.get("weakReusablePackageConvention"):
            reasons.append("go-pkg-weak-convention")
        if module.get("language") == "go" and module.get("internalBoundary"):
            reasons.append("go-internal-boundary")
        if module.get("language") == "csharp" and module.get("projectReferenceCount", 0):
            reasons.append("project-referenced-by-local-projects")
        if module.get("language") == "csharp" and module.get("internalAssemblyLocal"):
            reasons.append("internal-assembly-boundary")
        if module.get("language") in {"javascript", "typescript"} and module.get("workspacePackageReferenced"):
            reasons.append("workspace-package")
        if module.get("language") in {"javascript", "typescript"} and module.get("packageImportCount", 0):
            reasons.append("package-name-import")
        if module.get("language") in {"javascript", "typescript"} and module.get("tsconfigPathReferenced"):
            reasons.append("tsconfig-path-reference")
        if module.get("importCount", 0):
            reasons.append("imported-by-local-files")
        if module.get("pairedTests"):
            reasons.append("paired-test")
        if exported_symbols:
            reasons.append("exported-symbols")
        if module.get("language") == "go" and module.get("kind") == "package":
            if module.get("entrypointBoundary") and not module.get("importCount", 0):
                continue
            has_primary_shared_signal = bool(
                module.get("importCount", 0)
                or module.get("pairedTests")
                or exported_symbols
            )
        elif module.get("language") == "rust":
            if module.get("workspaceMember"):
                reasons.append("workspace-member")
            has_primary_shared_signal = bool(
                exported_symbols
                or module.get("importCount", 0)
                or module.get("pairedTests")
            )
        elif module.get("language") == "csharp":
            if module.get("isTestProject"):
                continue
            if module.get("executableBoundary") and not (
                module.get("projectReferenceCount", 0)
                or module.get("importCount", 0) > 1
            ):
                continue
            has_primary_shared_signal = bool(
                module.get("projectReferenceCount", 0)
                or module.get("importCount", 0)
                or module.get("pairedTests")
                or exported_symbols
            )
        elif module.get("language") in {"javascript", "typescript"}:
            if module.get("executableBoundary") and not (
                module.get("importCount", 0) > 1
                or module.get("packageImportCount", 0) > 1
            ):
                continue
            has_primary_shared_signal = bool(
                exported_symbols
                or module.get("importCount", 0)
                or module.get("pairedTests")
            )
        else:
            has_primary_shared_signal = bool((parts & SHARED_DIR_HINTS) or module.get("importCount", 0) or module.get("pairedTests"))
        if not has_primary_shared_signal:
            continue
        if module.get("kind") not in {"source", "support", "package", "project"}:
            continue
        candidate = {
            "path": path,
            "language": module.get("language"),
            "symbols": sorted(exported_symbols),
            "usageCount": int(module.get("importCount", 0)),
            "importedBy": module.get("importedBy", []),
            "pairedTests": module.get("pairedTests", []),
            "reasons": reasons,
            "tokens": module.get("tokens", []),
        }
        if module.get("language") == "go":
            for key in ("package", "boundaryHints", "boundaryKinds", "internalBoundary", "weakReusablePackageConvention", "publicAPICandidate"):
                if key in module:
                    candidate[key] = module.get(key)
        if module.get("language") == "rust":
            for key in ("crateName", "crateRoot", "packageName", "boundaryHints", "boundaryKinds", "workspaceMember", "crateLocalSymbols"):
                if key in module:
                    candidate[key] = module.get(key)
            if module.get("crateLocalSymbols"):
                candidate["visibilityRisks"] = ["pub(crate)/pub(super) symbols are crate-local"]
        if module.get("language") == "csharp":
            for key in (
                "projectName",
                "projectPath",
                "assemblyName",
                "rootNamespace",
                "projectReferences",
                "projectReferenceCount",
                "boundaryHints",
                "boundaryKinds",
                "internalSymbols",
                "internalAssemblyLocal",
                "executableBoundary",
                "publicAPICandidate",
            ):
                if key in module:
                    candidate[key] = module.get(key)
            if module.get("internalSymbols"):
                candidate["visibilityRisks"] = ["internal symbols are assembly-local"]
        if module.get("language") in {"javascript", "typescript"}:
            for key in (
                "packageName",
                "packageRoot",
                "packageType",
                "packageImportedBy",
                "packageImportCount",
                "boundaryHints",
                "boundaryKinds",
                "workspaceMember",
                "workspacePackageReferenced",
                "tsconfigPath",
                "tsconfigPathReferenced",
                "tsconfigPathImportedBy",
                "executableBoundary",
            ):
                if key in module:
                    candidate[key] = module.get(key)
        shared_candidates.append(candidate)

    symbol_name_counts = Counter(str(symbol.get("name")) for symbol in symbols if symbol.get("name"))
    duplicate_fingerprints = []
    for name, count in sorted(symbol_name_counts.items()):
        if count < 2:
            continue
        paths = sorted(str(symbol.get("path")) for symbol in symbols if symbol.get("name") == name)
        duplicate_fingerprints.append(
            {
                "fingerprint": f"symbol-name:{name}",
                "symbol": name,
                "paths": paths,
                "count": count,
                "reason": "same symbol name appears in multiple files",
            }
        )

    conventions = {
        "testPaths": sorted(str(test.get("path")) for test in tests),
        "sharedDirectoryNames": sorted(
            {
                part
                for module in modules
                for part in Path(str(module.get("path"))).parts
                if part in SHARED_DIR_HINTS
            }
        ),
        "validationPaths": sorted(
            {
                str(module.get("path"))
                for module in modules
                if set(module.get("tokens", [])) & VALIDATION_TOKENS
            }
        ),
        "goInternalPackages": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("language") == "go" and module.get("internalBoundary")
        ),
        "goCommandEntrypoints": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("language") == "go" and module.get("entrypointBoundary")
        ),
        "goReusablePackageDirs": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("language") == "go" and module.get("weakReusablePackageConvention")
        ),
        "goTestdataPaths": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("testFixture")
        ),
        "goPublicAPICandidates": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("language") == "go" and module.get("publicAPICandidate")
        ),
        "rustBoundaryPaths": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("language") == "rust" and module.get("boundaryHints")
        ),
        "csharpProjectPaths": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("language") == "csharp" and module.get("kind") == "project"
        ),
        "csharpProjectReferences": sorted(
            str(module.get("projectPath"))
            for module in modules
            if module.get("language") == "csharp" and module.get("kind") == "project" and module.get("projectReferences")
        ),
        "csharpTestProjects": sorted(
            str(module.get("projectPath"))
            for module in modules
            if module.get("language") == "csharp" and module.get("isTestProject")
        ),
        "csharpExecutableProjects": sorted(
            str(module.get("projectPath"))
            for module in modules
            if module.get("language") == "csharp" and module.get("executableBoundary")
        ),
        "typescriptJavascriptPackagePaths": sorted(
            str(manifest.get("path"))
            for manifest in manifests
            if manifest.get("kind") == "npm-package"
        ),
        "typescriptJavascriptConfigPaths": sorted(
            str(manifest.get("path"))
            for manifest in manifests
            if manifest.get("kind") in {"tsconfig", "jsconfig"}
        ),
        "typescriptJavascriptCliEntrypoints": sorted(
            str(module.get("path"))
            for module in modules
            if module.get("language") in {"javascript", "typescript"} and module.get("executableBoundary")
        ),
    }
    module_boundaries = collect_module_boundaries(modules)

    language_counts = Counter(
        str(module.get("language"))
        for module in modules
        if module.get("kind") in {"source", "test"} and module.get("language") in SOURCE_LANGUAGES
    )
    primary_languages = [
        language for language, _count in sorted(language_counts.items(), key=lambda item: (-item[1], item[0]))
    ]
    language_detections = [
        {"language": language, "fileCount": count}
        for language, count in sorted(language_counts.items(), key=lambda item: (-item[1], item[0]))
    ]
    scan_stats = {
        "fileCount": scan.scan_stats["filesSeen"],
        "sourceFileCount": sum(1 for module in modules if module.get("kind") == "source"),
        "testFileCount": len(tests),
        "symbolCount": len(symbols),
        "importCount": len(imports),
        "manifestCount": len(manifests),
        "sharedCandidateCount": len(shared_candidates),
        "filesSeen": scan.scan_stats["filesSeen"],
        "filesIndexed": scan.scan_stats["filesIndexed"],
        "filesReused": scan.scan_stats.get("filesReused", 0),
        "filesExtracted": scan.scan_stats.get("filesExtracted", 0),
        "filesSkipped": scan.scan_stats["filesSkipped"],
        "bytesIndexed": scan.scan_stats["bytesIndexed"],
        "truncated": scan.scan_stats["truncated"],
    }
    if scan.scan_stats.get("notes"):
        scan_stats["notes"] = scan.scan_stats["notes"]
    portable_root = portable_project_root(project_root_arg)

    codebase_index = {
        "schemaVersion": "1.0",
        "generatedAt": generated_at,
        "scanMode": INDEX_SCAN_MODE,
        "projectRoot": portable_root,
        "primaryLanguages": primary_languages,
        "languageDetections": language_detections,
        "sharedCandidates": sorted(shared_candidates, key=lambda item: str(item.get("path"))),
        "symbols": sorted(symbols, key=lambda item: (str(item.get("path")), str(item.get("name")))),
        "modules": sorted(modules, key=lambda item: str(item.get("path"))),
        "imports": sorted(imports, key=lambda item: (str(item.get("path")), str(item.get("imported")))),
        "tests": sorted(tests, key=lambda item: str(item.get("path"))),
        "conventions": conventions,
        "moduleBoundaries": module_boundaries,
        "duplicateFingerprints": duplicate_fingerprints,
        "manifests": sorted(manifests, key=lambda item: str(item.get("path"))),
        "scanStats": scan_stats,
        "unsupportedFilesSummary": scan.unsupported_files_summary,
    }
    style_profile = build_style_profile(generated_at, portable_root, modules, symbols, manifests, file_text_signals)
    digest_cache = build_digest_cache(generated_at, portable_root, scan)
    extracts_cache = build_extracts_cache(generated_at, portable_root, scan, extractions)
    return codebase_index, style_profile, digest_cache, extracts_cache


def build_digest_cache(generated_at: str, project_root_arg: str, scan: ScanResult) -> dict[str, Any]:
    files: dict[str, dict[str, Any]] = {}
    for scanned_file in sorted(scan.files, key=lambda item: item.rel):
        files[scanned_file.rel] = {
            "sha256": scanned_file.sha256,
            "sizeBytes": scanned_file.size_bytes,
            "mtimeNs": scanned_file.mtime_ns,
            "language": scanned_file.language,
            "indexed": scanned_file.indexed,
            "reason": scanned_file.reason,
        }

    cache: dict[str, Any] = {
        "schemaVersion": "1.0",
        "generatedAt": generated_at,
        "projectRoot": project_root_arg,
        "scanMode": DIGEST_SCAN_MODE,
        "files": files,
        "scanStats": scan.scan_stats,
    }
    if scan.unsupported_files_summary:
        cache["unsupportedFilesSummary"] = scan.unsupported_files_summary
    return cache


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_previous_digests(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def load_previous_extracts(path: Path | None) -> tuple[dict[str, Any], str | None]:
    if path is None or not path.exists():
        return {}, None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}, "previous-extracts ignored: invalid or unreadable JSON"
    if not isinstance(data, dict):
        return {}, "previous-extracts ignored: invalid top-level value"
    return data, None


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    project_root = Path(args.project_root).resolve()
    if not project_root.is_dir():
        print(f"Project root not found: {args.project_root}", file=sys.stderr)
        return 1
    generated_at = args.generated_at or utc_now()
    previous_digests_path = project_root / args.previous_digests if args.previous_digests else None
    load_previous_digests(previous_digests_path)
    previous_extracts_path = project_root / args.previous_extracts if args.previous_extracts else None
    previous_extracts, previous_extracts_note = load_previous_extracts(previous_extracts_path)
    scan = build_scan(
        project_root,
        max_files=args.max_files,
        max_bytes=args.max_bytes,
        max_file_size=args.max_file_size,
    )
    if previous_extracts_note:
        scan_stats_add_note(scan.scan_stats, previous_extracts_note)
    extractions = build_extractions(scan, previous_extracts)
    codebase_index, style_profile, digest_cache, extracts_cache = build_index(args.project_root, generated_at, scan, extractions)
    write_json(project_root / args.output, codebase_index)
    write_json(project_root / args.style_output, style_profile)
    if args.digests_output:
        write_json(project_root / args.digests_output, digest_cache)
    if args.extracts_output:
        write_json(project_root / args.extracts_output, extracts_cache)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
