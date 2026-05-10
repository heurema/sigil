"""TypeScript/JavaScript adapter for the shallow codebase awareness scanner."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from scripts.codebase_awareness.adapters.common import (
    normalize_rel_parts,
    split_identifier,
    tokens_for_path,
)

SOURCE_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
TYPE_EXTENSIONS = (".ts", ".tsx", ".mts", ".cts")
INDEX_CANDIDATES = tuple(f"index{suffix}" for suffix in SOURCE_EXTENSIONS)
TEST_FRAMEWORK_PACKAGES = {
    "@playwright/test": "playwright",
    "cypress": "cypress",
    "jest": "jest",
    "mocha": "mocha",
    "playwright": "playwright",
    "ts-node": "ts-node",
    "tsx": "tsx",
    "vitest": "vitest",
}
BROWSER_RUNTIME_PACKAGES = {
    "@vitejs/plugin-react",
    "next",
    "react",
    "react-dom",
    "svelte",
    "vue",
}
NODE_RUNTIME_PACKAGES = {
    "@types/node",
    "commander",
    "express",
    "fastify",
    "node",
    "yargs",
}
SHARED_DIR_HINTS = {"common", "lib", "shared", "utils"}


def manifest_kinds() -> dict[str, str]:
    return {
        "jsconfig.json": "jsconfig",
        "package-lock.json": "npm-lock",
        "package.json": "npm-package",
        "pnpm-lock.yaml": "pnpm-lock",
        "pnpm-workspace.yaml": "pnpm-workspace",
        "yarn.lock": "yarn-lock",
    }


def manifest_kind_for_path(rel: str) -> str | None:
    path = Path(rel)
    if path.name in manifest_kinds():
        return manifest_kinds()[path.name]
    if path.name == "tsconfig.json" or re.fullmatch(r"tsconfig\.[^.]+\.json", path.name):
        return "tsconfig"
    return None


def language_for_manifest(kind: str) -> str | None:
    if kind in {"jsconfig", "npm-lock", "npm-package", "tsconfig"}:
        return "json"
    if kind in {"pnpm-lock", "pnpm-workspace", "yarn-lock"}:
        return "yaml"
    return None


def language_for_source(rel: str) -> str | None:
    suffix = Path(rel).suffix
    if suffix in TYPE_EXTENSIONS:
        return "typescript"
    if suffix in {".js", ".jsx", ".mjs", ".cjs"}:
        return "javascript"
    return None


def strip_json_comments(text: str) -> str:
    output: list[str] = []
    index = 0
    in_string = False
    quote = ""
    escaped = False
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                in_string = False
                quote = ""
            index += 1
            continue
        if char in {"\"", "'"}:
            in_string = True
            quote = char
            output.append(char)
            index += 1
            continue
        if char == "/" and next_char == "/":
            while index < len(text) and text[index] != "\n":
                index += 1
            continue
        if char == "/" and next_char == "*":
            index += 2
            while index + 1 < len(text) and not (text[index] == "*" and text[index + 1] == "/"):
                output.append("\n" if text[index] == "\n" else " ")
                index += 1
            index += 2
            continue
        output.append(char)
        index += 1
    return "".join(output)


def strip_trailing_commas(text: str) -> str:
    return re.sub(r",\s*([}\]])", r"\1", text)


def parse_json_document(text: str) -> dict[str, Any]:
    try:
        data = json.loads(strip_trailing_commas(strip_json_comments(text)))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def string_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return sorted(str(item) for item in value if isinstance(item, str))
    if isinstance(value, str):
        return [value]
    return []


def dependency_names(data: dict[str, Any], key: str) -> list[str]:
    value = data.get(key)
    if not isinstance(value, dict):
        return []
    return sorted(str(name) for name in value)


def workspace_patterns(value: Any) -> list[str]:
    if isinstance(value, list):
        return sorted(str(item) for item in value if isinstance(item, str))
    if isinstance(value, dict):
        packages = value.get("packages")
        if isinstance(packages, list):
            return sorted(str(item) for item in packages if isinstance(item, str))
    return []


def exported_keys(value: Any) -> list[str]:
    if isinstance(value, dict):
        return sorted(str(key) for key in value)
    if isinstance(value, (str, list)):
        return ["."]
    return []


def collect_export_targets(value: Any) -> list[str]:
    targets: list[str] = []
    if isinstance(value, str):
        targets.append(value)
    elif isinstance(value, list):
        for item in value:
            targets.extend(collect_export_targets(item))
    elif isinstance(value, dict):
        for key, item in sorted(value.items(), key=lambda pair: str(pair[0])):
            if key in {"default", "import", "require", "types", "node", "browser"}:
                targets.extend(collect_export_targets(item))
            elif str(key).startswith("."):
                targets.extend(collect_export_targets(item))
            elif isinstance(item, (str, list, dict)):
                targets.extend(collect_export_targets(item))
    return sorted(set(targets))


def export_targets_map(value: Any) -> dict[str, list[str]]:
    if isinstance(value, str):
        return {".": [value]}
    if not isinstance(value, dict):
        return {}
    targets: dict[str, list[str]] = {}
    for key, item in sorted(value.items(), key=lambda pair: str(pair[0])):
        if str(key).startswith("."):
            resolved = collect_export_targets(item)
            if resolved:
                targets[str(key)] = resolved
    return targets


def bin_entries(value: Any, package_name: str | None) -> dict[str, str]:
    if isinstance(value, str):
        key = package_name or "bin"
        return {key: value}
    if isinstance(value, dict):
        return {
            str(key): str(item)
            for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))
            if isinstance(item, str)
        }
    return {}


def test_framework_hints(deps: set[str], scripts: dict[str, Any]) -> list[dict[str, Any]]:
    hints: dict[tuple[str, str], dict[str, Any]] = {}
    for package in sorted(deps):
        framework = TEST_FRAMEWORK_PACKAGES.get(package)
        if framework:
            hints[(package, framework)] = {"package": package, "framework": framework}
        if package.startswith("@testing-library/"):
            hints[(package, "testing-library")] = {
                "package": package,
                "framework": "testing-library",
            }
    script_text = " ".join(str(value) for value in scripts.values())
    for package, framework in TEST_FRAMEWORK_PACKAGES.items():
        if re.search(rf"(?<![\w@/-]){re.escape(package)}(?![\w/-])", script_text):
            hints[(package, framework)] = {"package": package, "framework": framework}
    return [hints[key] for key in sorted(hints)]


def runtime_hints(data: dict[str, Any], deps: set[str], bin_map: dict[str, str]) -> list[str]:
    hints: set[str] = set()
    engines = data.get("engines")
    if isinstance(engines, dict) and engines.get("node"):
        hints.add("node")
    if bin_map:
        hints.add("node")
    if deps & NODE_RUNTIME_PACKAGES:
        hints.add("node")
    if data.get("browser") or deps & BROWSER_RUNTIME_PACKAGES:
        hints.add("browser")
    return sorted(hints)


def manifest_tokens(rel: str, *values: Any) -> list[str]:
    tokens = set(tokens_for_path(rel))
    for value in values:
        if isinstance(value, str):
            tokens.update(split_identifier(value))
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, str):
                    tokens.update(split_identifier(item))
        elif isinstance(value, dict):
            for key, item in value.items():
                tokens.update(split_identifier(str(key)))
                if isinstance(item, str):
                    tokens.update(split_identifier(item))
    return sorted(tokens)


def extract_package_manifest(rel: str, text: str) -> dict[str, Any]:
    data = parse_json_document(text)
    package_name = data.get("name") if isinstance(data.get("name"), str) else None
    package_type = data.get("type") if isinstance(data.get("type"), str) else None
    scripts = data.get("scripts") if isinstance(data.get("scripts"), dict) else {}
    deps = dependency_names(data, "dependencies")
    dev_deps = dependency_names(data, "devDependencies")
    peer_deps = dependency_names(data, "peerDependencies")
    all_deps = set(deps) | set(dev_deps) | set(peer_deps)
    workspaces = workspace_patterns(data.get("workspaces"))
    bin_map = bin_entries(data.get("bin"), package_name)
    exports = exported_keys(data.get("exports"))
    imports = exported_keys(data.get("imports"))
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": "npm-package",
        "language": "json",
        "tokens": manifest_tokens(rel, package_name or "", exports, imports),
    }
    if package_name:
        manifest["packageName"] = package_name
    if package_type:
        manifest["packageType"] = package_type
    for key in ("main", "module"):
        if isinstance(data.get(key), str):
            manifest[key] = data[key]
    if exports:
        manifest["exports"] = exports
    export_targets = export_targets_map(data.get("exports"))
    if export_targets:
        manifest["exportTargets"] = export_targets
    if imports:
        manifest["imports"] = imports
    if bin_map:
        manifest["bin"] = bin_map
    if workspaces:
        manifest["workspaces"] = workspaces
    if scripts:
        manifest["scripts"] = sorted(str(key) for key in scripts)
    if deps:
        manifest["dependencies"] = deps
    if dev_deps:
        manifest["devDependencies"] = dev_deps
    if peer_deps:
        manifest["peerDependencies"] = peer_deps
    hints = test_framework_hints(all_deps, scripts)
    if hints:
        manifest["testFrameworkHints"] = hints
    runtimes = runtime_hints(data, all_deps, bin_map)
    if runtimes:
        manifest["runtimeHints"] = runtimes
    if isinstance(data.get("packageManager"), str):
        manifest["packageManager"] = data["packageManager"]
    return manifest


def extract_tsconfig_manifest(rel: str, text: str, kind: str) -> dict[str, Any]:
    data = parse_json_document(text)
    compiler = data.get("compilerOptions") if isinstance(data.get("compilerOptions"), dict) else {}
    paths = compiler.get("paths") if isinstance(compiler.get("paths"), dict) else {}
    references = data.get("references") if isinstance(data.get("references"), list) else []
    normalized_references = [
        {"path": str(item.get("path"))}
        for item in references
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    ]
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": kind,
        "language": "json",
        "tokens": manifest_tokens(rel, compiler.get("baseUrl") or "", paths, normalized_references),
    }
    if isinstance(data.get("extends"), str):
        manifest["extends"] = data["extends"]
    if isinstance(compiler.get("baseUrl"), str):
        manifest["baseUrl"] = compiler["baseUrl"]
    if paths:
        manifest["paths"] = {
            str(key): string_list(value)
            for key, value in sorted(paths.items(), key=lambda pair: str(pair[0]))
        }
    if normalized_references:
        manifest["references"] = normalized_references
    for key in ("include", "exclude"):
        values = string_list(data.get(key))
        if values:
            manifest[key] = values
    return manifest


def parse_pnpm_workspace_packages(text: str) -> list[str]:
    packages: list[str] = []
    in_packages = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if re.match(r"^packages\s*:", stripped):
            in_packages = True
            continue
        if in_packages and re.match(r"^[A-Za-z0-9_-]+\s*:", stripped):
            break
        if in_packages:
            match = re.match(r"^-\s*['\"]?([^'\"]+)['\"]?\s*$", stripped)
            if match:
                packages.append(match.group(1))
    return sorted(set(packages))


def extract_manifest(rel: str, text: str, manifest_kind: str) -> dict[str, Any] | None:
    if manifest_kind == "npm-package":
        return extract_package_manifest(rel, text)
    if manifest_kind in {"tsconfig", "jsconfig"}:
        return extract_tsconfig_manifest(rel, text, manifest_kind)
    if manifest_kind == "pnpm-workspace":
        packages = parse_pnpm_workspace_packages(text)
        manifest: dict[str, Any] = {
            "path": rel,
            "kind": manifest_kind,
            "language": "yaml",
            "tokens": manifest_tokens(rel, packages),
        }
        if packages:
            manifest["workspaces"] = packages
        return manifest
    if manifest_kind in {"npm-lock", "pnpm-lock", "yarn-lock"}:
        return {
            "path": rel,
            "kind": manifest_kind,
            "language": language_for_manifest(manifest_kind),
            "tokens": tokens_for_path(rel),
        }
    return None


def line_without_comment(line: str) -> str:
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
        if char in {"\"", "'", "`"}:
            in_string = True
            quote = char
            continue
        if char == "/" and index + 1 < len(line) and line[index + 1] == "/":
            return line[:index]
    return line


def brace_delta(line: str) -> int:
    stripped = line_without_comment(line)
    return stripped.count("{") - stripped.count("}")


def symbol_record(
    *,
    rel: str,
    line_number: int,
    name: str,
    kind: str,
    exported: bool,
    visibility: str,
    token_source: str | None = None,
) -> dict[str, Any]:
    tokens = set(split_identifier(token_source or name))
    if name == "default" and not tokens:
        tokens.update(tokens_for_path(rel))
    record: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "language": language_for_source(rel),
        "path": rel,
        "line": line_number,
        "exported": exported,
        "visibility": visibility,
        "tokens": sorted(tokens),
    }
    if visibility in {"local", "package-private"}:
        record["visibilityRisks"] = ["package-private/non-exported helper may not be reusable across package boundary"]
    return record


def variable_kind(line: str) -> str:
    if "=>" in line or re.search(r"=\s*(?:async\s+)?function\b", line):
        return "function"
    return "constant"


def parse_export_specifiers(raw: str) -> list[tuple[str, str | None]]:
    specifiers: list[tuple[str, str | None]] = []
    for item in raw.split(","):
        cleaned = item.strip()
        if not cleaned:
            continue
        cleaned = re.sub(r"^(?:type)\s+", "", cleaned)
        match = re.match(r"^([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*|default))?$", cleaned)
        if match:
            specifiers.append((match.group(1), match.group(2)))
    return specifiers


def extract_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    language = language_for_source(rel)
    if language is None:
        return []
    records: list[dict[str, Any]] = []
    by_name: dict[str, dict[str, Any]] = {}
    exported_names: set[str] = set()
    seen: set[tuple[str, str]] = set()
    brace_depth = 0
    default_function_re = re.compile(r"^\s*export\s+default\s+(?:async\s+)?function(?:\s+(?P<name>[A-Za-z_$][\w$]*))?\b")
    default_class_re = re.compile(r"^\s*export\s+default\s+class(?:\s+(?P<name>[A-Za-z_$][\w$]*))?\b")
    function_re = re.compile(r"^\s*(?P<export>export\s+)?(?:async\s+)?function\s+(?P<name>[A-Za-z_$][\w$]*)\b")
    class_re = re.compile(r"^\s*(?P<export>export\s+)?class\s+(?P<name>[A-Za-z_$][\w$]*)\b")
    type_re = re.compile(r"^\s*(?P<export>export\s+)?(?P<kind>interface|type|enum)\s+(?P<name>[A-Za-z_$][\w$]*)\b")
    variable_re = re.compile(r"^\s*(?P<export>export\s+)?(?:declare\s+)?(?P<decl>const|let|var)\s+(?P<name>[A-Za-z_$][\w$]*)\b")
    export_list_re = re.compile(r"^\s*export\s*\{(?P<body>[^}]*)\}\s*;?\s*$")

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = line_without_comment(raw_line)
        stripped = line.strip()
        top_level = brace_depth == 0
        if top_level and stripped:
            default_match = default_function_re.search(line)
            if default_match:
                token_source = default_match.group("name") or Path(rel).stem
                key = ("default", "function")
                if key not in seen:
                    seen.add(key)
                    record = symbol_record(
                        rel=rel,
                        line_number=line_number,
                        name="default",
                        kind="function",
                        exported=True,
                        visibility="default-export",
                        token_source=token_source,
                    )
                    records.append(record)
                    by_name["default"] = record
                brace_depth += brace_delta(line)
                continue

            default_match = default_class_re.search(line)
            if default_match:
                token_source = default_match.group("name") or Path(rel).stem
                key = ("default", "class")
                if key not in seen:
                    seen.add(key)
                    record = symbol_record(
                        rel=rel,
                        line_number=line_number,
                        name="default",
                        kind="class",
                        exported=True,
                        visibility="default-export",
                        token_source=token_source,
                    )
                    records.append(record)
                    by_name["default"] = record
                brace_depth += brace_delta(line)
                continue

            export_list = export_list_re.search(line)
            if export_list:
                for local_name, _alias in parse_export_specifiers(export_list.group("body")):
                    exported_names.add(local_name)
                brace_depth += brace_delta(line)
                continue

            for pattern, default_kind in (
                (function_re, "function"),
                (class_re, "class"),
                (type_re, None),
                (variable_re, None),
            ):
                match = pattern.search(line)
                if not match:
                    continue
                name = match.group("name")
                exported = bool(match.groupdict().get("export"))
                if pattern is variable_re:
                    kind = variable_kind(line)
                else:
                    kind = default_kind or match.group("kind")
                key = (name, kind)
                if key in seen:
                    break
                seen.add(key)
                visibility = "exported" if exported else "local"
                record = symbol_record(
                    rel=rel,
                    line_number=line_number,
                    name=name,
                    kind=kind,
                    exported=exported,
                    visibility=visibility,
                )
                records.append(record)
                by_name[name] = record
                break
        brace_depth += brace_delta(line)
        if brace_depth < 0:
            brace_depth = 0

    for name in sorted(exported_names):
        record = by_name.get(name)
        if record:
            record["exported"] = True
            record["visibility"] = "exported"
            record.pop("visibilityRisks", None)
        else:
            records.append(
                symbol_record(
                    rel=rel,
                    line_number=1,
                    name=name,
                    kind="export",
                    exported=True,
                    visibility="exported",
                )
            )
    return records


def parse_import_bindings(body: str) -> tuple[list[str], Any]:
    body = body.strip()
    if not body:
        return [], None
    if body.startswith("type "):
        body = body[len("type ") :].strip()
    symbols: list[str] = []
    aliases: dict[str, str] = {}
    namespace_match = re.search(r"\*\s+as\s+([A-Za-z_$][\w$]*)", body)
    if namespace_match:
        return ["*"], namespace_match.group(1)
    named_match = re.search(r"\{([^}]*)\}", body)
    if named_match:
        for original, alias in parse_export_specifiers(named_match.group(1)):
            symbols.append(original)
            if alias:
                aliases[original] = alias
    default_part = body.split("{", 1)[0].split(",", 1)[0].strip()
    if default_part and re.fullmatch(r"[A-Za-z_$][\w$]*", default_part):
        symbols.insert(0, "default")
        aliases["default"] = default_part
    if aliases:
        return sorted(set(symbols)), aliases if len(aliases) > 1 else next(iter(aliases.values()))
    return sorted(set(symbols)), None


def import_record(
    *,
    imported: str,
    kind: str,
    line_number: int,
    symbols: list[str] | None = None,
    alias: Any = None,
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "imported": imported,
        "kind": kind,
        "line": line_number,
        "tokens": sorted(set(split_identifier(imported))),
    }
    if symbols:
        record["symbols"] = sorted(set(symbols))
        token_set = set(record["tokens"])
        for symbol in symbols:
            token_set.update(split_identifier(symbol))
        record["tokens"] = sorted(token_set)
    if alias:
        record["alias"] = alias
    return record


def extract_import_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    static_re = re.compile(r"^\s*import\s+(?P<body>.+?)\s+from\s+['\"](?P<spec>[^'\"]+)['\"]\s*;?\s*$")
    side_effect_re = re.compile(r"^\s*import\s+['\"](?P<spec>[^'\"]+)['\"]\s*;?\s*$")
    require_re = re.compile(
        r"(?:const|let|var)\s+(?P<body>\{[^}]+\}|[A-Za-z_$][\w$]*)\s*=\s*require\(\s*['\"](?P<spec>[^'\"]+)['\"]\s*\)"
    )
    dynamic_re = re.compile(r"(?:await\s+)?import\(\s*['\"](?P<spec>[^'\"]+)['\"]\s*\)")
    export_from_re = re.compile(r"^\s*export\s+(?P<body>\*|\{[^}]*\})\s+from\s+['\"](?P<spec>[^'\"]+)['\"]\s*;?\s*$")

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = line_without_comment(raw_line).strip()
        if not line:
            continue
        match = export_from_re.search(line)
        if match:
            body = match.group("body")
            if body == "*":
                symbols, alias = ["*"], None
            else:
                symbols, alias = parse_import_bindings(body)
            records.append(
                import_record(
                    imported=match.group("spec"),
                    kind="export-from",
                    line_number=line_number,
                    symbols=symbols,
                    alias=alias,
                )
            )
            continue

        match = static_re.search(line)
        if match:
            symbols, alias = parse_import_bindings(match.group("body"))
            records.append(
                import_record(
                    imported=match.group("spec"),
                    kind="import",
                    line_number=line_number,
                    symbols=symbols,
                    alias=alias,
                )
            )
            continue

        match = side_effect_re.search(line)
        if match:
            records.append(
                import_record(
                    imported=match.group("spec"),
                    kind="side-effect-import",
                    line_number=line_number,
                )
            )
            continue

        for match in require_re.finditer(line):
            body = match.group("body")
            if body.startswith("{"):
                symbols, alias = parse_import_bindings(body)
            else:
                symbols, alias = ["default"], body
            records.append(
                import_record(
                    imported=match.group("spec"),
                    kind="require",
                    line_number=line_number,
                    symbols=symbols,
                    alias=alias,
                )
            )

        for match in dynamic_re.finditer(line):
            records.append(
                import_record(
                    imported=match.group("spec"),
                    kind="dynamic-import",
                    line_number=line_number,
                )
            )

    unique: dict[tuple[str, str, int, str], dict[str, Any]] = {}
    for record in records:
        unique[
            (
                str(record.get("imported")),
                str(record.get("kind")),
                int(record.get("line", 0)),
                json.dumps(record.get("symbols", []), sort_keys=True),
            )
        ] = record
    return [unique[key] for key in sorted(unique)]


def is_test_path(rel: str) -> bool:
    path = Path(rel)
    name = path.name
    parts = set(path.parts)
    return (
        "test" in parts
        or "tests" in parts
        or "__tests__" in parts
        or ".test." in name
        or ".spec." in name
    ) and path.suffix in SOURCE_EXTENSIONS


def detect_test_framework(text: str) -> str | None:
    imports = extract_import_records(text)
    imported_specs = {str(item.get("imported")) for item in imports}
    if "vitest" in imported_specs or re.search(r"\bfrom\s+['\"]vitest['\"]", text):
        return "vitest"
    if "jest" in imported_specs or "@jest/globals" in imported_specs:
        return "jest"
    if "mocha" in imported_specs:
        return "mocha"
    if "@playwright/test" in imported_specs or "playwright" in imported_specs:
        return "playwright"
    if "cypress" in imported_specs or re.search(r"\bcy\.", text):
        return "cypress"
    if re.search(r"\bdescribe\s*\(|\bit\s*\(|\btest\s*\(|\bexpect\s*\(", text):
        return "javascript-test"
    return None


def extract_test_names(text: str) -> list[str]:
    names: set[str] = set()
    pattern = re.compile(r"\b(?:it|test|describe)\s*\(\s*(['\"`])(?P<name>.+?)\1")
    for match in pattern.finditer(text):
        name = " ".join(match.group("name").split())
        if name:
            names.add(name)
    return sorted(names)


def test_info(rel: str, text: str, language: str | None) -> dict[str, Any]:
    if language not in {"javascript", "typescript"}:
        return {"hasTests": False, "framework": None, "testFunctions": []}
    framework = detect_test_framework(text)
    names = extract_test_names(text)
    has_tests = bool(is_test_path(rel) or framework or names)
    return {
        "hasTests": has_tests,
        "framework": framework or ("javascript-test" if has_tests else None),
        "testFunctions": names,
    }


def file_text_signals(rel: str, text: str, language: str | None) -> dict[str, Any]:
    signals: dict[str, Any] = {}
    if language in {"javascript", "typescript"}:
        framework = detect_test_framework(text)
        if framework:
            signals["testFramework"] = framework
        if re.search(r"\bexport\s+", text):
            signals["hasExports"] = True
    return signals


def path_matches_workspace(root: str, patterns: list[str]) -> bool:
    if not root:
        return False
    for pattern in patterns:
        normalized = pattern.strip("/")
        if "*" not in normalized:
            if root == normalized or root.startswith(f"{normalized}/"):
                return True
            continue
        prefix = normalized.split("*", 1)[0].rstrip("/")
        if prefix and root.startswith(f"{prefix}/"):
            return True
    return False


def package_root_for_manifest(path: str) -> str:
    parent = Path(path).parent.as_posix()
    return "" if parent == "." else parent


def build_context(manifests: list[dict[str, Any]], known_files: set[str]) -> dict[str, Any]:
    workspace_patterns_all: list[str] = []
    for manifest in manifests:
        if manifest.get("kind") in {"npm-package", "pnpm-workspace"}:
            workspace_patterns_all.extend(str(item) for item in manifest.get("workspaces", []) if isinstance(item, str))

    packages: list[dict[str, Any]] = []
    tsconfigs: list[dict[str, Any]] = []
    for manifest in manifests:
        kind = manifest.get("kind")
        path = str(manifest.get("path") or "")
        root = package_root_for_manifest(path)
        if kind == "npm-package":
            item = dict(manifest)
            item["root"] = root
            item["workspaceMember"] = path_matches_workspace(root, workspace_patterns_all)
            packages.append(item)
        elif kind in {"tsconfig", "jsconfig"}:
            item = dict(manifest)
            item["root"] = root
            tsconfigs.append(item)

    package_by_name = {
        str(package.get("packageName")): package
        for package in packages
        if isinstance(package.get("packageName"), str)
    }
    return {
        "knownFiles": set(known_files),
        "packages": sorted(packages, key=lambda item: (-len(str(item.get("root") or "")), str(item.get("root") or ""))),
        "packageByName": package_by_name,
        "tsconfigs": sorted(tsconfigs, key=lambda item: (-len(str(item.get("root") or "")), str(item.get("path") or ""))),
        "workspacePatterns": sorted(set(workspace_patterns_all)),
    }


def file_candidates(base: str) -> list[str]:
    candidates = [base]
    suffix = Path(base).suffix
    if suffix not in SOURCE_EXTENSIONS:
        candidates.extend(f"{base}{extension}" for extension in SOURCE_EXTENSIONS)
    candidates.extend(f"{base}/{index_name}" for index_name in INDEX_CANDIDATES)
    return [normalize_rel_parts(candidate) for candidate in candidates]


def first_existing_file(base: str, known_files: set[str]) -> str | None:
    for candidate in file_candidates(base):
        if candidate in known_files:
            return candidate
    return None


def package_for_path(rel: str, context: dict[str, Any]) -> dict[str, Any] | None:
    rel = rel.strip("/")
    for package in context.get("packages", []):
        root = str(package.get("root") or "")
        if not root:
            continue
        if rel == root or rel.startswith(f"{root}/"):
            return package
    return next((package for package in context.get("packages", []) if not package.get("root")), None)


def tsconfig_for_path(rel: str, context: dict[str, Any]) -> dict[str, Any] | None:
    rel = rel.strip("/")
    for config in context.get("tsconfigs", []):
        root = str(config.get("root") or "")
        if not root or rel == root or rel.startswith(f"{root}/"):
            return config
    return None


def resolve_relative(source_rel: str, spec: str, known_files: set[str]) -> str | None:
    base = (Path(source_rel).parent / spec).as_posix()
    return first_existing_file(base, known_files)


def target_base(config_root: str, base_url: str | None, target: str) -> str:
    base_parts = [config_root] if config_root else []
    if base_url:
        base_parts.append(base_url)
    base_parts.append(target)
    return normalize_rel_parts("/".join(part.strip("/") for part in base_parts if part not in {"", "."}))


def match_path_alias(spec: str, pattern: str, targets: list[str]) -> list[str]:
    if "*" not in pattern:
        return targets if spec == pattern else []
    prefix, suffix = pattern.split("*", 1)
    if not spec.startswith(prefix) or (suffix and not spec.endswith(suffix)):
        return []
    star = spec[len(prefix) : len(spec) - len(suffix) if suffix else len(spec)]
    return [target.replace("*", star) for target in targets]


def resolve_tsconfig_path(source_rel: str, spec: str, known_files: set[str], context: dict[str, Any]) -> str | None:
    config = tsconfig_for_path(source_rel, context)
    configs = [config] if config else []
    configs.extend(item for item in context.get("tsconfigs", []) if item is not config)
    for item in configs:
        if not isinstance(item, dict):
            continue
        paths = item.get("paths")
        if not isinstance(paths, dict):
            continue
        root = str(item.get("root") or "")
        base_url = item.get("baseUrl") if isinstance(item.get("baseUrl"), str) else None
        for pattern, raw_targets in sorted(paths.items(), key=lambda pair: str(pair[0])):
            targets = [str(target) for target in raw_targets if isinstance(target, str)] if isinstance(raw_targets, list) else []
            for target in match_path_alias(spec, str(pattern), targets):
                resolved = first_existing_file(target_base(root, base_url, target), known_files)
                if resolved:
                    return resolved
    return None


def package_subpath(spec: str, package_name: str) -> str:
    if spec == package_name:
        return ""
    return spec[len(package_name) :].lstrip("/")


def resolve_package_export(package: dict[str, Any], subpath: str, known_files: set[str]) -> str | None:
    root = str(package.get("root") or "")
    export_key = "." if not subpath else f"./{subpath}"
    export_targets = package.get("exportTargets")
    if isinstance(export_targets, dict):
        targets = export_targets.get(export_key)
        if isinstance(targets, list):
            for target in targets:
                if not isinstance(target, str):
                    continue
                resolved = first_existing_file(normalize_rel_parts(f"{root}/{target}".strip("/")), known_files)
                if resolved:
                    return resolved
    return None


def resolve_package_import(spec: str, known_files: set[str], context: dict[str, Any]) -> str | None:
    package_by_name = context.get("packageByName")
    if not isinstance(package_by_name, dict):
        return None
    for package_name in sorted(package_by_name, key=len, reverse=True):
        if spec != package_name and not spec.startswith(f"{package_name}/"):
            continue
        package = package_by_name[package_name]
        if not isinstance(package, dict):
            continue
        root = str(package.get("root") or "")
        subpath = package_subpath(spec, package_name)
        exported = resolve_package_export(package, subpath, known_files)
        if exported:
            return exported
        if subpath:
            for base in (
                normalize_rel_parts(f"{root}/{subpath}".strip("/")),
                normalize_rel_parts(f"{root}/src/{subpath}".strip("/")),
            ):
                resolved = first_existing_file(base, known_files)
                if resolved:
                    return resolved
        return root or None
    return None


def resolve_import(source_rel: str, spec: str, known_files: set[str], context: dict[str, Any]) -> str | None:
    if spec.startswith("."):
        return resolve_relative(source_rel, spec, known_files)
    tsconfig_resolved = resolve_tsconfig_path(source_rel, spec, known_files, context)
    if tsconfig_resolved:
        return tsconfig_resolved
    return resolve_package_import(spec, known_files, context)


def bin_targets(package: dict[str, Any], known_files: set[str]) -> list[str]:
    root = str(package.get("root") or "")
    raw_bin = package.get("bin")
    if not isinstance(raw_bin, dict):
        return []
    targets: set[str] = set()
    for target in raw_bin.values():
        if not isinstance(target, str):
            continue
        resolved = first_existing_file(normalize_rel_parts(f"{root}/{target}".strip("/")), known_files)
        if resolved:
            targets.add(resolved)
    return sorted(targets)


def module_fields(rel: str, context: dict[str, Any]) -> dict[str, Any]:
    language = language_for_source(rel)
    path = Path(rel)
    parts = set(path.parts)
    known_files = context.get("knownFiles", set())
    fields: dict[str, Any] = {}
    hints: list[dict[str, Any]] = []

    package = package_for_path(rel, context)
    if package and isinstance(package, dict):
        package_name = package.get("packageName")
        if isinstance(package_name, str):
            fields["packageName"] = package_name
        fields["packageRoot"] = str(package.get("root") or "")
        if package.get("packageType"):
            fields["packageType"] = package.get("packageType")
            hints.append(
                {
                    "kind": "npm-package-type",
                    "value": str(package.get("packageType")),
                    "path": rel,
                }
            )
        if package.get("workspaceMember"):
            fields["workspaceMember"] = True
        if rel == str(package.get("path")):
            hints.append(
                {
                    "kind": "npm-package",
                    "value": str(package_name or package.get("path")),
                    "path": rel,
                }
            )
        if language in {"javascript", "typescript"} and rel in bin_targets(package, known_files if isinstance(known_files, set) else set()):
            fields["executableBoundary"] = True
            hints.append(
                {
                    "kind": "npm-bin-entrypoint",
                    "value": "package.json bin entrypoint",
                    "path": rel,
                    "risk": "CLI package/bin entrypoint is not a generic helper module",
                }
            )

    config = tsconfig_for_path(rel, context)
    if config and rel == str(config.get("path")):
        hints.append({"kind": "tsconfig-project", "value": str(config.get("path")), "path": rel})
    elif config and language in {"javascript", "typescript"}:
        fields["tsconfigPath"] = str(config.get("path"))

    if language in {"javascript", "typescript"}:
        if "src" in parts:
            hints.append({"kind": "source-root", "value": "src/", "path": rel, "weak": True})
        if parts & {"test", "tests", "__tests__"} or is_test_path(rel):
            hints.append(
                {
                    "kind": "tsjs-test-file",
                    "value": "test file guides tests, not production helpers",
                    "path": rel,
                    "risk": "test files should guide tests, not production helper placement",
                }
            )
        if parts & SHARED_DIR_HINTS:
            hints.append(
                {
                    "kind": "shared-name-weak",
                    "value": ",".join(sorted(parts & SHARED_DIR_HINTS)),
                    "path": rel,
                    "weak": True,
                }
            )

    if hints:
        fields["boundaryHints"] = hints
        fields["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in hints)
    return fields


def import_matches_package(spec: str, package_name: str) -> bool:
    return spec == package_name or spec.startswith(f"{package_name}/")


def spec_matches_tsconfig_path(spec: str, context: dict[str, Any]) -> bool:
    for config in context.get("tsconfigs", []):
        paths = config.get("paths") if isinstance(config, dict) else None
        if not isinstance(paths, dict):
            continue
        for pattern, raw_targets in paths.items():
            targets = raw_targets if isinstance(raw_targets, list) else []
            if match_path_alias(spec, str(pattern), [str(target) for target in targets if isinstance(target, str)]):
                return True
    return False


def update_package_usage(
    modules: list[dict[str, Any]],
    manifests: list[dict[str, Any]],
    imports: list[dict[str, Any]],
    context: dict[str, Any],
) -> None:
    packages = [package for package in context.get("packages", []) if isinstance(package, dict)]
    referenced_by: dict[str, set[str]] = {str(package.get("root") or ""): set() for package in packages}
    tsconfig_refs: dict[str, set[str]] = {str(package.get("root") or ""): set() for package in packages}
    for item in imports:
        spec = str(item.get("imported") or "")
        importer = str(item.get("path") or "")
        if not spec or not importer:
            continue
        importer_package = package_for_path(importer, context)
        importer_root = str(importer_package.get("root") or "") if isinstance(importer_package, dict) else ""
        for package in packages:
            package_name = package.get("packageName")
            package_root = str(package.get("root") or "")
            if not isinstance(package_name, str) or not package_name:
                continue
            if not import_matches_package(spec, package_name):
                continue
            if importer_root != package_root:
                referenced_by.setdefault(package_root, set()).add(importer)
                if spec_matches_tsconfig_path(spec, context):
                    tsconfig_refs.setdefault(package_root, set()).add(importer)

    for manifest in manifests:
        if manifest.get("kind") != "npm-package":
            continue
        root = package_root_for_manifest(str(manifest.get("path") or ""))
        refs = sorted(referenced_by.get(root, set()))
        if refs:
            manifest["referencedBy"] = refs
            manifest["packageImportFanIn"] = len(refs)

    for module in modules:
        language = module.get("language")
        if language not in {"javascript", "typescript", "json"}:
            continue
        package = package_for_path(str(module.get("path") or ""), context)
        if not isinstance(package, dict):
            continue
        root = str(package.get("root") or "")
        refs = sorted(referenced_by.get(root, set()))
        if refs:
            module["packageImportedBy"] = refs
            module["packageImportCount"] = len(refs)
            if package.get("workspaceMember"):
                module["workspacePackageReferenced"] = True
        alias_refs = sorted(tsconfig_refs.get(root, set()))
        if alias_refs:
            module["tsconfigPathReferenced"] = True
            module["tsconfigPathImportedBy"] = alias_refs
