#!/usr/bin/env python3
"""Build local deterministic codebase awareness scanner artifacts.

This is intentionally shallow: it records file, symbol, import, test, manifest,
and convention signals that later deterministic steps can explain. It does not
parse ASTs or call external tools.
"""

from __future__ import annotations

import argparse
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

DEFAULT_MAX_FILES = 10_000
DEFAULT_MAX_BYTES = 50_000_000
DEFAULT_MAX_FILE_SIZE = 1_048_576
TEXT_EXTRACTION_LIMIT = 800_000
INDEX_SCAN_MODE = "shallow-regex-v1"
DIGEST_SCAN_MODE = "lexical-symbol"

IGNORE_DIRS = {
    ".git",
    ".signum",
    ".venv",
    ".mypy_cache",
    ".pytest_cache",
    "__pycache__",
    "bin",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "obj",
    "target",
    "venv",
}
GENERATED_MARKER_RE = re.compile(r"(@generated|auto-generated|do not edit|generated)", re.IGNORECASE)

LANGUAGE_BY_SUFFIX = {
    ".cjs": "javascript",
    ".cts": "typescript",
    ".go": "go",
    ".js": "javascript",
    ".jsx": "javascript",
    ".json": "json",
    ".mjs": "javascript",
    ".mts": "typescript",
    ".py": "python",
    ".rs": "rust",
    ".sh": "shell",
    ".toml": "toml",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".yaml": "yaml",
    ".yml": "yaml",
}

SOURCE_LANGUAGES = {"go", "javascript", "python", "rust", "shell", "typescript"}
MANIFEST_NAMES = {
    "Cargo.toml": "cargo",
    "go.mod": "go",
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
    return any(part in IGNORE_DIRS for part in parts)


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


def language_for_path(rel: str) -> str | None:
    path = Path(rel)
    if path.name in MANIFEST_NAMES:
        return {
            "cargo": "toml",
            "go": "go",
            "npm": "json" if path.suffix == ".json" else "yaml",
            "python": "toml" if path.suffix == ".toml" else "python",
        }.get(MANIFEST_NAMES[path.name])
    return LANGUAGE_BY_SUFFIX.get(path.suffix)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_binary_data(data: bytes) -> bool:
    return b"\0" in data[:4096]


def has_generated_marker(data: bytes) -> bool:
    try:
        prefix = data[:8192].decode("utf-8", errors="replace")
    except OSError:
        return False
    return bool(GENERATED_MARKER_RE.search(prefix))


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


def split_identifier(value: str) -> list[str]:
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", value)
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", value)
    return [part.lower() for part in re.split(r"[^A-Za-z0-9]+", value) if part]


def tokens_for_path(rel: str) -> list[str]:
    return sorted(set(split_identifier(rel)))


def is_test_path(rel: str) -> bool:
    path = Path(rel)
    name = path.name
    parts = set(path.parts)
    return (
        "test" in parts
        or "tests" in parts
        or name.startswith("test_")
        or name.endswith("_test.py")
        or ".test." in name
        or ".spec." in name
    )


def module_kind(rel: str) -> str:
    if Path(rel).name in MANIFEST_NAMES:
        return "manifest"
    if is_test_path(rel):
        return "test"
    if language_for_path(rel) in SOURCE_LANGUAGES:
        return "source"
    return "support"


def extract_symbols(rel: str, language: str | None, text: str) -> list[dict[str, Any]]:
    patterns: list[tuple[str, str, str]] = []
    if language in {"javascript", "typescript"}:
        patterns = [
            ("function", r"^\s*export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\b", "exported"),
            ("class", r"^\s*export\s+class\s+([A-Za-z_$][\w$]*)\b", "exported"),
            ("constant", r"^\s*export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)\b", "exported"),
            ("function", r"^\s*(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\b", "local"),
            ("class", r"^\s*class\s+([A-Za-z_$][\w$]*)\b", "local"),
            ("constant", r"^\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=", "local"),
        ]
    elif language == "python":
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


def resolve_import(source_rel: str, spec: str, known_files: set[str]) -> str | None:
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
    normalized = []
    for candidate in candidates:
        parts: list[str] = []
        for part in candidate.split("/"):
            if part in {"", "."}:
                continue
            if part == "..":
                if parts:
                    parts.pop()
                continue
            parts.append(part)
        normalized.append("/".join(parts))
    for candidate in normalized:
        if candidate in known_files:
            return candidate
    return None


def test_framework_for_path(rel: str, text: str, language: str | None) -> str | None:
    if language in {"javascript", "typescript"}:
        if re.search(r"\bdescribe\s*\(|\bit\s*\(|\btest\s*\(", text):
            return "jest-or-vitest"
        return "javascript-test"
    if language == "python":
        if "pytest" in text or Path(rel).name.startswith("test_"):
            return "pytest"
        return "python-test"
    if language == "shell":
        return "shell"
    return None


def paired_tests_for(rel: str, tests: list[dict[str, Any]]) -> list[str]:
    stem = Path(rel).stem
    if stem.endswith(".test") or stem.endswith(".spec"):
        stem = stem.rsplit(".", 1)[0]
    pairs: list[str] = []
    for test in tests:
        test_path = str(test.get("path", ""))
        if stem and stem in tokens_for_path(test_path):
            pairs.append(test_path)
    return sorted(set(pairs))


def extract_manifest(rel: str, text: str) -> dict[str, Any] | None:
    path = Path(rel)
    if path.name not in MANIFEST_NAMES:
        return None
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": MANIFEST_NAMES[path.name],
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
    file_text: dict[str, str],
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
        if ".test." in name:
            by_pattern[(language, "*.test.*")].append(path)
        elif ".spec." in name:
            by_pattern[(language, "*.spec.*")].append(path)
        elif name.startswith("test_"):
            by_pattern[(language, "test_*.py")].append(path)
        elif name.endswith("_test.py"):
            by_pattern[(language, "*_test.py")].append(path)
        elif "tests" in Path(path).parts:
            by_pattern[(language, "tests/ directory")].append(path)
    for (language, pattern), evidence in sorted(by_pattern.items()):
        test_conventions.append(convention_entry("test-file-pattern", pattern, language or None, evidence))

    error_handling: list[dict[str, Any]] = []
    logging: list[dict[str, Any]] = []
    validation: list[dict[str, Any]] = []
    config: list[dict[str, Any]] = []
    for rel, text in sorted(file_text.items()):
        language = language_for_path(rel)
        if re.search(r"\bthrow\s+new\s+Error\b|\btry\s*\{|\bcatch\s*\(", text):
            error_handling.append(convention_entry("error-handling", "throw/catch", language, [rel]))
        if re.search(r"^\s*(try:|except\b|raise\b)", text, flags=re.MULTILINE):
            error_handling.append(convention_entry("error-handling", "try/except/raise", language, [rel]))
        if re.search(r"\bconsole\.(log|warn|error)\b|\blogger\.|\blogging\.getLogger\b", text):
            logging.append(convention_entry("logging", "runtime logging call", language, [rel]))
        if re.search(r"\b(process\.env|os\.environ|getenv)\b", text):
            config.append(convention_entry("config", "environment variable access", language, [rel]))

    for manifest in manifests:
        config.append(convention_entry("config", f"{manifest.get('kind')} manifest", manifest.get("language"), [str(manifest.get("path"))]))

    validation_paths: set[str] = set()
    for symbol in symbols:
        if set(symbol.get("tokens", [])) & VALIDATION_TOKENS:
            validation_paths.add(str(symbol.get("path")))
    for module in modules:
        path = str(module.get("path"))
        if set(module.get("tokens", [])) & VALIDATION_TOKENS:
            validation_paths.add(path)
    for path in sorted(validation_paths):
        validation.append(convention_entry("validation", "validation naming or helper", language_for_path(path), [path]))

    compact_error_handling = compact_conventions(error_handling)
    compact_logging = compact_conventions(logging)
    compact_config = compact_conventions(config)
    compact_validation = compact_conventions(validation)
    confidence = 0.45
    for section in (test_conventions, compact_error_handling, compact_logging, compact_config, compact_validation):
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


def build_index(
    project_root_arg: str,
    generated_at: str,
    scan: ScanResult,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    indexed_files = [file for file in scan.files if file.indexed]
    known_files = {file.rel for file in indexed_files}
    file_text: dict[str, str] = {}
    modules: list[dict[str, Any]] = []
    symbols: list[dict[str, Any]] = []
    imports: list[dict[str, Any]] = []
    tests: list[dict[str, Any]] = []
    manifests: list[dict[str, Any]] = []

    for scanned_file in indexed_files:
        rel = scanned_file.rel
        language = scanned_file.language
        text = scanned_file.text
        if text:
            file_text[rel] = text
        kind = module_kind(rel)
        module = {
            "path": rel,
            "name": Path(rel).stem,
            "directory": Path(rel).parent.as_posix() if Path(rel).parent.as_posix() != "." else "",
            "language": language,
            "kind": kind,
            "tokens": tokens_for_path(rel),
            "lineCount": len(text.splitlines()) if text else 0,
        }
        modules.append(module)
        file_symbols = extract_symbols(rel, language, text)
        symbols.extend(file_symbols)
        for spec in extract_import_specs(language, text):
            imports.append(
                {
                    "path": rel,
                    "language": language,
                    "imported": spec,
                    "resolvedPath": resolve_import(rel, spec, known_files),
                    "tokens": sorted(set(split_identifier(spec))),
                }
            )
        if kind == "test":
            tests.append(
                {
                    "path": rel,
                    "language": language,
                    "framework": test_framework_for_path(rel, text, language),
                    "tokens": tokens_for_path(rel),
                }
            )
        manifest = extract_manifest(rel, text)
        if manifest:
            manifests.append(manifest)

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
        if paired_tests and path not in tests_by_path:
            module["pairedTests"] = paired_tests

    symbols_by_path: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for symbol in symbols:
        symbols_by_path[str(symbol.get("path"))].append(symbol)

    shared_candidates: list[dict[str, Any]] = []
    for module in modules:
        path = str(module.get("path"))
        parts = set(Path(path).parts)
        exported_symbols = [
            symbol.get("name")
            for symbol in symbols_by_path.get(path, [])
            if symbol.get("exported") and isinstance(symbol.get("name"), str)
        ]
        reasons = []
        if parts & SHARED_DIR_HINTS:
            reasons.append("shared-directory-name")
        if module.get("importCount", 0):
            reasons.append("imported-by-local-files")
        if module.get("pairedTests"):
            reasons.append("paired-test")
        has_primary_shared_signal = bool((parts & SHARED_DIR_HINTS) or module.get("importCount", 0) or module.get("pairedTests"))
        if not has_primary_shared_signal:
            continue
        if exported_symbols:
            reasons.append("exported-symbols")
        if module.get("kind") not in {"source", "support"}:
            continue
        shared_candidates.append(
            {
                "path": path,
                "language": module.get("language"),
                "symbols": sorted(exported_symbols),
                "usageCount": int(module.get("importCount", 0)),
                "importedBy": module.get("importedBy", []),
                "pairedTests": module.get("pairedTests", []),
                "reasons": reasons,
                "tokens": module.get("tokens", []),
            }
        )

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
    }

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
        "duplicateFingerprints": duplicate_fingerprints,
        "manifests": sorted(manifests, key=lambda item: str(item.get("path"))),
        "scanStats": scan_stats,
        "unsupportedFilesSummary": scan.unsupported_files_summary,
    }
    style_profile = build_style_profile(generated_at, portable_root, modules, symbols, manifests, file_text)
    digest_cache = build_digest_cache(generated_at, portable_root, scan)
    return codebase_index, style_profile, digest_cache


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


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    project_root = Path(args.project_root).resolve()
    if not project_root.is_dir():
        print(f"Project root not found: {args.project_root}", file=sys.stderr)
        return 1
    generated_at = args.generated_at or utc_now()
    previous_digests_path = project_root / args.previous_digests if args.previous_digests else None
    load_previous_digests(previous_digests_path)
    scan = build_scan(
        project_root,
        max_files=args.max_files,
        max_bytes=args.max_bytes,
        max_file_size=args.max_file_size,
    )
    codebase_index, style_profile, digest_cache = build_index(args.project_root, generated_at, scan)
    write_json(project_root / args.output, codebase_index)
    write_json(project_root / args.style_output, style_profile)
    if args.digests_output:
        write_json(project_root / args.digests_output, digest_cache)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
