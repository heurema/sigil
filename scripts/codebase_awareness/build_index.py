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
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11 fallback
    tomllib = None

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
MANIFEST_NAMES = {
    "Cargo.lock": "cargo-lock",
    "Cargo.toml": "cargo",
    "go.mod": "go",
    "go.work": "go-work",
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
GO_TEST_FUNCTION_RE = re.compile(r"^\s*func\s+((?:Test|Benchmark|Fuzz)[A-Za-z0-9_]*)\s*\(", re.MULTILINE)
CSHARP_TEST_PACKAGE_FRAMEWORKS = {
    "microsoft.net.test.sdk": "dotnet-test",
    "mstest.testframework": "mstest",
    "nunit": "nunit",
    "xunit": "xunit",
}
CSHARP_EXTERNAL_NAMESPACE_PREFIXES = ("Microsoft.", "Newtonsoft.", "System.")


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
    if path.name in MANIFEST_NAMES:
        return MANIFEST_NAMES[path.name]
    if path.suffix == ".sln":
        return "dotnet-solution"
    if path.suffix == ".csproj":
        return "dotnet-project"
    if path.name == "Directory.Build.props" or path.suffix == ".props":
        return "dotnet-props"
    if path.name == "Directory.Build.targets" or path.suffix == ".targets":
        return "dotnet-targets"
    return None


def language_for_path(rel: str) -> str | None:
    path = Path(rel)
    manifest_kind = manifest_kind_for_path(rel)
    if manifest_kind:
        return {
            "cargo": "toml",
            "cargo-lock": "toml",
            "dotnet-project": "csharp",
            "dotnet-props": "csharp",
            "dotnet-solution": "csharp",
            "dotnet-targets": "csharp",
            "go": "go",
            "go-work": "go",
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
        or name.endswith("Test.cs")
        or name.endswith("Tests.cs")
        or name.endswith("_test.go")
        or name.endswith("_test.py")
        or name.endswith("_test.rs")
        or ".test." in name
        or ".spec." in name
    )


def is_go_test_path(rel: str) -> bool:
    return Path(rel).name.endswith("_test.go")


def is_test_fixture_path(rel: str) -> bool:
    return "testdata" in Path(rel).parts


def module_kind(rel: str) -> str:
    if manifest_kind_for_path(rel):
        return "manifest"
    if is_test_path(rel):
        return "test"
    if language_for_path(rel) in SOURCE_LANGUAGES:
        return "source"
    return "support"


def is_exported_go_identifier(name: str) -> bool:
    return bool(name) and "A" <= name[0] <= "Z"


def extract_go_package_name(text: str) -> str | None:
    match = re.search(r"^\s*package\s+([A-Za-z_][A-Za-z0-9_]*)\b", text, flags=re.MULTILINE)
    return match.group(1) if match else None


def normalize_go_receiver(receiver: str) -> str | None:
    receiver = receiver.strip()
    if not receiver:
        return None
    parts = receiver.split()
    raw_type = parts[-1] if parts else receiver
    raw_type = raw_type.lstrip("*")
    raw_type = raw_type.split(".")[-1]
    raw_type = raw_type.split("[", 1)[0]
    raw_type = re.sub(r"[^A-Za-z0-9_]", "", raw_type)
    return raw_type or None


def go_symbol_entry(
    *,
    name: str,
    kind: str,
    rel: str,
    line_number: int,
    receiver: str | None = None,
) -> dict[str, Any]:
    tokens = set(split_identifier(name))
    if receiver:
        tokens.update(split_identifier(receiver))
    return {
        "name": name,
        "kind": kind,
        "language": "go",
        "path": rel,
        "line": line_number,
        "exported": is_exported_go_identifier(name),
        "tokens": sorted(tokens),
        "receiver": receiver,
    }


def extract_go_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    symbols: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str | None]] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        func_match = re.search(
            r"^\s*func\s+(?:\((?P<receiver>[^)]*)\)\s*)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(",
            line,
        )
        if func_match:
            receiver = normalize_go_receiver(func_match.group("receiver") or "")
            name = func_match.group("name")
            kind = "method" if receiver else "function"
            key = (kind, name, receiver)
            if key not in seen:
                seen.add(key)
                symbols.append(
                    go_symbol_entry(
                        name=name,
                        kind=kind,
                        rel=rel,
                        line_number=line_number,
                        receiver=receiver,
                    )
                )
            continue

        type_match = re.search(r"^\s*type\s+([A-Za-z_][A-Za-z0-9_]*)\b", line)
        if type_match:
            name = type_match.group(1)
            key = ("type", name, None)
            if key not in seen:
                seen.add(key)
                symbols.append(go_symbol_entry(name=name, kind="type", rel=rel, line_number=line_number))
            continue

        value_match = re.search(r"^\s*(const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b", line)
        if value_match:
            kind = "constant" if value_match.group(1) == "const" else "variable"
            name = value_match.group(2)
            key = (kind, name, None)
            if key not in seen:
                seen.add(key)
                symbols.append(go_symbol_entry(name=name, kind=kind, rel=rel, line_number=line_number))
            continue

        grouped_value_match = re.search(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|[A-Za-z_\*])", line)
        if grouped_value_match and symbols:
            previous_kind = symbols[-1].get("kind")
            if previous_kind in {"constant", "variable"}:
                name = grouped_value_match.group(1)
                key = (str(previous_kind), name, None)
                if key not in seen:
                    seen.add(key)
                    symbols.append(
                        go_symbol_entry(
                            name=name,
                            kind=str(previous_kind),
                            rel=rel,
                            line_number=line_number,
                        )
                    )
    return symbols


def parse_toml_document(text: str) -> dict[str, Any]:
    if tomllib is not None:
        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            data = {}
        if isinstance(data, dict):
            return data
    return parse_toml_fallback(text)


def parse_toml_fallback(text: str) -> dict[str, Any]:
    data: dict[str, Any] = {}
    section: list[str] = []
    array_section: tuple[list[str], dict[str, Any]] | None = None
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[[") and line.endswith("]]"):
            section = [part.strip() for part in line[2:-2].split(".") if part.strip()]
            container = data
            for part in section[:-1]:
                child = container.setdefault(part, {})
                if not isinstance(child, dict):
                    child = {}
                    container[part] = child
                container = child
            entries = container.setdefault(section[-1], [])
            if not isinstance(entries, list):
                entries = []
                container[section[-1]] = entries
            item: dict[str, Any] = {}
            entries.append(item)
            array_section = (section, item)
            continue
        if line.startswith("[") and line.endswith("]"):
            section = [part.strip() for part in line[1:-1].split(".") if part.strip()]
            array_section = None
            continue
        if "=" not in line:
            continue
        key, value = [part.strip() for part in line.split("=", 1)]
        parsed: Any
        if value.startswith('"') and value.endswith('"'):
            parsed = value[1:-1]
        elif value.startswith("[") and value.endswith("]"):
            parsed = [
                item.strip().strip('"').strip("'")
                for item in value[1:-1].split(",")
                if item.strip()
            ]
        else:
            parsed = value.strip('"').strip("'")

        if array_section is not None and array_section[0] == section:
            array_section[1][key] = parsed
            continue
        container = data
        for part in section:
            child = container.setdefault(part, {})
            if not isinstance(child, dict):
                child = {}
                container[part] = child
            container = child
        container[key] = parsed
    return data


def normalize_rust_visibility(raw: str | None) -> str:
    if not raw:
        return "private"
    compact = re.sub(r"\s+", " ", raw.strip())
    compact = compact.replace("pub (", "pub(")
    compact = re.sub(r"\(\s+", "(", compact)
    compact = re.sub(r"\s+\)", ")", compact)
    return compact


def rust_visibility_exported(visibility: str) -> bool:
    return visibility == "pub"


def rust_line_without_comment(line: str) -> str:
    return line.split("//", 1)[0]


def rust_brace_delta(line: str) -> int:
    stripped = rust_line_without_comment(line)
    return stripped.count("{") - stripped.count("}")


def rust_impl_type(line: str) -> str | None:
    pattern = re.compile(
        r"""
        ^\s*impl
        (?:\s*<[^>{}]*>)?
        \s+
        (?:
          [A-Za-z_][\w:<>]*
          \s+for\s+
        )?
        (?P<type>[A-Za-z_][\w:]*)
        (?:\s*<[^>{}]*>)?
        (?:\s+where\b.*)?
        \s*\{
        """,
        re.VERBOSE,
    )
    match = pattern.search(line)
    if not match:
        return None
    return match.group("type").split("::")[-1]


def rust_symbol_record(
    *,
    rel: str,
    line_number: int,
    kind: str,
    name: str,
    visibility: str,
    impl_type: str | None = None,
    test_only: bool = False,
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "language": "rust",
        "path": rel,
        "line": line_number,
        "exported": rust_visibility_exported(visibility),
        "visibility": visibility,
        "tokens": sorted(set(split_identifier(name))),
    }
    if impl_type:
        record["implType"] = impl_type
        record["tokens"] = sorted(set(record["tokens"]) | set(split_identifier(impl_type)))
    if test_only:
        record["testOnly"] = True
    return record


def extract_rust_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    vis = r"(?P<vis>pub(?:\s*\([^)]*\))?)?"
    fn_pattern = re.compile(
        rf"^\s*{vis}\s*(?:(?:async|unsafe|const)\s+)*fn\s+(?P<name>[A-Za-z_][\w]*)\b"
    )
    type_pattern = re.compile(
        rf"^\s*{vis}\s*(?P<kind>struct|enum|trait|type)\s+(?P<name>[A-Za-z_][\w]*)\b"
    )
    const_pattern = re.compile(
        rf"^\s*{vis}\s*(?P<kind>const|static)\s+(?P<name>[A-Za-z_][\w]*)\b"
    )
    mod_pattern = re.compile(
        rf"^\s*{vis}\s*mod\s+(?P<name>[A-Za-z_][\w]*)\s*(?:;|\{{)"
    )
    cfg_test_re = re.compile(r"#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]")
    test_attr_re = re.compile(r"#\s*\[\s*(?:(?:tokio|async_std)::)?test\s*\]")
    symbols: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    brace_depth = 0
    impl_stack: list[tuple[int, str]] = []
    test_module_stack: list[int] = []
    pending_cfg_test = False
    pending_test_attr = False

    for line_number, line in enumerate(text.splitlines(), start=1):
        while impl_stack and brace_depth < impl_stack[-1][0]:
            impl_stack.pop()
        while test_module_stack and brace_depth < test_module_stack[-1]:
            test_module_stack.pop()

        if cfg_test_re.search(line):
            pending_cfg_test = True
            brace_depth += rust_brace_delta(line)
            continue

        if test_attr_re.search(line):
            pending_test_attr = True
            brace_depth += rust_brace_delta(line)
            continue

        cfg_test_item = pending_cfg_test
        pending_cfg_test = False
        test_mod_line = bool(cfg_test_item and re.search(r"^\s*(?:pub\s+)?mod\s+[A-Za-z_][\w]*\s*\{", line))
        if test_mod_line:
            test_module_stack.append(brace_depth + 1)
        test_attr_item = pending_test_attr
        pending_test_attr = False
        in_test_module = bool(test_module_stack) or cfg_test_item or test_attr_item

        impl_type = rust_impl_type(line)
        if impl_type and not in_test_module:
            impl_stack.append((brace_depth + 1, impl_type))
        active_impl = impl_stack[-1][1] if impl_stack and brace_depth >= impl_stack[-1][0] else None

        if not in_test_module:
            for pattern, default_kind in (
                (fn_pattern, "function"),
                (type_pattern, None),
                (const_pattern, None),
                (mod_pattern, "module"),
            ):
                match = pattern.search(line)
                if not match:
                    continue
                name = match.group("name")
                visibility = normalize_rust_visibility(match.groupdict().get("vis"))
                kind = default_kind or match.group("kind")
                if kind == "fn":
                    kind = "function"
                if kind == "const":
                    kind = "constant"
                if kind == "static":
                    kind = "static"
                if kind == "function" and active_impl:
                    kind = "method"
                key = (kind, name, active_impl or "")
                if key in seen:
                    continue
                seen.add(key)
                symbols.append(
                    rust_symbol_record(
                        rel=rel,
                        line_number=line_number,
                        kind=kind,
                        name=name,
                        visibility=visibility,
                        impl_type=active_impl if kind == "method" else None,
                    )
                )
                break

        brace_depth += rust_brace_delta(line)
        while impl_stack and brace_depth < impl_stack[-1][0]:
            impl_stack.pop()
        while test_module_stack and brace_depth < test_module_stack[-1]:
            test_module_stack.pop()
    return symbols


def csharp_line_without_comment(line: str) -> str:
    in_string = False
    escaped = False
    quote = ""
    for index, char in enumerate(line):
        if in_string:
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == quote:
                in_string = False
                quote = ""
            continue
        if char in {"\"", "'"}:
            in_string = True
            quote = char
            continue
        if char == "/" and index + 1 < len(line) and line[index + 1] == "/":
            return line[:index]
    return line


def csharp_brace_delta(line: str) -> int:
    stripped = csharp_line_without_comment(line)
    return stripped.count("{") - stripped.count("}")


def normalize_csharp_visibility(modifiers: str, default_visibility: str) -> str:
    words = set(re.findall(r"\b(public|internal|private|protected)\b", modifiers))
    if "private" in words and "protected" in words:
        return "private protected"
    if "protected" in words and "internal" in words:
        return "protected internal"
    for visibility in ("public", "internal", "private", "protected"):
        if visibility in words:
            return visibility
    return default_visibility


def csharp_visibility_exported(visibility: str) -> bool:
    return visibility == "public"


def csharp_visibility_risk(visibility: str) -> str | None:
    if visibility == "internal":
        return "C# internal symbol is assembly-local and may not be reusable across project boundaries"
    if visibility == "protected internal":
        return "C# protected internal symbol is constrained by assembly or inheritance boundaries"
    if visibility == "private protected":
        return "C# private protected symbol is constrained to derived types in the same assembly"
    if visibility == "protected":
        return "C# protected symbol is inheritance-scoped"
    if visibility == "private":
        return "C# private symbol is not reusable outside its containing type"
    return None


def csharp_symbol_record(
    *,
    rel: str,
    line_number: int,
    kind: str,
    name: str,
    visibility: str,
    namespace: str | None,
    container: str | None = None,
    is_static: bool = False,
) -> dict[str, Any]:
    tokens = set(split_identifier(name))
    if container:
        tokens.update(split_identifier(container))
    record: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "language": "csharp",
        "path": rel,
        "line": line_number,
        "exported": csharp_visibility_exported(visibility),
        "visibility": visibility,
        "static": is_static,
        "tokens": sorted(tokens),
    }
    if namespace:
        record["namespace"] = namespace
    if container:
        record["container"] = container
    risk = csharp_visibility_risk(visibility)
    if risk:
        record["visibilityRisks"] = [risk]
    return record


def extract_csharp_namespaces(rel: str, text: str) -> list[dict[str, Any]]:
    namespaces: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = csharp_line_without_comment(line)
        match = re.search(r"^\s*namespace\s+([A-Za-z_][\w.]*)\s*(?:[;{]|$)", stripped)
        if not match:
            continue
        namespace = match.group(1)
        if namespace in seen:
            continue
        seen.add(namespace)
        namespaces.append(
            csharp_symbol_record(
                rel=rel,
                line_number=line_number,
                kind="namespace",
                name=namespace,
                visibility="public",
                namespace=namespace,
            )
        )
    return namespaces


def extract_csharp_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    symbols = extract_csharp_namespaces(rel, text)
    modifier_words = (
        "public|internal|private|protected|static|sealed|abstract|partial|readonly|"
        "ref|unsafe|new|virtual|override|async|extern|required|const"
    )
    modifiers = rf"(?P<mods>(?:(?:{modifier_words})\s+)*)"
    type_pattern = re.compile(
        rf"^\s*{modifiers}(?P<kind>record\s+struct|record\s+class|class|record|struct|interface|enum)\s+"
        rf"(?P<name>[A-Za-z_][\w]*)\b"
    )
    constructor_pattern = re.compile(rf"^\s*{modifiers}(?P<name>[A-Za-z_][\w]*)\s*\(")
    method_pattern = re.compile(
        rf"^\s*{modifiers}(?P<return>[A-Za-z_][\w.<>,?\[\]]*(?:\s*<[^;=(){{}}]+>)?)\s+"
        rf"(?P<name>[A-Za-z_][\w]*)\s*(?:<[^;=(){{}}]+>)?\s*\("
    )
    property_pattern = re.compile(
        rf"^\s*{modifiers}(?P<type>[A-Za-z_][\w.<>,?\[\]]*)\s+"
        rf"(?P<name>[A-Za-z_][\w]*)\s*\{{[^}}]*(?:get|set|init)\b"
    )
    field_pattern = re.compile(
        rf"^\s*{modifiers}(?P<type>[A-Za-z_][\w.<>,?\[\]]*)\s+"
        rf"(?P<name>[A-Za-z_][\w]*)\s*(?:=|;)"
    )
    namespace_pattern = re.compile(r"^\s*namespace\s+([A-Za-z_][\w.]*)\s*(?:[;{]|$)")
    control_words = {"catch", "for", "foreach", "if", "lock", "switch", "using", "while"}
    seen: set[tuple[str, str, str | None]] = {
        ("namespace", str(symbol.get("name")), None) for symbol in symbols
    }
    brace_depth = 0
    type_stack: list[tuple[int, str]] = []
    pending_type: tuple[str, int] | None = None
    current_namespace: str | None = None

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        while type_stack and brace_depth < type_stack[-1][0]:
            type_stack.pop()
        line = csharp_line_without_comment(raw_line)
        stripped = line.strip()
        if not stripped or stripped.startswith("["):
            brace_depth += csharp_brace_delta(line)
            continue

        namespace_match = namespace_pattern.search(line)
        if namespace_match:
            current_namespace = namespace_match.group(1)

        if pending_type and "{" in line:
            type_stack.append((brace_depth + 1, pending_type[0]))
            pending_type = None

        type_match = type_pattern.search(line)
        if type_match:
            raw_kind = re.sub(r"\s+", " ", type_match.group("kind").strip())
            kind = "record" if raw_kind.startswith("record") else raw_kind
            name = type_match.group("name")
            visibility = normalize_csharp_visibility(type_match.group("mods") or "", "internal")
            key = (kind, name, type_stack[-1][1] if type_stack else None)
            if key not in seen:
                seen.add(key)
                symbols.append(
                    csharp_symbol_record(
                        rel=rel,
                        line_number=line_number,
                        kind=kind,
                        name=name,
                        visibility=visibility,
                        namespace=current_namespace,
                        container=type_stack[-1][1] if type_stack else None,
                        is_static=bool(re.search(r"\bstatic\b", type_match.group("mods") or "")),
                    )
                )
            if "{" in line:
                type_stack.append((brace_depth + 1, name))
            elif not stripped.endswith(";"):
                pending_type = (name, brace_depth + 1)
            brace_depth += csharp_brace_delta(line)
            continue

        container = type_stack[-1][1] if type_stack else None
        if container:
            constructor_match = constructor_pattern.search(line)
            if constructor_match and constructor_match.group("name") == container:
                visibility = normalize_csharp_visibility(constructor_match.group("mods") or "", "private")
                key = ("constructor", container, container)
                if key not in seen:
                    seen.add(key)
                    symbols.append(
                        csharp_symbol_record(
                            rel=rel,
                            line_number=line_number,
                            kind="constructor",
                            name=container,
                            visibility=visibility,
                            namespace=current_namespace,
                            container=container,
                            is_static=bool(re.search(r"\bstatic\b", constructor_match.group("mods") or "")),
                        )
                    )
                brace_depth += csharp_brace_delta(line)
                continue

            property_match = property_pattern.search(line)
            if property_match:
                name = property_match.group("name")
                visibility = normalize_csharp_visibility(property_match.group("mods") or "", "private")
                key = ("property", name, container)
                if key not in seen:
                    seen.add(key)
                    symbols.append(
                        csharp_symbol_record(
                            rel=rel,
                            line_number=line_number,
                            kind="property",
                            name=name,
                            visibility=visibility,
                            namespace=current_namespace,
                            container=container,
                            is_static=bool(re.search(r"\bstatic\b", property_match.group("mods") or "")),
                        )
                    )
                brace_depth += csharp_brace_delta(line)
                continue

            method_match = method_pattern.search(line)
            if method_match and method_match.group("name") not in control_words:
                name = method_match.group("name")
                visibility = normalize_csharp_visibility(method_match.group("mods") or "", "private")
                key = ("method", name, container)
                if key not in seen:
                    seen.add(key)
                    symbols.append(
                        csharp_symbol_record(
                            rel=rel,
                            line_number=line_number,
                            kind="method",
                            name=name,
                            visibility=visibility,
                            namespace=current_namespace,
                            container=container,
                            is_static=bool(re.search(r"\bstatic\b", method_match.group("mods") or "")),
                        )
                    )
                brace_depth += csharp_brace_delta(line)
                continue

            if "(" not in line and not stripped.startswith(("return ", "throw ")):
                field_match = field_pattern.search(line)
                if field_match:
                    name = field_match.group("name")
                    mods = field_match.group("mods") or ""
                    visibility = normalize_csharp_visibility(mods, "private")
                    kind = "constant" if re.search(r"\bconst\b", mods) else "field"
                    key = (kind, name, container)
                    if key not in seen:
                        seen.add(key)
                        symbols.append(
                            csharp_symbol_record(
                                rel=rel,
                                line_number=line_number,
                                kind=kind,
                                name=name,
                                visibility=visibility,
                                namespace=current_namespace,
                                container=container,
                                is_static=bool(re.search(r"\bstatic\b", mods)),
                            )
                        )

        brace_depth += csharp_brace_delta(line)
        while type_stack and brace_depth < type_stack[-1][0]:
            type_stack.pop()
    return symbols


def extract_symbols(rel: str, language: str | None, text: str) -> list[dict[str, Any]]:
    if language == "csharp" and Path(rel).suffix == ".cs":
        return extract_csharp_symbols(rel, text)
    if language == "go":
        return extract_go_symbols(rel, text)
    if language == "rust":
        return extract_rust_symbols(rel, text)

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


def strip_go_line_comment(line: str) -> str:
    in_string = False
    escaped = False
    quote = ""
    for index, char in enumerate(line):
        if in_string:
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == quote:
                in_string = False
                quote = ""
            continue
        if char in {"\"", "`"}:
            in_string = True
            quote = char
            continue
        if char == "/" and index + 1 < len(line) and line[index + 1] == "/":
            return line[:index]
    return line


def parse_go_import_line(line: str) -> dict[str, Any] | None:
    line = strip_go_line_comment(line).strip().rstrip(";")
    if not line or line == ")":
        return None
    match = re.match(
        r"^(?:(?P<alias>\.|\_|[A-Za-z_][A-Za-z0-9_]*)\s+)?(?P<quote>\"[^\"]+\"|`[^`]+`)$",
        line,
    )
    if not match:
        return None
    alias = match.group("alias")
    imported = match.group("quote")[1:-1]
    if alias == "_":
        import_kind = "blank"
    elif alias == ".":
        import_kind = "dot"
    elif alias:
        import_kind = "aliased"
    else:
        import_kind = "package"
    return {
        "imported": imported,
        "alias": alias,
        "importKind": import_kind,
        "tokens": sorted(set(split_identifier(imported))),
    }


def extract_go_import_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    in_block = False
    for line in text.splitlines():
        stripped = strip_go_line_comment(line).strip()
        if not in_block:
            single = re.match(r"^import\s+(?!\()(.*)$", stripped)
            if single:
                record = parse_go_import_line(single.group(1))
                if record:
                    records.append(record)
                continue
            if re.match(r"^import\s*\($", stripped):
                in_block = True
                continue
        else:
            if stripped.startswith(")"):
                in_block = False
                continue
            record = parse_go_import_line(stripped)
            if record:
                records.append(record)
    unique: dict[tuple[str, str | None], dict[str, Any]] = {}
    for record in records:
        unique[(str(record.get("imported")), record.get("alias"))] = record
    return [unique[key] for key in sorted(unique)]


def split_top_level_commas(value: str) -> list[str]:
    items: list[str] = []
    depth = 0
    start = 0
    for index, char in enumerate(value):
        if char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
        elif char == "," and depth == 0:
            item = value[start:index].strip()
            if item:
                items.append(item)
            start = index + 1
    item = value[start:].strip()
    if item:
        items.append(item)
    return items


def find_matching_brace(value: str, start: int) -> int | None:
    depth = 0
    for index in range(start, len(value)):
        char = value[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def clean_rust_use_spec(spec: str) -> str:
    spec = re.sub(r"\s+as\s+[A-Za-z_][\w]*$", "", spec.strip())
    spec = spec.strip(":")
    spec = re.sub(r"\s+", "", spec)
    return spec


def expand_rust_use_tree(value: str) -> list[str]:
    value = value.strip()
    brace_index = value.find("{")
    if brace_index == -1:
        cleaned = clean_rust_use_spec(value)
        return [cleaned] if cleaned else []
    end = find_matching_brace(value, brace_index)
    if end is None:
        cleaned = clean_rust_use_spec(value)
        return [cleaned] if cleaned else []

    prefix = value[:brace_index]
    suffix = value[end + 1 :]
    inner = value[brace_index + 1 : end]
    expanded: list[str] = []
    for item in split_top_level_commas(inner):
        for child in expand_rust_use_tree(item):
            if child == "self":
                combined = prefix.rstrip(":")
            elif prefix.endswith("::"):
                combined = f"{prefix}{child}"
            elif prefix:
                combined = f"{prefix}::{child}"
            else:
                combined = child
            combined = clean_rust_use_spec(f"{combined}{suffix}")
            if combined:
                expanded.append(combined)
    return sorted(set(expanded))


def extract_rust_import_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    use_pattern = re.compile(r"^\s*(?P<vis>pub(?:\s*\([^)]*\))?)?\s*use\s+(?P<body>[^;]+);")
    mod_pattern = re.compile(r"^\s*(?P<vis>pub(?:\s*\([^)]*\))?)?\s*mod\s+(?P<name>[A-Za-z_][\w]*)\s*(?:;|\{)")
    seen: set[tuple[str, str, int]] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        use_match = use_pattern.search(line)
        if use_match:
            visibility = normalize_rust_visibility(use_match.group("vis"))
            kind = "pub use" if visibility == "pub" else "use"
            for spec in expand_rust_use_tree(use_match.group("body")):
                key = (kind, spec, line_number)
                if key in seen:
                    continue
                seen.add(key)
                records.append(
                    {
                        "imported": spec,
                        "kind": kind,
                        "visibility": visibility,
                        "exported": visibility == "pub",
                        "tokens": sorted(set(split_identifier(spec))),
                        "line": line_number,
                    }
                )
            continue

        mod_match = mod_pattern.search(line)
        if mod_match:
            visibility = normalize_rust_visibility(mod_match.group("vis"))
            name = mod_match.group("name")
            key = ("mod", name, line_number)
            if key in seen:
                continue
            seen.add(key)
            records.append(
                {
                    "imported": name,
                    "kind": "mod",
                    "visibility": visibility,
                    "exported": visibility == "pub",
                    "tokens": sorted(set(split_identifier(name))),
                    "line": line_number,
                }
            )
    return sorted(records, key=lambda item: (int(item.get("line", 0)), str(item.get("imported"))))


def extract_csharp_import_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    pattern = re.compile(
        r"""
        ^\s*
        (?P<global>global\s+)?
        using\s+
        (?P<static>static\s+)?
        (?:
          (?P<alias>[A-Za-z_][\w]*)\s*=\s*
        )?
        (?P<imported>[A-Za-z_][\w.]*)
        \s*;
        """,
        re.MULTILINE | re.VERBOSE,
    )
    seen: set[tuple[str, str | None, bool, bool]] = set()
    for match in pattern.finditer(text):
        imported = match.group("imported")
        alias = match.group("alias")
        is_static = bool(match.group("static"))
        is_global = bool(match.group("global"))
        key = (imported, alias, is_static, is_global)
        if key in seen:
            continue
        seen.add(key)
        record: dict[str, Any] = {
            "imported": imported,
            "kind": "using",
            "alias": alias,
            "static": is_static,
            "global": is_global,
            "tokens": sorted(set(split_identifier(imported))),
        }
        records.append(record)
    return sorted(records, key=lambda item: (str(item.get("imported")), str(item.get("alias") or "")))


def extract_import_records(language: str | None, text: str) -> list[dict[str, Any]]:
    if language == "csharp":
        return extract_csharp_import_records(text)
    if language == "go":
        return extract_go_import_records(text)
    if language == "rust":
        return extract_rust_import_records(text)
    return [
        {
            "imported": spec,
            "tokens": sorted(set(split_identifier(spec))),
        }
        for spec in extract_import_specs(language, text)
    ]


def normalize_rel_parts(value: str) -> str:
    parts: list[str] = []
    for part in value.split("/"):
        if part in {"", "."}:
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/".join(parts)


def parse_go_mod_module_path(text: str) -> str | None:
    match = re.search(r"^\s*module\s+([^\s]+)", text, flags=re.MULTILINE)
    return match.group(1) if match else None


def parse_go_work_uses(text: str) -> list[str]:
    uses: list[str] = []
    in_block = False
    for line in text.splitlines():
        stripped = strip_go_line_comment(line).strip()
        if not stripped:
            continue
        if in_block:
            if stripped.startswith(")"):
                in_block = False
                continue
            value = stripped.strip("\"`")
            if value:
                uses.append(value)
            continue
        match = re.match(r"^use\s+(.+)$", stripped)
        if not match:
            continue
        rest = match.group(1).strip()
        if rest.startswith("("):
            in_block = True
            rest = rest[1:].strip()
            if not rest:
                continue
        if rest and rest != ")":
            uses.append(rest.strip("\"`"))
    return sorted(set(uses))


def local_xml_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def parse_xml_document(text: str) -> ET.Element | None:
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        return None


def xml_children_text(root: ET.Element, name: str) -> list[str]:
    values: list[str] = []
    for element in root.iter():
        if local_xml_name(element.tag) != name:
            continue
        text = (element.text or "").strip()
        if text:
            values.append(text)
    return values


def parse_sln_projects(text: str) -> list[dict[str, str]]:
    projects: list[dict[str, str]] = []
    pattern = re.compile(
        r'^\s*Project\("\{[^"]+\}"\)\s*=\s*"(?P<name>[^"]+)",\s*"(?P<path>[^"]+)",\s*"\{[^"]+\}"',
        re.MULTILINE,
    )
    for match in pattern.finditer(text):
        project_path = match.group("path").replace("\\", "/")
        if not project_path.endswith(".csproj"):
            continue
        projects.append(
            {
                "name": match.group("name"),
                "path": normalize_rel_parts(project_path),
            }
        )
    return sorted(projects, key=lambda item: (item["path"], item["name"]))


def normalize_msbuild_include(base_dir: str, include: str) -> str:
    include = include.replace("\\", "/")
    if not base_dir:
        return normalize_rel_parts(include)
    return normalize_rel_parts(f"{base_dir}/{include}")


def parse_dotnet_project(rel: str, text: str) -> dict[str, Any]:
    path = Path(rel)
    base_dir = path.parent.as_posix()
    if base_dir == ".":
        base_dir = ""
    root = parse_xml_document(text)
    target_frameworks: list[str] = []
    output_type: str | None = None
    assembly_name: str | None = None
    root_namespace: str | None = None
    project_references: list[str] = []
    package_references: list[dict[str, str]] = []
    package_names: list[str] = []
    is_packable_values: list[str] = []
    explicit_test_project_values: list[str] = []

    if root is not None:
        target_frameworks.extend(xml_children_text(root, "TargetFramework"))
        for value in xml_children_text(root, "TargetFrameworks"):
            target_frameworks.extend(item.strip() for item in value.split(";") if item.strip())
        output_values = xml_children_text(root, "OutputType")
        if output_values:
            output_type = output_values[0]
        assembly_values = xml_children_text(root, "AssemblyName")
        if assembly_values:
            assembly_name = assembly_values[0]
        root_namespace_values = xml_children_text(root, "RootNamespace")
        if root_namespace_values:
            root_namespace = root_namespace_values[0]
        is_packable_values = xml_children_text(root, "IsPackable")
        explicit_test_project_values = xml_children_text(root, "IsTestProject")
        for element in root.iter():
            tag = local_xml_name(element.tag)
            if tag == "ProjectReference":
                include = element.attrib.get("Include") or element.attrib.get("Update")
                if include:
                    project_references.append(normalize_msbuild_include(base_dir, include))
            elif tag == "PackageReference":
                include = element.attrib.get("Include") or element.attrib.get("Update")
                if not include:
                    continue
                version = element.attrib.get("Version")
                if not version:
                    for child in element:
                        if local_xml_name(child.tag) == "Version" and child.text:
                            version = child.text.strip()
                            break
                package_record = {"include": include}
                if version:
                    package_record["version"] = version
                package_references.append(package_record)
                package_names.append(include)

    project_name = path.stem
    lower_packages = {package.lower() for package in package_names}
    is_test_project = (
        project_name.endswith(".Tests")
        or "tests" in path.parts
        or any(CSHARP_TEST_PACKAGE_FRAMEWORKS.get(package) for package in lower_packages)
        or any(value.lower() == "true" for value in explicit_test_project_values)
    )
    tokens = set(tokens_for_path(rel))
    for value in [project_name, assembly_name or "", root_namespace or "", output_type or ""]:
        tokens.update(split_identifier(value))
    tokens.update(token for package in package_names for token in split_identifier(package))
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": "dotnet-project",
        "language": "csharp",
        "projectName": project_name,
        "assemblyName": assembly_name or project_name,
        "targetFrameworks": sorted(set(target_frameworks)),
        "projectReferences": sorted(set(project_references)),
        "packageReferences": sorted(set(package_names)),
        "isTestProject": is_test_project,
        "tokens": sorted(tokens),
    }
    if root_namespace:
        manifest["rootNamespace"] = root_namespace
    if output_type:
        manifest["outputType"] = output_type
    if package_references:
        manifest["packageReferenceDetails"] = sorted(
            package_references,
            key=lambda item: (str(item.get("include")), str(item.get("version", ""))),
        )
    test_packages = sorted(
        package for package in lower_packages if package in CSHARP_TEST_PACKAGE_FRAMEWORKS
    )
    if test_packages:
        manifest["testPackageHints"] = [
            {"package": package, "framework": CSHARP_TEST_PACKAGE_FRAMEWORKS[package]}
            for package in test_packages
        ]
    if is_packable_values:
        manifest["isPackable"] = is_packable_values[0]
    return manifest


def parse_dotnet_props_targets(rel: str, text: str, kind: str) -> dict[str, Any]:
    root = parse_xml_document(text)
    properties: set[str] = set()
    item_types: set[str] = set()
    if root is not None:
        for element in root.iter():
            name = local_xml_name(element.tag)
            if name in {"Project", "PropertyGroup", "ItemGroup"}:
                continue
            if element.attrib:
                item_types.add(name)
            elif (element.text or "").strip():
                properties.add(name)
    tokens = set(tokens_for_path(rel))
    tokens.update(token for value in properties | item_types for token in split_identifier(value))
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": kind,
        "language": "csharp",
        "tokens": sorted(tokens),
    }
    if properties:
        manifest["properties"] = sorted(properties)
    if item_types:
        manifest["itemTypes"] = sorted(item_types)
    return manifest


def collect_go_modules(indexed_files: list[ScanFile]) -> list[tuple[str, str]]:
    modules: list[tuple[str, str]] = []
    for scanned_file in indexed_files:
        if Path(scanned_file.rel).name != "go.mod":
            continue
        module_path = parse_go_mod_module_path(scanned_file.text)
        if not module_path:
            continue
        directory = Path(scanned_file.rel).parent.as_posix()
        modules.append(("" if directory == "." else directory, module_path))
    return sorted(modules, key=lambda item: (-len(item[1]), item[0], item[1]))


def resolve_go_import(
    spec: str,
    go_modules: list[tuple[str, str]],
    go_package_dirs: set[str],
) -> str | None:
    for module_dir, module_path in go_modules:
        if spec == module_path:
            candidate = module_dir
        elif spec.startswith(f"{module_path}/"):
            suffix = spec[len(module_path) + 1 :]
            candidate = normalize_rel_parts(f"{module_dir}/{suffix}" if module_dir else suffix)
        else:
            continue
        if candidate in go_package_dirs:
            return candidate or "."
    return None


def rust_src_root(crate: dict[str, Any] | None) -> str:
    if not crate:
        return "src"
    root = str(crate.get("root") or "")
    return f"{root}/src" if root else "src"


def rust_crate_for_path(rel: str, rust_context: dict[str, Any]) -> dict[str, Any] | None:
    crates = rust_context.get("crates")
    if not isinstance(crates, list):
        return None
    matches = []
    for crate in crates:
        if not isinstance(crate, dict):
            continue
        root = str(crate.get("root") or "")
        if not root or rel == root or rel.startswith(f"{root}/"):
            matches.append(crate)
    if not matches:
        return None
    return sorted(matches, key=lambda item: len(str(item.get("root") or "")), reverse=True)[0]


def rust_module_path_candidates(base_dir: str, module_parts: list[str]) -> list[str]:
    candidates: list[str] = []
    for count in range(len(module_parts), -1, -1):
        parts = module_parts[:count]
        if not parts:
            candidates.extend(
                [
                    f"{base_dir}/lib.rs",
                    f"{base_dir}/main.rs",
                    f"{base_dir}/mod.rs",
                ]
            )
            continue
        module_path = "/".join(parts)
        candidates.extend(
            [
                f"{base_dir}/{module_path}.rs",
                f"{base_dir}/{module_path}/mod.rs",
                f"{base_dir}/{module_path}/lib.rs",
            ]
        )
    return [normalize_rel_parts(candidate) for candidate in candidates]


def resolve_rust_import(
    source_rel: str,
    imported: str,
    known_files: set[str],
    rust_context: dict[str, Any],
) -> str | None:
    if not imported:
        return None
    parts = [part for part in imported.split("::") if part and part not in {"*"}]
    if not parts:
        return None
    crate = rust_crate_for_path(source_rel, rust_context)
    crate_by_name = rust_context.get("crateByName")
    if not isinstance(crate_by_name, dict):
        crate_by_name = {}

    first = parts[0]
    rest = parts[1:]
    if first == "crate":
        base = rust_src_root(crate)
        module_parts = rest
    elif first == "self":
        base = Path(source_rel).parent.as_posix()
        module_parts = rest
    elif first == "super":
        base = Path(source_rel).parent.parent.as_posix()
        module_parts = rest
    elif first in crate_by_name:
        target = crate_by_name[first]
        base = rust_src_root(target if isinstance(target, dict) else None)
        module_parts = rest
    elif crate:
        base = rust_src_root(crate)
        module_parts = parts
    else:
        return None

    for candidate in rust_module_path_candidates(base, module_parts):
        if candidate in known_files:
            return candidate
    return None


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
) -> str | None:
    if language == "csharp":
        if isinstance(csharp_context, dict):
            return resolve_csharp_import(source_rel, spec, csharp_context)
        return None
    if language == "go":
        return resolve_go_import(spec, go_modules, go_package_dirs)
    if language == "rust":
        if isinstance(rust_context, dict):
            return resolve_rust_import(source_rel, spec, known_files, rust_context)
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
        if re.search(r"\[(?:Fact|Theory)\b", text):
            return "xunit"
        if re.search(r"\[(?:Test|TestCase|TestFixture)\b", text):
            return "nunit"
        if re.search(r"\[(?:TestMethod|TestClass)\b", text):
            return "mstest"
        if is_test_path(rel):
            return "dotnet-test"
        return None
    if language == "go" and is_go_test_path(rel):
        return "go-test"
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
    if language == "rust":
        if "#[tokio::test]" in text:
            return "tokio-test"
        if "#[async_std::test]" in text:
            return "async-std-test"
        return "rust-test"
    return None


def csharp_test_info(
    rel: str,
    text: str,
    language: str | None,
    project: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if language != "csharp" or Path(rel).suffix != ".cs":
        return {"hasTests": False, "framework": None, "testFunctions": []}
    package_frameworks: set[str] = set()
    if project:
        for package in project.get("packageReferences", []):
            framework = CSHARP_TEST_PACKAGE_FRAMEWORKS.get(str(package).lower())
            if framework:
                package_frameworks.add(framework)

    attr_frameworks: set[str] = set()
    test_functions: list[str] = []
    pending_attr: str | None = None
    attr_pattern = re.compile(r"\[(?P<attr>Fact|Theory|Test|TestCase|TestFixture|TestMethod|TestClass)\b")
    method_pattern = re.compile(
        r"^\s*(?:(?:public|internal|private|protected|static|async|virtual|override|sealed|new)\s+)*"
        r"(?:[A-Za-z_][\w.<>,?\[\]]+\s+)?(?P<name>[A-Za-z_][\w]*)\s*\("
    )
    for line in text.splitlines():
        attr_match = attr_pattern.search(line)
        if attr_match:
            attr = attr_match.group("attr")
            if attr in {"Fact", "Theory"}:
                attr_frameworks.add("xunit")
                pending_attr = attr
            elif attr in {"Test", "TestCase", "TestFixture"}:
                attr_frameworks.add("nunit")
                if attr != "TestFixture":
                    pending_attr = attr
            elif attr in {"TestMethod", "TestClass"}:
                attr_frameworks.add("mstest")
                if attr == "TestMethod":
                    pending_attr = attr
            continue
        if pending_attr:
            method_match = method_pattern.search(line)
            if method_match:
                test_functions.append(method_match.group("name"))
                pending_attr = None
                continue
            if line.strip() and not line.strip().startswith("["):
                pending_attr = None

    frameworks = attr_frameworks | package_frameworks
    framework_order = ("xunit", "nunit", "mstest", "dotnet-test")
    framework = next((item for item in framework_order if item in frameworks), None)
    if framework is None and (project and project.get("isTestProject")):
        framework = "dotnet-test"
    has_tests = bool(test_functions or frameworks or is_test_path(rel) or (project and project.get("isTestProject")))
    return {
        "hasTests": has_tests,
        "framework": framework,
        "testFunctions": sorted(set(test_functions)),
    }


def rust_test_info(rel: str, text: str, language: str | None) -> dict[str, Any]:
    if language != "rust":
        return {"hasTests": False, "testFunctions": [], "hasCfgTest": False}
    has_cfg_test = bool(re.search(r"#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]", text))
    test_functions: list[str] = []
    pending_test = False
    for line in text.splitlines():
        if re.search(r"#\s*\[\s*(?:test|tokio::test|async_std::test)\s*\]", line):
            pending_test = True
            continue
        if pending_test:
            match = re.search(r"^\s*(?:async\s+)?fn\s+([A-Za-z_][\w]*)\b", line)
            if match:
                test_functions.append(match.group(1))
                pending_test = False
                continue
            if line.strip() and not line.strip().startswith("#"):
                pending_test = False
    has_tests = has_cfg_test or bool(test_functions) or is_test_path(rel)
    return {
        "hasTests": has_tests,
        "testFunctions": sorted(set(test_functions)),
        "hasCfgTest": has_cfg_test,
    }


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


def go_boundary_hints_for_path(rel: str) -> list[dict[str, Any]]:
    path = Path(rel)
    parts = path.parts
    hints: list[dict[str, Any]] = []
    if "internal" in parts:
        index = parts.index("internal")
        allowed_root = "/".join(parts[:index]) or "."
        hints.append(
            {
                "kind": "go-internal",
                "value": "internal package boundary",
                "allowedRoot": allowed_root,
                "weak": False,
            }
        )
    if parts and parts[0] == "cmd":
        hints.append(
            {
                "kind": "go-cmd",
                "value": "executable entrypoint convention",
                "weak": False,
            }
        )
    if parts and parts[0] == "pkg":
        hints.append(
            {
                "kind": "go-pkg",
                "value": "reusable package directory convention",
                "weak": True,
            }
        )
    if "testdata" in parts:
        hints.append(
            {
                "kind": "go-testdata",
                "value": "test fixture data convention",
                "weak": False,
            }
        )
    if path.name.endswith("_test.go"):
        hints.append(
            {
                "kind": "go-test-file",
                "value": "*_test.go test convention",
                "weak": False,
            }
        )
    return hints


def extract_manifest(rel: str, text: str) -> dict[str, Any] | None:
    path = Path(rel)
    manifest_kind = manifest_kind_for_path(rel)
    if not manifest_kind:
        return None
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": manifest_kind,
        "language": language_for_path(rel),
        "tokens": tokens_for_path(rel),
    }
    if manifest_kind == "dotnet-solution":
        projects = parse_sln_projects(text)
        manifest["language"] = "csharp"
        if projects:
            manifest["projects"] = projects
            project_tokens = {token for project in projects for token in split_identifier(" ".join(project.values()))}
            manifest["tokens"] = sorted(set(manifest["tokens"]) | project_tokens)
        return manifest
    if manifest_kind == "dotnet-project":
        return parse_dotnet_project(rel, text)
    if manifest_kind in {"dotnet-props", "dotnet-targets"}:
        return parse_dotnet_props_targets(rel, text, manifest_kind)
    if path.name == "go.mod":
        module_path = parse_go_mod_module_path(text)
        if module_path:
            manifest["modulePath"] = module_path
            manifest["tokens"] = sorted(set(manifest["tokens"]) | set(split_identifier(module_path)))
    if path.name == "go.work":
        workspace_uses = parse_go_work_uses(text)
        if workspace_uses:
            manifest["workspaceUses"] = workspace_uses
            use_tokens = {token for use in workspace_uses for token in split_identifier(use)}
            manifest["tokens"] = sorted(set(manifest["tokens"]) | use_tokens)
    if path.name == "Cargo.toml":
        data = parse_toml_document(text)
        package = data.get("package") if isinstance(data, dict) else None
        workspace = data.get("workspace") if isinstance(data, dict) else None
        if isinstance(package, dict):
            name = package.get("name")
            if isinstance(name, str) and name:
                manifest["packageName"] = name
        if isinstance(workspace, dict):
            members = workspace.get("members")
            if isinstance(members, list):
                manifest["workspaceMembers"] = sorted(str(member) for member in members if isinstance(member, str))
        dependency_sections = {
            "dependencies": "dependencies",
            "dev-dependencies": "devDependencies",
            "build-dependencies": "buildDependencies",
        }
        for source_key, output_key in dependency_sections.items():
            section = data.get(source_key) if isinstance(data, dict) else None
            if isinstance(section, dict):
                manifest[output_key] = sorted(str(key) for key in section)
        lib = data.get("lib") if isinstance(data, dict) else None
        if isinstance(lib, dict):
            hint = {str(key): str(value) for key, value in sorted(lib.items()) if isinstance(value, (str, int, bool))}
            manifest["lib"] = hint or True
        bins = data.get("bin") if isinstance(data, dict) else None
        if isinstance(bins, list):
            bin_targets = []
            for item in bins:
                if isinstance(item, dict):
                    name = item.get("name")
                    path_value = item.get("path")
                    target = {}
                    if isinstance(name, str):
                        target["name"] = name
                    if isinstance(path_value, str):
                        target["path"] = path_value
                    if target:
                        bin_targets.append(target)
            if bin_targets:
                manifest["bin"] = sorted(bin_targets, key=lambda item: (str(item.get("name", "")), str(item.get("path", ""))))
        token_values = [str(manifest.get("packageName", ""))]
        token_values.extend(str(item) for item in manifest.get("workspaceMembers", []))
        token_values.extend(str(item) for item in manifest.get("dependencies", []))
        manifest["tokens"] = sorted(set(manifest["tokens"]) | set(split_identifier(" ".join(token_values))))
    if path.name == "Cargo.lock":
        packages = sorted(set(re.findall(r'^\s*name\s*=\s*"([^"]+)"', text, flags=re.MULTILINE)))
        if packages:
            manifest["packages"] = packages[:50]
            manifest["tokens"] = sorted(set(manifest["tokens"]) | set(split_identifier(" ".join(packages[:50]))))
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


def rust_crate_name_for_package(package_name: str) -> str:
    return package_name.replace("-", "_")


def build_rust_context(manifests: list[dict[str, Any]], known_files: set[str]) -> dict[str, Any]:
    workspace_members: set[str] = set()
    for manifest in manifests:
        if manifest.get("kind") != "cargo":
            continue
        base = Path(str(manifest.get("path") or "")).parent
        base_rel = "" if base.as_posix() == "." else base.as_posix()
        for member in manifest.get("workspaceMembers", []):
            if not isinstance(member, str) or not member:
                continue
            member_path = normalize_rel_parts(f"{base_rel}/{member}" if base_rel else member)
            workspace_members.add(member_path)

    crates: list[dict[str, Any]] = []
    for manifest in manifests:
        if manifest.get("kind") != "cargo":
            continue
        path = str(manifest.get("path") or "")
        root = Path(path).parent.as_posix()
        if root == ".":
            root = ""
        package_name = manifest.get("packageName")
        if not isinstance(package_name, str):
            package_name = Path(root).name if root else ""
        if not package_name and root not in workspace_members:
            continue
        crate = {
            "root": root,
            "manifestPath": path,
            "packageName": package_name,
            "crateName": rust_crate_name_for_package(package_name) if package_name else "",
            "workspaceMember": root in workspace_members,
        }
        crates.append(crate)

    crate_by_name: dict[str, dict[str, Any]] = {}
    for crate in crates:
        for key in (crate.get("crateName"), crate.get("packageName")):
            if isinstance(key, str) and key:
                crate_by_name[key] = crate

    return {
        "crates": sorted(crates, key=lambda item: str(item.get("root") or "")),
        "crateByName": crate_by_name,
        "workspaceMembers": sorted(workspace_members),
        "knownFiles": sorted(known_files),
    }


def build_csharp_context(manifests: list[dict[str, Any]], known_files: set[str]) -> dict[str, Any]:
    projects: list[dict[str, Any]] = []
    project_by_path: dict[str, dict[str, Any]] = {}
    for manifest in manifests:
        if manifest.get("kind") != "dotnet-project":
            continue
        path = str(manifest.get("path") or "")
        if not path:
            continue
        root = Path(path).parent.as_posix()
        if root == ".":
            root = ""
        project = {
            "path": path,
            "root": root,
            "projectName": manifest.get("projectName") or Path(path).stem,
            "assemblyName": manifest.get("assemblyName") or manifest.get("projectName") or Path(path).stem,
            "rootNamespace": manifest.get("rootNamespace")
            or manifest.get("assemblyName")
            or manifest.get("projectName")
            or Path(path).stem,
            "projectReferences": sorted(str(item) for item in manifest.get("projectReferences", []) if isinstance(item, str)),
            "packageReferences": sorted(str(item) for item in manifest.get("packageReferences", []) if isinstance(item, str)),
            "isTestProject": bool(manifest.get("isTestProject")),
            "outputType": manifest.get("outputType"),
            "targetFrameworks": manifest.get("targetFrameworks", []),
        }
        projects.append(project)
        project_by_path[path] = project

    referenced_by: dict[str, list[str]] = defaultdict(list)
    for project in projects:
        for reference in project.get("projectReferences", []):
            if reference in project_by_path:
                referenced_by[reference].append(str(project.get("path")))

    for project in projects:
        path = str(project.get("path"))
        project["referencedBy"] = sorted(set(referenced_by.get(path, [])))
        source_files = [
            rel
            for rel in known_files
            if rel.endswith(".cs")
            and (
                (not project.get("root") and "/" not in rel)
                or (bool(project.get("root")) and rel.startswith(f"{project.get('root')}/"))
            )
        ]
        project["sourceFiles"] = sorted(source_files)

    return {
        "projects": sorted(projects, key=lambda item: str(item.get("root") or "")),
        "projectByPath": project_by_path,
    }


def csharp_project_for_path(rel: str, csharp_context: dict[str, Any]) -> dict[str, Any] | None:
    projects = csharp_context.get("projects")
    if not isinstance(projects, list):
        return None
    matches = []
    for project in projects:
        if not isinstance(project, dict):
            continue
        root = str(project.get("root") or "")
        project_path = str(project.get("path") or "")
        if rel == project_path or (root and rel.startswith(f"{root}/")) or (not root and "/" not in rel):
            matches.append(project)
    if not matches:
        return None
    return sorted(matches, key=lambda item: len(str(item.get("root") or "")), reverse=True)[0]


def csharp_transitive_project_references(project: dict[str, Any], csharp_context: dict[str, Any]) -> list[dict[str, Any]]:
    project_by_path = csharp_context.get("projectByPath")
    if not isinstance(project_by_path, dict):
        return []
    found: list[dict[str, Any]] = []
    seen: set[str] = set()
    pending = [str(item) for item in project.get("projectReferences", [])]
    while pending:
        path = pending.pop(0)
        if path in seen:
            continue
        seen.add(path)
        target = project_by_path.get(path)
        if not isinstance(target, dict):
            continue
        found.append(target)
        pending.extend(str(item) for item in target.get("projectReferences", []))
    return found


def csharp_namespace_matches(imported: str, project: dict[str, Any]) -> bool:
    namespaces = [
        str(project.get("rootNamespace") or ""),
        str(project.get("assemblyName") or ""),
        str(project.get("projectName") or ""),
    ]
    for namespace in namespaces:
        if not namespace:
            continue
        if imported == namespace or imported.startswith(f"{namespace}."):
            return True
    return False


def resolve_csharp_import(
    source_rel: str,
    imported: str,
    csharp_context: dict[str, Any],
) -> str | None:
    if not imported:
        return None
    source_project = csharp_project_for_path(source_rel, csharp_context)
    candidates: list[dict[str, Any]] = []
    if source_project:
        candidates.append(source_project)
        candidates.extend(csharp_transitive_project_references(source_project, csharp_context))
    else:
        projects = csharp_context.get("projects")
        if isinstance(projects, list):
            candidates.extend(project for project in projects if isinstance(project, dict))

    for project in candidates:
        if not csharp_namespace_matches(imported, project):
            continue
        root = str(project.get("root") or "")
        return root or "."

    if imported.startswith(CSHARP_EXTERNAL_NAMESPACE_PREFIXES):
        return None
    return None


def rust_module_role(rel: str, crate: dict[str, Any] | None) -> str | None:
    if not crate:
        if rel.startswith("crates/"):
            return "crates-directory"
        if Path(rel).parts and "tests" in Path(rel).parts:
            return "integration-test"
        return None
    src_root = rust_src_root(crate)
    if rel == f"{src_root}/lib.rs":
        return "library-crate-root"
    if rel == f"{src_root}/main.rs":
        return "binary-crate-root"
    if Path(rel).parts and "tests" in Path(rel).parts:
        return "integration-test"
    if Path(rel).name == "mod.rs":
        return "module-root"
    return None


def rust_module_fields(rel: str, text: str, rust_context: dict[str, Any]) -> dict[str, Any]:
    crate = rust_crate_for_path(rel, rust_context)
    fields: dict[str, Any] = {}
    if crate:
        if crate.get("root"):
            fields["crateRoot"] = crate.get("root")
        if crate.get("crateName"):
            fields["crateName"] = crate.get("crateName")
        if crate.get("packageName"):
            fields["packageName"] = crate.get("packageName")
        if crate.get("workspaceMember"):
            fields["workspaceMember"] = True
    role = rust_module_role(rel, crate)
    hints: list[dict[str, Any]] = []
    if role == "library-crate-root":
        hints.append({"kind": "rust-library-crate-root", "value": "Rust library crate root", "weak": False})
    elif role == "binary-crate-root":
        hints.append({"kind": "rust-binary-crate-root", "value": "Rust binary crate root", "weak": False})
    elif role == "integration-test":
        hints.append({"kind": "rust-integration-test", "value": "Rust integration test", "weak": False})
    elif role == "crates-directory":
        hints.append({"kind": "rust-crates-directory", "value": "crates/ directory convention", "weak": True})
    if crate and crate.get("workspaceMember") and crate.get("root"):
        hints.append(
            {
                "kind": "rust-workspace-member",
                "value": "Cargo workspace member",
                "weak": False,
                "path": crate.get("root"),
            }
        )
    if re.search(r"#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]", text):
        fields["hasInlineCfgTest"] = True
        hints.append({"kind": "rust-inline-cfg-test", "value": "inline #[cfg(test)] tests", "weak": False})
    if hints:
        fields["boundaryHints"] = hints
        fields["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in hints)
    if role:
        fields["rustRole"] = role
    return fields


def csharp_module_fields(
    rel: str,
    text: str,
    csharp_context: dict[str, Any],
    manifest: dict[str, Any] | None = None,
) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    hints: list[dict[str, Any]] = []
    project = csharp_project_for_path(rel, csharp_context)
    if project and Path(rel).suffix == ".cs":
        for key in ("projectName", "assemblyName", "rootNamespace", "outputType"):
            value = project.get(key)
            if value:
                fields[key] = value
        if project.get("root"):
            fields["projectRoot"] = project.get("root")
        if project.get("path"):
            fields["projectPath"] = project.get("path")
        if project.get("targetFrameworks"):
            fields["targetFrameworks"] = project.get("targetFrameworks")
        if project.get("isTestProject"):
            fields["testProject"] = True

    if manifest and manifest.get("kind") == "dotnet-solution":
        hints.append({"kind": "dotnet-solution", "value": "C# solution boundary", "weak": False})
    if manifest and manifest.get("kind") == "dotnet-project":
        hints.append({"kind": "dotnet-project", "value": "C# project/assembly boundary", "weak": False})
        if manifest.get("isTestProject"):
            hints.append({"kind": "dotnet-test-project", "value": "C# test project boundary", "weak": False})
            fields["testProject"] = True
        if str(manifest.get("outputType") or "").lower() == "exe":
            hints.append(
                {
                    "kind": "dotnet-executable-project",
                    "value": "C# executable project boundary",
                    "weak": False,
                    "risk": "Executable C# project is not a generic helper module",
                }
            )
            fields["executableBoundary"] = True
        for reference in manifest.get("projectReferences", []):
            if isinstance(reference, str):
                hints.append(
                    {
                        "kind": "dotnet-project-reference",
                        "value": "C# project reference dependency edge",
                        "path": reference,
                        "sourceProject": rel,
                        "weak": False,
                    }
                )
    if manifest and manifest.get("kind") in {"dotnet-props", "dotnet-targets"}:
        hints.append({"kind": manifest.get("kind"), "value": "MSBuild props/targets manifest", "weak": False})

    if hints:
        fields["boundaryHints"] = hints
        fields["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in hints if isinstance(hint, dict))
    return fields


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
        if name.endswith("_test.go"):
            by_pattern[(language, "*_test.go")].append(path)
        elif ".test." in name:
            by_pattern[(language, "*.test.*")].append(path)
        elif ".spec." in name:
            by_pattern[(language, "*.spec.*")].append(path)
        elif name.startswith("test_"):
            by_pattern[(language, "test_*.py")].append(path)
        elif name.endswith("_test.py"):
            by_pattern[(language, "*_test.py")].append(path)
        elif language == "csharp" and name.endswith("Tests.cs"):
            by_pattern[(language, "*Tests.cs")].append(path)
        elif "tests" in Path(path).parts:
            by_pattern[(language, "tests/ directory")].append(path)
    for rel, text in sorted(file_text.items()):
        language = language_for_path(rel)
        if language == "rust" and re.search(r"#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]", text):
            by_pattern[(language, "inline #[cfg(test)]")].append(rel)
    for (language, pattern), evidence in sorted(by_pattern.items()):
        test_conventions.append(convention_entry("test-file-pattern", pattern, language or None, evidence))

    error_handling: list[dict[str, Any]] = []
    logging: list[dict[str, Any]] = []
    validation: list[dict[str, Any]] = []
    config: list[dict[str, Any]] = []
    go_conventions: list[dict[str, Any]] = []
    csharp_conventions: list[dict[str, Any]] = []
    rust_boundaries: list[dict[str, Any]] = []
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
        if language == "go" and is_go_test_path(rel):
            go_conventions.append(convention_entry("go-test-command", "go test", "go", [rel]))
            package_name = extract_go_package_name(text)
            if package_name and not package_name.endswith("_test"):
                go_conventions.append(convention_entry("go-test-scope", "package-local tests", "go", [rel]))
        if language == "csharp" and Path(rel).suffix == ".cs":
            if Path(rel).name.endswith("Tests.cs"):
                csharp_conventions.append(convention_entry("test-file-pattern", "*Tests.cs", "csharp", [rel]))
            framework = test_framework_for_path(rel, text, language)
            if framework:
                csharp_conventions.append(convention_entry("test-framework", framework, "csharp", [rel]))
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
    compact_rust_boundaries = compact_conventions(rust_boundaries)
    confidence = 0.45
    for section in (test_conventions, compact_error_handling, compact_logging, compact_config, compact_validation, compact_go_conventions, compact_csharp_conventions, compact_rust_boundaries):
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


def build_go_package_modules(
    modules: list[dict[str, Any]],
    symbols: list[dict[str, Any]],
    tests: list[dict[str, Any]],
    importers_by_target: dict[str, list[str]],
) -> list[dict[str, Any]]:
    files_by_dir: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for module in modules:
        path = str(module.get("path") or "")
        if module.get("language") != "go" or not path.endswith(".go"):
            continue
        if is_test_fixture_path(path):
            continue
        directory = str(module.get("directory") or "")
        files_by_dir[directory].append(module)

    symbols_by_dir: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for symbol in symbols:
        if symbol.get("language") != "go":
            continue
        path = str(symbol.get("path") or "")
        if is_go_test_path(path):
            continue
        symbols_by_dir[Path(path).parent.as_posix() if Path(path).parent.as_posix() != "." else ""].append(symbol)

    go_package_modules: list[dict[str, Any]] = []
    for directory, package_files in sorted(files_by_dir.items()):
        source_files = sorted(
            str(item.get("path"))
            for item in package_files
            if str(item.get("path") or "").endswith(".go") and not is_go_test_path(str(item.get("path") or ""))
        )
        test_files = sorted(
            str(item.get("path"))
            for item in package_files
            if is_go_test_path(str(item.get("path") or ""))
        )
        if not source_files and not test_files:
            continue
        package_counts = Counter(
            str(item.get("package"))
            for item in package_files
            if isinstance(item.get("package"), str) and item.get("package")
        )
        package_name = ""
        if package_counts:
            package_name = sorted(package_counts.items(), key=lambda item: (-item[1], item[0]))[0][0]
        package_symbols = [
            str(symbol.get("name"))
            for symbol in symbols_by_dir.get(directory, [])
            if symbol.get("exported") and isinstance(symbol.get("name"), str)
        ]
        tokens = set(tokens_for_path(directory or package_name or "."))
        if package_name:
            tokens.update(split_identifier(package_name))
        for symbol_name in package_symbols:
            tokens.update(split_identifier(symbol_name))
        imported_by = sorted(set(importers_by_target.get(directory, [])))
        boundary_hints = go_boundary_hints_for_path(directory)
        module: dict[str, Any] = {
            "path": directory or ".",
            "name": package_name or Path(directory).name or ".",
            "directory": Path(directory).parent.as_posix() if directory and Path(directory).parent.as_posix() != "." else "",
            "language": "go",
            "kind": "package",
            "package": package_name or None,
            "files": sorted(source_files + test_files),
            "sourceFiles": source_files,
            "testFiles": test_files,
            "tokens": sorted(tokens),
            "lineCount": sum(int(item.get("lineCount", 0)) for item in package_files),
            "symbols": sorted(set(package_symbols)),
            "exportedSymbolCount": len(set(package_symbols)),
        }
        if imported_by:
            module["importedBy"] = imported_by
            module["importCount"] = len(imported_by)
        if test_files:
            module["pairedTests"] = test_files
        if boundary_hints:
            module["boundaryHints"] = boundary_hints
            module["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in boundary_hints)
        if any(hint.get("kind") == "go-internal" for hint in boundary_hints):
            module["internalBoundary"] = True
        if any(hint.get("kind") == "go-cmd" for hint in boundary_hints):
            module["entrypointBoundary"] = True
        if any(hint.get("kind") == "go-pkg" for hint in boundary_hints):
            module["weakReusablePackageConvention"] = True
        if package_symbols and source_files:
            module["publicAPICandidate"] = True
        go_package_modules.append(module)
    return go_package_modules


def build_csharp_project_modules(
    modules: list[dict[str, Any]],
    symbols: list[dict[str, Any]],
    tests: list[dict[str, Any]],
    importers_by_target: dict[str, list[str]],
    csharp_context: dict[str, Any],
) -> list[dict[str, Any]]:
    projects = csharp_context.get("projects")
    if not isinstance(projects, list):
        return []
    modules_by_path = {str(module.get("path")): module for module in modules}
    symbols_by_project: dict[str, list[dict[str, Any]]] = defaultdict(list)
    files_by_project: dict[str, list[str]] = defaultdict(list)
    tests_by_project: dict[str, list[str]] = defaultdict(list)

    for module in modules:
        if module.get("language") != "csharp" or Path(str(module.get("path") or "")).suffix != ".cs":
            continue
        path = str(module.get("path"))
        project_path = str(module.get("projectPath") or "")
        if not project_path:
            project = csharp_project_for_path(path, csharp_context)
            project_path = str(project.get("path") or "") if project else ""
        if not project_path:
            continue
        files_by_project[project_path].append(path)
        if module.get("kind") == "test" or module.get("testProject"):
            tests_by_project[project_path].append(path)
    for symbol in symbols:
        if symbol.get("language") != "csharp":
            continue
        path = str(symbol.get("path") or "")
        module = modules_by_path.get(path)
        project_path = str(module.get("projectPath") or "") if module else ""
        if not project_path:
            project = csharp_project_for_path(path, csharp_context)
            project_path = str(project.get("path") or "") if project else ""
        if project_path:
            symbols_by_project[project_path].append(symbol)

    project_modules: list[dict[str, Any]] = []
    for project in projects:
        if not isinstance(project, dict):
            continue
        project_path = str(project.get("path") or "")
        root = str(project.get("root") or ".")
        source_files = sorted(files_by_project.get(project_path, []))
        test_files = sorted(tests_by_project.get(project_path, []))
        project_symbols = symbols_by_project.get(project_path, [])
        public_symbols = sorted(
            {
                str(symbol.get("name"))
                for symbol in project_symbols
                if symbol.get("exported") and str(symbol.get("kind")) != "namespace" and isinstance(symbol.get("name"), str)
            }
        )
        internal_symbols = sorted(
            {
                str(symbol.get("name"))
                for symbol in project_symbols
                if str(symbol.get("visibility") or "") == "internal" and isinstance(symbol.get("name"), str)
            }
        )
        imported_by = sorted(set(importers_by_target.get(root, [])))
        referenced_by = sorted(set(str(item) for item in project.get("referencedBy", []) if item))
        paired_test_paths = sorted(
            {
                str(test.get("path"))
                for test in tests
                if isinstance(test.get("path"), str)
                and (
                    str(test.get("path")) in imported_by
                    or set(tokens_for_path(str(test.get("path")))) & set(split_identifier(str(project.get("projectName") or "")))
                    or set(tokens_for_path(str(test.get("path")))) & {token for symbol in public_symbols for token in split_identifier(symbol)}
                )
            }
        )
        tokens = set(tokens_for_path(root))
        for value in (
            str(project.get("projectName") or ""),
            str(project.get("assemblyName") or ""),
            str(project.get("rootNamespace") or ""),
        ):
            tokens.update(split_identifier(value))
        for symbol_name in public_symbols:
            tokens.update(split_identifier(symbol_name))
        boundary_hints: list[dict[str, Any]] = [
            {"kind": "dotnet-project", "value": "C# project/assembly boundary", "weak": False}
        ]
        if referenced_by:
            boundary_hints.append({"kind": "dotnet-project-referenced", "value": "C# project referenced by local projects", "weak": False})
        if project.get("isTestProject"):
            boundary_hints.append({"kind": "dotnet-test-project", "value": "C# test project boundary", "weak": False})
        if str(project.get("outputType") or "").lower() == "exe":
            boundary_hints.append(
                {
                    "kind": "dotnet-executable-project",
                    "value": "C# executable project boundary",
                    "weak": False,
                    "risk": "Executable C# project is not a generic helper module",
                }
            )
        if public_symbols:
            boundary_hints.append({"kind": "dotnet-public-api", "value": "C# public API candidate", "weak": False})
        if internal_symbols:
            boundary_hints.append(
                {
                    "kind": "dotnet-internal-api",
                    "value": "C# internal API is assembly-local",
                    "weak": False,
                    "risk": "internal symbols are assembly-local and may not be reusable across projects",
                }
            )
        module: dict[str, Any] = {
            "path": root,
            "name": str(project.get("projectName") or Path(root).name or "."),
            "directory": Path(root).parent.as_posix() if root not in {"", "."} and Path(root).parent.as_posix() != "." else "",
            "language": "csharp",
            "kind": "project",
            "projectPath": project_path,
            "projectName": project.get("projectName"),
            "assemblyName": project.get("assemblyName"),
            "rootNamespace": project.get("rootNamespace"),
            "targetFrameworks": project.get("targetFrameworks", []),
            "files": source_files,
            "sourceFiles": [path for path in source_files if path not in test_files],
            "testFiles": test_files,
            "tokens": sorted(tokens),
            "lineCount": sum(int(modules_by_path.get(path, {}).get("lineCount", 0)) for path in source_files),
            "symbols": public_symbols,
            "exportedSymbolCount": len(public_symbols),
            "internalSymbols": internal_symbols,
            "boundaryHints": boundary_hints,
            "boundaryKinds": sorted(str(hint.get("kind")) for hint in boundary_hints),
        }
        if project.get("packageReferences"):
            module["packageReferences"] = project.get("packageReferences")
        if project.get("projectReferences"):
            module["projectReferenceTargets"] = project.get("projectReferences")
        if referenced_by:
            module["projectReferences"] = referenced_by
            module["projectReferenceCount"] = len(referenced_by)
        if imported_by:
            module["importedBy"] = imported_by
            module["importCount"] = len(imported_by)
        if paired_test_paths:
            module["pairedTests"] = paired_test_paths
        if project.get("isTestProject"):
            module["isTestProject"] = True
        if str(project.get("outputType") or "").lower() == "exe":
            module["executableBoundary"] = True
        if public_symbols:
            module["publicAPICandidate"] = True
        if internal_symbols:
            module["internalAssemblyLocal"] = True
        project_modules.append(module)
    return project_modules


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


def build_index(
    project_root_arg: str,
    generated_at: str,
    scan: ScanResult,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    indexed_files = [file for file in scan.files if file.indexed]
    known_files = {file.rel for file in indexed_files}
    go_modules = collect_go_modules(indexed_files)
    go_package_dirs = {
        Path(file.rel).parent.as_posix() if Path(file.rel).parent.as_posix() != "." else ""
        for file in indexed_files
        if file.language == "go" and file.rel.endswith(".go") and not is_test_fixture_path(file.rel)
    }
    file_text: dict[str, str] = {}
    modules: list[dict[str, Any]] = []
    symbols: list[dict[str, Any]] = []
    imports: list[dict[str, Any]] = []
    tests: list[dict[str, Any]] = []
    manifest_by_path: dict[str, dict[str, Any]] = {}
    for scanned_file in indexed_files:
        manifest = extract_manifest(scanned_file.rel, scanned_file.text)
        if manifest:
            manifest_by_path[scanned_file.rel] = manifest
    manifests: list[dict[str, Any]] = list(manifest_by_path.values())
    rust_context = build_rust_context(manifests, known_files)
    csharp_context = build_csharp_context(manifests, known_files)
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
        text = scanned_file.text
        if text:
            file_text[rel] = text
        kind = module_kind(rel)
        csharp_project = csharp_project_for_path(rel, csharp_context) if language == "csharp" else None
        if language == "csharp" and Path(rel).suffix == ".cs" and csharp_project and csharp_project.get("isTestProject"):
            kind = "test"
        package_name = extract_go_package_name(text) if language == "go" else None
        boundary_hints = go_boundary_hints_for_path(rel) if language == "go" or is_test_fixture_path(rel) else []
        module = {
            "path": rel,
            "name": Path(rel).stem,
            "directory": Path(rel).parent.as_posix() if Path(rel).parent.as_posix() != "." else "",
            "language": language,
            "kind": kind,
            "tokens": tokens_for_path(rel),
            "lineCount": len(text.splitlines()) if text else 0,
        }
        if package_name:
            module["package"] = package_name
        if language == "go" and kind == "test" and package_name:
            module["targetPackage"] = package_name[: -len("_test")] if package_name.endswith("_test") else package_name
        if language == "go" and boundary_hints:
            module["boundaryHints"] = boundary_hints
            module["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in boundary_hints)
        if language == "rust":
            module.update(rust_module_fields(rel, text, rust_context))
        if language == "csharp":
            module.update(csharp_module_fields(rel, text, csharp_context, manifest_by_path.get(rel)))
        if is_test_fixture_path(rel):
            module["testFixture"] = True
        modules.append(module)
        file_symbols = extract_symbols(rel, language, text)
        symbols.extend(file_symbols)
        for import_record in extract_import_records(language, text):
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
            imports.append(item)
        rust_tests = rust_test_info(rel, text, language)
        csharp_tests = csharp_test_info(rel, text, language, csharp_project)
        if kind == "test" or rust_tests.get("hasTests") or csharp_tests.get("hasTests"):
            test_entry = {
                "path": rel,
                "language": language,
                "framework": csharp_tests.get("framework") if language == "csharp" else test_framework_for_path(rel, text, language),
                "tokens": sorted(set(tokens_for_path(rel)) | ({"test"} if language == "rust" else set())),
            }
            if language == "go":
                if package_name:
                    test_entry["package"] = package_name
                    test_entry["targetPackage"] = package_name[: -len("_test")] if package_name.endswith("_test") else package_name
                test_functions = sorted(set(GO_TEST_FUNCTION_RE.findall(text)))
                if test_functions:
                    test_entry["testFunctions"] = test_functions
            if rust_tests.get("testFunctions"):
                test_entry["testFunctions"] = rust_tests["testFunctions"]
            if rust_tests.get("hasCfgTest"):
                test_entry["inlineCfgTest"] = True
            if csharp_tests.get("testFunctions"):
                test_entry["testFunctions"] = csharp_tests["testFunctions"]
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

    modules.extend(build_go_package_modules(modules, symbols, tests, importers_by_target))
    modules.extend(build_csharp_project_modules(modules, symbols, tests, importers_by_target, csharp_context))

    symbols_by_path: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for symbol in symbols:
        symbols_by_path[str(symbol.get("path"))].append(symbol)

    for module in modules:
        if module.get("language") != "rust":
            continue
        path = str(module.get("path") or "")
        if not path:
            continue
        hints = list(module.get("boundaryHints", []))
        exported = sorted(
            str(symbol.get("name"))
            for symbol in symbols_by_path.get(path, [])
            if symbol.get("exported") and isinstance(symbol.get("name"), str)
        )
        if exported:
            hints.append({"kind": "rust-public-api", "value": "Rust public API candidate", "weak": False})
        crate_local = sorted(
            str(symbol.get("name"))
            for symbol in symbols_by_path.get(path, [])
            if str(symbol.get("visibility") or "").startswith("pub(") and isinstance(symbol.get("name"), str)
        )
        if crate_local:
            hints.append(
                {
                    "kind": "rust-crate-local-visibility",
                    "value": "Rust crate-local visibility",
                    "weak": False,
                    "risk": "pub(crate)/pub(super) visibility may not be reusable outside the crate",
                }
            )
            module["crateLocalSymbols"] = crate_local
        if hints:
            module["boundaryHints"] = hints
            module["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in hints if isinstance(hint, dict))

    for module in modules:
        if module.get("language") != "csharp":
            continue
        path = str(module.get("path") or "")
        if not path:
            continue
        hints = list(module.get("boundaryHints", []))
        exported = sorted(
            str(symbol.get("name"))
            for symbol in symbols_by_path.get(path, [])
            if symbol.get("exported") and isinstance(symbol.get("name"), str)
        )
        internal = sorted(
            str(symbol.get("name"))
            for symbol in symbols_by_path.get(path, [])
            if str(symbol.get("visibility") or "") == "internal" and isinstance(symbol.get("name"), str)
        )
        if exported:
            hints.append({"kind": "dotnet-public-api", "value": "C# public API candidate", "weak": False})
            module["publicAPICandidate"] = True
        if internal:
            hints.append(
                {
                    "kind": "dotnet-internal-api",
                    "value": "C# internal API is assembly-local",
                    "weak": False,
                    "risk": "internal symbols are assembly-local and may not be reusable across projects",
                }
            )
            module["internalSymbols"] = internal
            module["internalAssemblyLocal"] = True
        if hints:
            module["boundaryHints"] = hints
            module["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in hints if isinstance(hint, dict))

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
            reasons.append("shared-directory-name")
        if module.get("language") == "go" and module.get("weakReusablePackageConvention"):
            reasons.append("go-pkg-weak-convention")
        if module.get("language") == "go" and module.get("internalBoundary"):
            reasons.append("go-internal-boundary")
        if module.get("language") == "csharp" and module.get("projectReferenceCount", 0):
            reasons.append("project-referenced-by-local-projects")
        if module.get("language") == "csharp" and module.get("internalAssemblyLocal"):
            reasons.append("internal-assembly-boundary")
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
