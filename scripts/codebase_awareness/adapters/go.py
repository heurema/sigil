"""Go adapter for the shallow codebase awareness scanner."""

from __future__ import annotations

import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from scripts.codebase_awareness.adapters.common import (
    is_test_fixture_path,
    normalize_rel_parts,
    split_identifier,
    tokens_for_path,
)

GO_TEST_FUNCTION_RE = re.compile(r"^\s*func\s+((?:Test|Benchmark|Fuzz)[A-Za-z0-9_]*)\s*\(", re.MULTILINE)


def manifest_kinds() -> dict[str, str]:
    return {
        "go.mod": "go",
        "go.work": "go-work",
    }


def language_for_manifest(kind: str) -> str | None:
    if kind in {"go", "go-work"}:
        return "go"
    return None


def is_test_path(rel: str) -> bool:
    return Path(rel).name.endswith("_test.go")


def is_exported_identifier(name: str) -> bool:
    return bool(name) and "A" <= name[0] <= "Z"


def extract_package_name(text: str) -> str | None:
    match = re.search(r"^\s*package\s+([A-Za-z_][A-Za-z0-9_]*)\b", text, flags=re.MULTILINE)
    return match.group(1) if match else None


def normalize_receiver(receiver: str) -> str | None:
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


def symbol_entry(
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
        "exported": is_exported_identifier(name),
        "tokens": sorted(tokens),
        "receiver": receiver,
    }


def extract_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    symbols: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str | None]] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        func_match = re.search(
            r"^\s*func\s+(?:\((?P<receiver>[^)]*)\)\s*)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(",
            line,
        )
        if func_match:
            receiver = normalize_receiver(func_match.group("receiver") or "")
            name = func_match.group("name")
            kind = "method" if receiver else "function"
            key = (kind, name, receiver)
            if key not in seen:
                seen.add(key)
                symbols.append(
                    symbol_entry(
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
                symbols.append(symbol_entry(name=name, kind="type", rel=rel, line_number=line_number))
            continue

        value_match = re.search(r"^\s*(const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b", line)
        if value_match:
            kind = "constant" if value_match.group(1) == "const" else "variable"
            name = value_match.group(2)
            key = (kind, name, None)
            if key not in seen:
                seen.add(key)
                symbols.append(symbol_entry(name=name, kind=kind, rel=rel, line_number=line_number))
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
                        symbol_entry(
                            name=name,
                            kind=str(previous_kind),
                            rel=rel,
                            line_number=line_number,
                        )
                    )
    return symbols


def strip_line_comment(line: str) -> str:
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


def parse_import_line(line: str) -> dict[str, Any] | None:
    line = strip_line_comment(line).strip().rstrip(";")
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


def extract_import_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    in_block = False
    for line in text.splitlines():
        stripped = strip_line_comment(line).strip()
        if not in_block:
            single = re.match(r"^import\s+(?!\()(.*)$", stripped)
            if single:
                record = parse_import_line(single.group(1))
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
            record = parse_import_line(stripped)
            if record:
                records.append(record)
    unique: dict[tuple[str, str | None], dict[str, Any]] = {}
    for record in records:
        unique[(str(record.get("imported")), record.get("alias"))] = record
    return [unique[key] for key in sorted(unique)]


def parse_mod_module_path(text: str) -> str | None:
    match = re.search(r"^\s*module\s+([^\s]+)", text, flags=re.MULTILINE)
    return match.group(1) if match else None


def parse_work_uses(text: str) -> list[str]:
    uses: list[str] = []
    in_block = False
    for line in text.splitlines():
        stripped = strip_line_comment(line).strip()
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


def extract_manifest(rel: str, text: str, kind: str) -> dict[str, Any] | None:
    if kind not in {"go", "go-work"}:
        return None
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": kind,
        "language": "go",
        "tokens": tokens_for_path(rel),
    }
    path = Path(rel)
    if path.name == "go.mod":
        module_path = parse_mod_module_path(text)
        if module_path:
            manifest["modulePath"] = module_path
            manifest["tokens"] = sorted(set(manifest["tokens"]) | set(split_identifier(module_path)))
    if path.name == "go.work":
        workspace_uses = parse_work_uses(text)
        if workspace_uses:
            manifest["workspaceUses"] = workspace_uses
            use_tokens = {token for use in workspace_uses for token in split_identifier(use)}
            manifest["tokens"] = sorted(set(manifest["tokens"]) | use_tokens)
    return manifest


def collect_modules(indexed_files: list[Any]) -> list[tuple[str, str]]:
    modules: list[tuple[str, str]] = []
    for scanned_file in indexed_files:
        if Path(scanned_file.rel).name != "go.mod":
            continue
        module_path = parse_mod_module_path(scanned_file.text)
        if not module_path:
            continue
        directory = Path(scanned_file.rel).parent.as_posix()
        modules.append(("" if directory == "." else directory, module_path))
    return sorted(modules, key=lambda item: (-len(item[1]), item[0], item[1]))


def resolve_import(
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


def test_info(rel: str, text: str, language: str | None) -> dict[str, Any]:
    if language != "go":
        return {"hasTests": False, "framework": None, "testFunctions": []}
    test_functions = sorted(set(GO_TEST_FUNCTION_RE.findall(text)))
    return {
        "hasTests": is_test_path(rel) or bool(test_functions),
        "framework": "go-test" if is_test_path(rel) else None,
        "testFunctions": test_functions,
    }


def boundary_hints_for_path(rel: str) -> list[dict[str, Any]]:
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


def build_package_modules(
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
        if is_test_path(path):
            continue
        symbols_by_dir[Path(path).parent.as_posix() if Path(path).parent.as_posix() != "." else ""].append(symbol)

    go_package_modules: list[dict[str, Any]] = []
    for directory, package_files in sorted(files_by_dir.items()):
        source_files = sorted(
            str(item.get("path"))
            for item in package_files
            if str(item.get("path") or "").endswith(".go") and not is_test_path(str(item.get("path") or ""))
        )
        test_files = sorted(
            str(item.get("path"))
            for item in package_files
            if is_test_path(str(item.get("path") or ""))
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
        boundary_hints = boundary_hints_for_path(directory)
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
