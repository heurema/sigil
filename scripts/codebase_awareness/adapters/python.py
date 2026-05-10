"""Python adapter for the shallow codebase awareness scanner."""

from __future__ import annotations

import configparser
import re
from pathlib import Path
from typing import Any

try:  # Python 3.11+
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - fallback exists for older runtimes.
    tomllib = None  # type: ignore[assignment]

from scripts.codebase_awareness.adapters.common import (
    normalize_rel_parts,
    split_identifier,
    tokens_for_path,
)

SOURCE_EXTENSIONS = (".py",)
SHARED_DIR_HINTS = {"common", "lib", "shared", "utils"}
TEST_FRAMEWORK_PACKAGES = {
    "hypothesis": "hypothesis",
    "pytest": "pytest",
    "unittest": "unittest",
}
TOOL_HINT_PACKAGES = {
    "coverage": "coverage",
    "mypy": "mypy",
    "ruff": "ruff",
}
FRAMEWORK_PACKAGES = {
    "click": "click",
    "django": "django",
    "fastapi": "fastapi",
    "flask": "flask",
    "pydantic": "pydantic",
    "typer": "typer",
}
BUILD_BACKEND_HINTS = {
    "hatch": ("hatchling", "hatch"),
    "pdm": ("pdm",),
    "poetry": ("poetry", "poetry-core"),
    "setuptools": ("setuptools",),
    "uv": ("uv",),
}
DEV_EXTRA_NAMES = {
    "check",
    "ci",
    "dev",
    "develop",
    "development",
    "lint",
    "qa",
    "test",
    "testing",
    "tests",
    "type",
    "typing",
}
PYTHON_IMPORT_BUILTINS = {
    "__future__",
    "abc",
    "argparse",
    "asyncio",
    "collections",
    "contextlib",
    "dataclasses",
    "datetime",
    "decimal",
    "enum",
    "functools",
    "hashlib",
    "itertools",
    "json",
    "logging",
    "math",
    "os",
    "pathlib",
    "re",
    "sys",
    "time",
    "typing",
    "unittest",
    "uuid",
}


def manifest_kinds() -> dict[str, str]:
    return {
        "Pipfile": "python-pipfile",
        "poetry.lock": "python-poetry-lock",
        "pyproject.toml": "python-project",
        "requirements.txt": "python-requirements",
        "setup.cfg": "python-setup-cfg",
        "setup.py": "python-setup",
        "uv.lock": "python-uv-lock",
    }


def manifest_kind_for_path(rel: str) -> str | None:
    path = Path(rel)
    if path.name in manifest_kinds():
        return manifest_kinds()[path.name]
    if len(path.parts) >= 2 and path.parts[-2] == "requirements" and path.name.endswith(".txt"):
        return "python-requirements"
    return None


def language_for_manifest(kind: str) -> str | None:
    if kind in {"python-project", "python-pipfile", "python-poetry-lock", "python-uv-lock"}:
        return "toml"
    if kind == "python-setup-cfg":
        return "ini"
    if kind == "python-setup":
        return "python"
    if kind == "python-requirements":
        return "text"
    return None


def language_for_source(rel: str) -> str | None:
    return "python" if Path(rel).suffix == ".py" else None


def manifest_tokens(rel: str, *values: Any) -> list[str]:
    tokens = set(tokens_for_path(rel))
    for value in values:
        if isinstance(value, str):
            tokens.update(split_identifier(value))
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, str):
                    tokens.update(split_identifier(item))
                elif isinstance(item, dict):
                    tokens.update(manifest_tokens("", item))
        elif isinstance(value, dict):
            for key, item in value.items():
                tokens.update(split_identifier(str(key)))
                tokens.update(manifest_tokens("", item))
    return sorted(token for token in tokens if token)


def string_list(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return sorted(str(item) for item in value if isinstance(item, str))
    return []


def parse_simple_toml_value(value: str) -> Any:
    value = value.strip().rstrip(",")
    if not value:
        return ""
    if value[0:1] in {"\"", "'"} and value[-1:] == value[0]:
        return value[1:-1]
    if value.startswith("[") and value.endswith("]"):
        body = value[1:-1].strip()
        if not body:
            return []
        items: list[str] = []
        current = ""
        quote = ""
        escaped = False
        for char in body:
            if quote:
                current += char
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = ""
                continue
            if char in {"\"", "'"}:
                quote = char
                current += char
                continue
            if char == ",":
                parsed = parse_simple_toml_value(current.strip())
                if isinstance(parsed, str) and parsed:
                    items.append(parsed)
                current = ""
                continue
            current += char
        parsed = parse_simple_toml_value(current.strip())
        if isinstance(parsed, str) and parsed:
            items.append(parsed)
        return items
    return value.strip("\"'")


def parse_simple_toml(text: str) -> dict[str, Any]:
    data: dict[str, Any] = {}
    table: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        table_match = re.match(r"^\[([A-Za-z0-9_.-]+)\]$", line)
        if table_match:
            table = table_match.group(1).split(".")
            current = data
            for part in table:
                current = current.setdefault(part, {})
            continue
        match = re.match(r"^([A-Za-z0-9_.-]+)\s*=\s*(.+)$", line)
        if not match:
            continue
        current = data
        for part in table:
            current = current.setdefault(part, {})
        key = match.group(1)
        current[key] = parse_simple_toml_value(match.group(2))
    return data


def parse_toml_document(text: str) -> dict[str, Any]:
    if tomllib is not None:
        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            data = {}
        return data if isinstance(data, dict) else {}
    return parse_simple_toml(text)


def requirement_name(value: str) -> str | None:
    line = value.split("#", 1)[0].strip()
    if not line or line.startswith(("-", "--")):
        return None
    if "://" in line or line.startswith(("git+", "hg+", "svn+")):
        egg_match = re.search(r"[#&]egg=([A-Za-z0-9_.-]+)", line)
        return egg_match.group(1).replace("_", "-").lower() if egg_match else None
    line = line.split(";", 1)[0].strip()
    match = re.match(r"^([A-Za-z0-9_.-]+)", line)
    if not match:
        return None
    return match.group(1).replace("_", "-").lower()


def dependency_names(values: list[str]) -> list[str]:
    names = {name for value in values if (name := requirement_name(value))}
    return sorted(names)


def dependency_names_from_mapping(value: Any) -> list[str]:
    if not isinstance(value, dict):
        return []
    return sorted(str(key).replace("_", "-").lower() for key in value if isinstance(key, str) and key.lower() != "python")


def test_framework_hints(deps: set[str]) -> list[dict[str, Any]]:
    hints: dict[tuple[str, str], dict[str, Any]] = {}
    for package in sorted(deps):
        framework = TEST_FRAMEWORK_PACKAGES.get(package)
        if framework:
            hints[(package, framework)] = {"package": package, "framework": framework}
    return [hints[key] for key in sorted(hints)]


def tool_hints(deps: set[str]) -> list[dict[str, str]]:
    return [
        {"package": package, "tool": TOOL_HINT_PACKAGES[package]}
        for package in sorted(deps)
        if package in TOOL_HINT_PACKAGES
    ]


def framework_hints(deps: set[str]) -> list[dict[str, str]]:
    return [
        {"package": package, "framework": FRAMEWORK_PACKAGES[package]}
        for package in sorted(deps)
        if package in FRAMEWORK_PACKAGES
    ]


def build_backend_hints(build_backend: str | None, deps: set[str], rel: str) -> list[str]:
    values = set(deps)
    if build_backend:
        values.update(split_identifier(build_backend))
        values.add(build_backend)
    if Path(rel).name == "uv.lock":
        values.add("uv")
    if Path(rel).name == "poetry.lock":
        values.add("poetry")
    hints: set[str] = set()
    haystack = " ".join(sorted(values)).lower()
    for hint, needles in BUILD_BACKEND_HINTS.items():
        if any(needle in haystack for needle in needles):
            hints.add(hint)
    return sorted(hints)


def script_targets(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    return {
        str(key): str(item)
        for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))
        if isinstance(item, str)
    }


def extract_pyproject_manifest(rel: str, text: str) -> dict[str, Any]:
    data = parse_toml_document(text)
    project = data.get("project") if isinstance(data.get("project"), dict) else {}
    tool = data.get("tool") if isinstance(data.get("tool"), dict) else {}
    poetry = tool.get("poetry") if isinstance(tool.get("poetry"), dict) else {}
    build_system = data.get("build-system") if isinstance(data.get("build-system"), dict) else {}

    project_name = project.get("name") if isinstance(project.get("name"), str) else None
    if project_name is None and isinstance(poetry.get("name"), str):
        project_name = poetry["name"]

    deps = dependency_names(string_list(project.get("dependencies")))
    optional_deps: list[str] = []
    dev_deps: set[str] = set()
    optional = project.get("optional-dependencies")
    if isinstance(optional, dict):
        for group, values in sorted(optional.items(), key=lambda pair: str(pair[0])):
            group_deps = dependency_names(string_list(values))
            if str(group).lower() in DEV_EXTRA_NAMES:
                dev_deps.update(group_deps)
            else:
                optional_deps.extend(group_deps)

    poetry_deps = dependency_names_from_mapping(poetry.get("dependencies"))
    poetry_group = poetry.get("group") if isinstance(poetry.get("group"), dict) else {}
    for group, group_data in sorted(poetry_group.items(), key=lambda pair: str(pair[0])):
        if not isinstance(group_data, dict):
            continue
        group_dep_names = dependency_names_from_mapping(group_data.get("dependencies"))
        if str(group).lower() in DEV_EXTRA_NAMES:
            dev_deps.update(group_dep_names)
        else:
            optional_deps.extend(group_dep_names)
    poetry_dev = poetry.get("dev-dependencies")
    dev_deps.update(dependency_names_from_mapping(poetry_dev))

    scripts = script_targets(project.get("scripts"))
    all_deps = set(deps) | set(optional_deps) | set(dev_deps) | set(poetry_deps)
    build_backend = build_system.get("build-backend") if isinstance(build_system.get("build-backend"), str) else None
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": "python-project",
        "language": "toml",
        "tokens": manifest_tokens(rel, project_name or "", deps, optional_deps, sorted(dev_deps), scripts),
    }
    if project_name:
        manifest["projectName"] = project_name
        manifest["packageName"] = project_name.replace("-", "_")
    combined_deps = sorted(set(deps) | set(poetry_deps))
    if combined_deps:
        manifest["dependencies"] = combined_deps
    if dev_deps:
        manifest["devDependencies"] = sorted(dev_deps)
    if optional_deps:
        manifest["optionalDependencies"] = sorted(set(optional_deps))
    if build_backend:
        manifest["buildBackend"] = build_backend
    build_hints = build_backend_hints(build_backend, all_deps, rel)
    if build_hints:
        manifest["buildBackendHints"] = build_hints
    if scripts:
        manifest["scripts"] = scripts
        manifest["entrypoints"] = scripts
    test_hints = test_framework_hints(all_deps)
    if test_hints:
        manifest["testFrameworkHints"] = test_hints
    tools = tool_hints(all_deps)
    if tools:
        manifest["toolHints"] = tools
    frameworks = framework_hints(all_deps)
    if frameworks:
        manifest["frameworkHints"] = frameworks
    return manifest


def extract_requirements_manifest(rel: str, text: str) -> dict[str, Any]:
    deps = dependency_names(text.splitlines())
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": "python-requirements",
        "language": "text",
        "tokens": manifest_tokens(rel, deps),
    }
    if "dev" in Path(rel).parts or Path(rel).stem in DEV_EXTRA_NAMES:
        if deps:
            manifest["devDependencies"] = deps
    elif deps:
        manifest["dependencies"] = deps
    all_deps = set(deps)
    test_hints = test_framework_hints(all_deps)
    if test_hints:
        manifest["testFrameworkHints"] = test_hints
    tools = tool_hints(all_deps)
    if tools:
        manifest["toolHints"] = tools
    frameworks = framework_hints(all_deps)
    if frameworks:
        manifest["frameworkHints"] = frameworks
    return manifest


def multiline_list_assignment(text: str, key: str) -> list[str]:
    match = re.search(rf"{re.escape(key)}\s*=\s*\[(?P<body>.*?)\]", text, flags=re.DOTALL)
    if not match:
        return []
    return re.findall(r"['\"]([^'\"]+)['\"]", match.group("body"))


def setup_keyword_value(text: str, key: str) -> str | None:
    match = re.search(rf"{re.escape(key)}\s*=\s*['\"]([^'\"]+)['\"]", text)
    return match.group(1) if match else None


def extract_setup_py_manifest(rel: str, text: str) -> dict[str, Any]:
    project_name = setup_keyword_value(text, "name")
    deps = dependency_names(multiline_list_assignment(text, "install_requires"))
    dev_deps = dependency_names(multiline_list_assignment(text, "tests_require"))
    all_deps = set(deps) | set(dev_deps)
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": "python-setup",
        "language": "python",
        "tokens": manifest_tokens(rel, project_name or "", deps, dev_deps),
    }
    if project_name:
        manifest["projectName"] = project_name
        manifest["packageName"] = project_name.replace("-", "_")
    if deps:
        manifest["dependencies"] = deps
    if dev_deps:
        manifest["devDependencies"] = dev_deps
    build_hints = build_backend_hints("setuptools", all_deps | {"setuptools"}, rel)
    if build_hints:
        manifest["buildBackendHints"] = build_hints
    test_hints = test_framework_hints(all_deps)
    if test_hints:
        manifest["testFrameworkHints"] = test_hints
    return manifest


def split_cfg_values(value: str) -> list[str]:
    values: list[str] = []
    for line in value.splitlines():
        stripped = line.strip()
        if stripped:
            values.append(stripped)
    if not values and value.strip():
        values.append(value.strip())
    return values


def extract_setup_cfg_manifest(rel: str, text: str) -> dict[str, Any]:
    parser = configparser.ConfigParser()
    try:
        parser.read_string(text)
    except configparser.Error:
        parser = configparser.ConfigParser()
    project_name = parser.get("metadata", "name", fallback=None)
    deps: list[str] = []
    dev_deps: set[str] = set()
    if parser.has_option("options", "install_requires"):
        deps = dependency_names(split_cfg_values(parser.get("options", "install_requires")))
    if parser.has_section("options.extras_require"):
        for group, value in parser.items("options.extras_require"):
            parsed = dependency_names(split_cfg_values(value))
            if group.lower() in DEV_EXTRA_NAMES:
                dev_deps.update(parsed)
    entrypoints: dict[str, str] = {}
    if parser.has_section("options.entry_points"):
        for _group, value in parser.items("options.entry_points"):
            for line in split_cfg_values(value):
                if "=" in line:
                    name, target = line.split("=", 1)
                    entrypoints[name.strip()] = target.strip()
    all_deps = set(deps) | set(dev_deps)
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": "python-setup-cfg",
        "language": "ini",
        "tokens": manifest_tokens(rel, project_name or "", deps, sorted(dev_deps), entrypoints),
    }
    if project_name:
        manifest["projectName"] = project_name
        manifest["packageName"] = project_name.replace("-", "_")
    if deps:
        manifest["dependencies"] = deps
    if dev_deps:
        manifest["devDependencies"] = sorted(dev_deps)
    if entrypoints:
        manifest["entrypoints"] = entrypoints
    build_hints = build_backend_hints("setuptools", all_deps | {"setuptools"}, rel)
    if build_hints:
        manifest["buildBackendHints"] = build_hints
    test_hints = test_framework_hints(all_deps)
    if test_hints:
        manifest["testFrameworkHints"] = test_hints
    return manifest


def extract_lock_manifest(rel: str, text: str, kind: str) -> dict[str, Any]:
    names = sorted(set(re.findall(r"(?m)^\s*name\s*=\s*['\"]([^'\"]+)['\"]", text)))
    deps = [name.replace("_", "-").lower() for name in names]
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": kind,
        "language": "toml",
        "tokens": manifest_tokens(rel, deps),
    }
    if deps:
        manifest["dependencies"] = deps
    build_hints = build_backend_hints(None, set(deps), rel)
    if build_hints:
        manifest["buildBackendHints"] = build_hints
    test_hints = test_framework_hints(set(deps))
    if test_hints:
        manifest["testFrameworkHints"] = test_hints
    return manifest


def extract_pipfile_manifest(rel: str, text: str) -> dict[str, Any]:
    data = parse_toml_document(text)
    packages = dependency_names_from_mapping(data.get("packages"))
    dev_packages = dependency_names_from_mapping(data.get("dev-packages"))
    all_deps = set(packages) | set(dev_packages)
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": "python-pipfile",
        "language": "toml",
        "tokens": manifest_tokens(rel, packages, dev_packages),
    }
    if packages:
        manifest["dependencies"] = packages
    if dev_packages:
        manifest["devDependencies"] = dev_packages
    test_hints = test_framework_hints(all_deps)
    if test_hints:
        manifest["testFrameworkHints"] = test_hints
    tools = tool_hints(all_deps)
    if tools:
        manifest["toolHints"] = tools
    frameworks = framework_hints(all_deps)
    if frameworks:
        manifest["frameworkHints"] = frameworks
    return manifest


def extract_manifest(rel: str, text: str, manifest_kind: str) -> dict[str, Any] | None:
    if manifest_kind == "python-project":
        return extract_pyproject_manifest(rel, text)
    if manifest_kind == "python-requirements":
        return extract_requirements_manifest(rel, text)
    if manifest_kind == "python-setup":
        return extract_setup_py_manifest(rel, text)
    if manifest_kind == "python-setup-cfg":
        return extract_setup_cfg_manifest(rel, text)
    if manifest_kind == "python-pipfile":
        return extract_pipfile_manifest(rel, text)
    if manifest_kind in {"python-poetry-lock", "python-uv-lock"}:
        return extract_lock_manifest(rel, text, manifest_kind)
    return None


def line_without_comment(line: str) -> str:
    quote = ""
    escaped = False
    for index, char in enumerate(line):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
            continue
        if char in {"\"", "'"}:
            quote = char
            continue
        if char == "#":
            return line[:index]
    return line


def indentation(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def visibility_for_name(name: str) -> str:
    if name.startswith("__") and name.endswith("__"):
        return "special"
    if name.startswith("_"):
        return "private"
    return "public"


def is_exported_name(name: str) -> bool:
    return visibility_for_name(name) == "public"


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
    record: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "language": "python",
        "path": rel,
        "line": line_number,
        "exported": exported,
        "visibility": visibility,
        "tokens": sorted(set(split_identifier(token_source or name))),
    }
    if visibility in {"private", "special"}:
        record["visibilityRisks"] = ["private Python helper is module-local by convention"]
    return record


def base_classes(raw: str) -> list[str]:
    if not raw.strip():
        return []
    bases: list[str] = []
    for item in raw.split(","):
        name = item.strip().split("[", 1)[0].split("(", 1)[0].strip()
        if "." in name:
            name = name.rsplit(".", 1)[-1]
        if re.fullmatch(r"[A-Za-z_][\w]*", name):
            bases.append(name)
    return sorted(set(bases))


def extract_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    if language_for_source(rel) != "python":
        return []
    records: list[dict[str, Any]] = []
    seen: set[tuple[str, str, int]] = set()
    class_stack: list[dict[str, Any]] = []
    pending_decorators: list[str] = []
    function_re = re.compile(r"^(?P<indent>\s*)(?P<async>async\s+)?def\s+(?P<name>[A-Za-z_][\w]*)\s*\(")
    class_re = re.compile(r"^(?P<indent>\s*)class\s+(?P<name>[A-Za-z_][\w]*)(?:\((?P<bases>[^)]*)\))?\s*:")
    constant_re = re.compile(r"^(?P<name>[A-Z][A-Z0-9_]+)\s*(?::[^=]+)?=\s*.+$")
    decorator_re = re.compile(r"^\s*@([A-Za-z_][\w.]*)(?:\(|$)")

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        line = line_without_comment(raw_line)
        if not line.strip():
            continue
        indent = indentation(line)
        while class_stack and indent <= int(class_stack[-1]["indent"]):
            class_stack.pop()

        decorator = decorator_re.match(line)
        if decorator:
            pending_decorators.append(decorator.group(1).rsplit(".", 1)[-1])
            continue

        class_match = class_re.match(line)
        if class_match:
            name = class_match.group("name")
            if visibility_for_name(name) == "special":
                pending_decorators = []
                continue
            visibility = visibility_for_name(name)
            bases = base_classes(class_match.group("bases") or "")
            exported = is_exported_name(name)
            key = (name, "class", line_number)
            if key not in seen:
                seen.add(key)
                record = symbol_record(
                    rel=rel,
                    line_number=line_number,
                    name=name,
                    kind="class",
                    exported=exported,
                    visibility=visibility,
                )
                if bases:
                    record["baseClasses"] = bases
                if "dataclass" in pending_decorators:
                    record["dataclass"] = True
                if "BaseModel" in bases:
                    record["pydanticModel"] = True
                records.append(record)
            class_stack.append({"name": name, "indent": indent, "exported": exported})
            pending_decorators = []
            continue

        function_match = function_re.match(line)
        if function_match:
            name = function_match.group("name")
            if visibility_for_name(name) == "special":
                pending_decorators = []
                continue
            current_class = class_stack[-1] if class_stack else None
            if current_class:
                visibility = visibility_for_name(name)
                exported = bool(current_class.get("exported")) and is_exported_name(name)
                kind = "method"
                token_source = f"{current_class.get('name')} {name}"
            else:
                visibility = visibility_for_name(name)
                exported = is_exported_name(name)
                kind = "function"
                token_source = name
            key = (name, kind, line_number)
            if key not in seen:
                seen.add(key)
                record = symbol_record(
                    rel=rel,
                    line_number=line_number,
                    name=name,
                    kind=kind,
                    exported=exported,
                    visibility=visibility,
                    token_source=token_source,
                )
                if function_match.group("async"):
                    record["async"] = True
                if current_class:
                    record["className"] = current_class.get("name")
                if "classmethod" in pending_decorators:
                    record["methodType"] = "classmethod"
                elif "staticmethod" in pending_decorators:
                    record["methodType"] = "staticmethod"
                if is_test_path(rel) or name.startswith("test_"):
                    record["testOnly"] = True
                records.append(record)
            pending_decorators = []
            continue

        if indent == 0:
            constant_match = constant_re.match(line)
            if constant_match:
                name = constant_match.group("name")
                visibility = visibility_for_name(name)
                if visibility == "special":
                    pending_decorators = []
                    continue
                key = (name, "constant", line_number)
                if key not in seen:
                    seen.add(key)
                    records.append(
                        symbol_record(
                            rel=rel,
                            line_number=line_number,
                            name=name,
                            kind="constant",
                            exported=is_exported_name(name),
                            visibility=visibility,
                        )
                    )
        pending_decorators = []
    return records


def parse_import_items(raw: str) -> list[tuple[str, str | None]]:
    items: list[tuple[str, str | None]] = []
    if "(" in raw and ")" in raw:
        raw = raw.replace("(", "").replace(")", "")
    for item in raw.split(","):
        cleaned = item.strip()
        if not cleaned:
            continue
        match = re.match(r"^(?P<name>[A-Za-z_][\w.]*|\*)(?:\s+as\s+(?P<alias>[A-Za-z_][\w]*))?$", cleaned)
        if match:
            items.append((match.group("name"), match.group("alias")))
    return items


def import_record(
    *,
    imported: str,
    kind: str,
    line_number: int,
    symbols: list[str] | None = None,
    alias: Any = None,
) -> dict[str, Any]:
    tokens = set(split_identifier(imported))
    for symbol in symbols or []:
        tokens.update(split_identifier(symbol))
    record: dict[str, Any] = {
        "imported": imported,
        "kind": kind,
        "line": line_number,
        "tokens": sorted(tokens),
    }
    if symbols:
        record["symbols"] = sorted(set(symbols))
    if alias:
        record["alias"] = alias
    return record


def extract_import_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    import_re = re.compile(r"^\s*import\s+(?P<body>.+)$")
    from_re = re.compile(r"^\s*from\s+(?P<module>\.*[A-Za-z_][\w.]*)\s+import\s+(?P<body>.+)$")
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = line_without_comment(raw_line).strip()
        if not line:
            continue
        import_match = import_re.match(line)
        if import_match:
            for imported, alias in parse_import_items(import_match.group("body")):
                records.append(
                    import_record(
                        imported=imported,
                        kind="import",
                        line_number=line_number,
                        alias=alias,
                    )
                )
            continue
        from_match = from_re.match(line)
        if from_match:
            symbols: list[str] = []
            aliases: dict[str, str] = {}
            for symbol, alias in parse_import_items(from_match.group("body")):
                symbols.append(symbol)
                if alias:
                    aliases[symbol] = alias
            alias_value: Any = None
            if len(aliases) == 1:
                alias_value = next(iter(aliases.values()))
            elif aliases:
                alias_value = aliases
            records.append(
                import_record(
                    imported=from_match.group("module"),
                    kind="from-import",
                    line_number=line_number,
                    symbols=symbols,
                    alias=alias_value,
                )
            )
    unique: dict[tuple[str, str, int, str], dict[str, Any]] = {}
    for record in records:
        unique[
            (
                str(record.get("imported")),
                str(record.get("kind")),
                int(record.get("line", 0)),
                ",".join(str(item) for item in record.get("symbols", [])),
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
        or name.startswith("test_")
        or name.endswith("_test.py")
    ) and path.suffix == ".py"


def detect_test_framework(text: str) -> str | None:
    imports = extract_import_records(text)
    imported_specs = {str(item.get("imported")) for item in imports}
    imported_symbols = {
        str(symbol)
        for item in imports
        for symbol in item.get("symbols", [])
        if isinstance(symbol, str)
    }
    if "hypothesis" in imported_specs or "given" in imported_symbols:
        return "hypothesis"
    if "pytest" in imported_specs or re.search(r"@\s*pytest\.fixture\b", text) or re.search(r"\bpytest\.", text):
        return "pytest"
    if "unittest" in imported_specs or re.search(r"\bunittest\.TestCase\b", text):
        return "unittest"
    if re.search(r"(?m)^\s*def\s+test_[A-Za-z_][\w]*\s*\(", text):
        return "pytest"
    return None


def extract_test_names(text: str) -> list[str]:
    names: set[str] = set()
    for match in re.finditer(r"(?m)^\s*(?:async\s+)?def\s+(test_[A-Za-z_][\w]*)\s*\(", text):
        names.add(match.group(1))
    for match in re.finditer(r"(?m)^\s*class\s+([A-Za-z_][\w]*Test|Test[A-Za-z_][\w]*)\s*\(", text):
        names.add(match.group(1))
    return sorted(names)


def extract_pytest_fixtures(text: str) -> list[str]:
    fixtures: set[str] = set()
    pending_fixture = False
    for line in text.splitlines():
        if re.search(r"@\s*pytest\.fixture\b", line):
            pending_fixture = True
            continue
        if pending_fixture:
            match = re.search(r"^\s*def\s+([A-Za-z_][\w]*)\s*\(", line)
            if match:
                fixtures.add(match.group(1))
            pending_fixture = False
    return sorted(fixtures)


def test_info(rel: str, text: str, language: str | None) -> dict[str, Any]:
    if language != "python":
        return {"hasTests": False, "framework": None, "testFunctions": []}
    framework = detect_test_framework(text)
    names = extract_test_names(text)
    fixtures = extract_pytest_fixtures(text)
    has_tests = bool(is_test_path(rel) or framework or names or fixtures)
    info: dict[str, Any] = {
        "hasTests": has_tests,
        "framework": framework or ("python-test" if has_tests else None),
        "testFunctions": names,
    }
    if fixtures:
        info["fixtures"] = fixtures
    return info


def file_text_signals(rel: str, text: str, language: str | None) -> dict[str, Any]:
    if language != "python":
        return {}
    signals: dict[str, Any] = {}
    framework = detect_test_framework(text)
    if framework:
        signals["testFramework"] = framework
    fixtures = extract_pytest_fixtures(text)
    if fixtures:
        signals["pytestFixtures"] = fixtures
    imports = extract_import_records(text)
    imported = {str(item.get("imported")).lstrip(".").split(".", 1)[0] for item in imports}
    framework_imports = sorted((imported & set(FRAMEWORK_PACKAGES)) - {""})
    if framework_imports:
        signals["frameworkImports"] = framework_imports
    if "dataclass" in text:
        signals["dataclassHint"] = True
    if "BaseModel" in text:
        signals["pydanticModelHint"] = True
    return signals


def package_root_for_manifest(path: str) -> str:
    parent = Path(path).parent.as_posix()
    return "" if parent == "." else parent


def module_name_for_path(rel: str, source_roots: list[str]) -> str | None:
    path = Path(rel)
    if path.suffix != ".py":
        return None
    for root in sorted(source_roots, key=len, reverse=True):
        if root:
            try:
                relative = path.relative_to(root)
            except ValueError:
                continue
        else:
            relative = path
        parts = list(relative.with_suffix("").parts)
        if not parts:
            continue
        if parts[-1] == "__init__":
            parts = parts[:-1]
        if not parts:
            continue
        return ".".join(parts)
    return None


def entrypoint_module(target: str) -> str | None:
    module = target.split(":", 1)[0].strip()
    return module if module else None


def build_context(manifests: list[dict[str, Any]], known_files: set[str]) -> dict[str, Any]:
    source_roots: set[str] = {""}
    if any(path.startswith("src/") for path in known_files):
        source_roots.add("src")
    package_dirs = {
        str(Path(path).parent.as_posix())
        for path in known_files
        if path.endswith("/__init__.py") or path == "__init__.py"
    }
    for package_dir in package_dirs:
        parent = Path(package_dir).parent.as_posix()
        if parent == ".":
            source_roots.add("")
        elif parent:
            source_roots.add(parent)
    projects: list[dict[str, Any]] = []
    entrypoint_modules: set[str] = set()
    for manifest in manifests:
        if not str(manifest.get("kind") or "").startswith("python-"):
            continue
        project = dict(manifest)
        project["root"] = package_root_for_manifest(str(manifest.get("path") or ""))
        projects.append(project)
        for target in script_targets(manifest.get("entrypoints")).values():
            module = entrypoint_module(target)
            if module:
                entrypoint_modules.add(module)

    ordered_roots = sorted(source_roots, key=lambda item: (-len(item), item))
    module_to_path: dict[str, str] = {}
    package_by_dir: dict[str, str] = {}
    for package_dir in sorted(package_dirs):
        module = module_name_for_path(f"{package_dir}/__init__.py", ordered_roots)
        if module:
            package_by_dir[package_dir] = module
            module_to_path[module] = f"{package_dir}/__init__.py"
    for path in sorted(known_files):
        module = module_name_for_path(path, ordered_roots)
        if module:
            module_to_path[module] = path
    entrypoint_paths: set[str] = set()
    for module in sorted(entrypoint_modules):
        resolved = module_to_path.get(module)
        if resolved:
            entrypoint_paths.add(resolved)
    return {
        "knownFiles": set(known_files),
        "sourceRoots": ordered_roots,
        "packageDirs": sorted(package_dirs),
        "packageByDir": package_by_dir,
        "moduleToPath": module_to_path,
        "projects": sorted(projects, key=lambda item: str(item.get("path") or "")),
        "entrypointModules": sorted(entrypoint_modules),
        "entrypointPaths": sorted(entrypoint_paths),
    }


def file_candidates(base: str) -> list[str]:
    normalized = normalize_rel_parts(base)
    return [
        normalized,
        f"{normalized}.py",
        f"{normalized}/__init__.py",
    ]


def first_existing_file(base: str, known_files: set[str]) -> str | None:
    for candidate in file_candidates(base):
        if candidate in known_files:
            return candidate
    return None


def resolve_absolute(spec: str, known_files: set[str], context: dict[str, Any]) -> str | None:
    module_to_path = context.get("moduleToPath")
    if isinstance(module_to_path, dict):
        resolved = module_to_path.get(spec)
        if isinstance(resolved, str):
            return resolved
    module_path = spec.replace(".", "/")
    for root in context.get("sourceRoots", [""]):
        base = normalize_rel_parts(f"{root}/{module_path}".strip("/"))
        resolved = first_existing_file(base, known_files)
        if resolved:
            return resolved
    return None


def resolve_relative(source_rel: str, spec: str, known_files: set[str]) -> str | None:
    match = re.match(r"^(\.+)(.*)$", spec)
    if not match:
        return None
    level = len(match.group(1))
    remainder = match.group(2).strip(".")
    base = Path(source_rel).parent
    for _ in range(max(0, level - 1)):
        base = base.parent
    if remainder:
        base = base / remainder.replace(".", "/")
    return first_existing_file(base.as_posix(), known_files)


def resolve_from_import_symbol(
    spec: str,
    symbols: list[str],
    known_files: set[str],
    context: dict[str, Any],
) -> str | None:
    if len(symbols) != 1:
        return None
    symbol = symbols[0]
    if not re.fullmatch(r"[A-Za-z_][\w]*", symbol):
        return None
    combined = f"{spec}.{symbol}" if spec else symbol
    return resolve_absolute(combined, known_files, context)


def resolve_import(
    source_rel: str,
    spec: str,
    known_files: set[str],
    context: dict[str, Any],
    import_record: dict[str, Any] | None = None,
) -> str | None:
    if spec.startswith("."):
        resolved = resolve_relative(source_rel, spec, known_files)
        if resolved:
            return resolved
        if import_record:
            symbols = [str(item) for item in import_record.get("symbols", []) if isinstance(item, str)]
            for symbol in symbols:
                resolved = resolve_relative(source_rel, f"{spec}.{symbol}", known_files)
                if resolved:
                    return resolved
        return None
    if import_record and import_record.get("kind") == "from-import":
        symbols = [str(item) for item in import_record.get("symbols", []) if isinstance(item, str)]
        resolved = resolve_from_import_symbol(spec, symbols, known_files, context)
        if resolved:
            return resolved
    resolved = resolve_absolute(spec, known_files, context)
    if resolved:
        return resolved
    if import_record:
        symbols = [str(item) for item in import_record.get("symbols", []) if isinstance(item, str)]
        return resolve_from_import_symbol(spec, symbols, known_files, context)
    return None


def package_dir_for_path(rel: str, context: dict[str, Any]) -> str | None:
    path = Path(rel)
    for package_dir in sorted(context.get("packageDirs", []), key=len, reverse=True):
        if path.as_posix() == package_dir or path.as_posix().startswith(f"{package_dir}/"):
            return str(package_dir)
    return None


def module_fields(
    rel: str,
    context: dict[str, Any],
    manifest: dict[str, Any] | None = None,
    signals: dict[str, Any] | None = None,
) -> dict[str, Any]:
    path = Path(rel)
    parts = set(path.parts)
    fields: dict[str, Any] = {}
    hints: list[dict[str, Any]] = []
    signals = signals or {}

    if manifest and str(manifest.get("kind") or "").startswith("python-"):
        if manifest.get("projectName"):
            fields["projectName"] = manifest.get("projectName")
        hint_kind = "python-project" if manifest.get("kind") in {"python-project", "python-setup", "python-setup-cfg"} else "python-manifest"
        hints.append(
            {
                "kind": hint_kind,
                "value": str(manifest.get("projectName") or manifest.get("kind")),
                "path": rel,
            }
        )

    if path.suffix == ".py":
        package_dir = package_dir_for_path(rel, context)
        module_name = module_name_for_path(rel, context.get("sourceRoots", [""]))
        if module_name:
            fields["moduleName"] = module_name
        if package_dir:
            fields["packagePath"] = package_dir
            package_name = context.get("packageByDir", {}).get(package_dir)
            if package_name:
                fields["packageName"] = package_name
            hints.append({"kind": "python-package", "value": package_name or package_dir, "path": rel})
        if "src" in parts:
            hints.append({"kind": "source-root", "value": "src/", "path": rel, "weak": True})
        if parts & {"test", "tests"} or is_test_path(rel):
            hints.append(
                {
                    "kind": "python-test-file",
                    "value": "test file guides tests, not production helpers",
                    "path": rel,
                    "risk": "Python test files should guide tests, not production helper placement",
                }
            )
        if path.name.startswith("_") and not (path.name.startswith("__") and path.name.endswith("__.py")):
            fields["privateModule"] = True
            hints.append(
                {
                    "kind": "python-private-module",
                    "value": "leading underscore private module",
                    "path": rel,
                    "risk": "Private Python modules are not reusable outside the package boundary by convention",
                }
            )
        if path.name == "__main__.py" or rel in set(context.get("entrypointPaths", [])):
            fields["executableBoundary"] = True
            hints.append(
                {
                    "kind": "python-cli-entrypoint",
                    "value": "Python CLI entrypoint",
                    "path": rel,
                    "risk": "Python CLI entrypoint is not a generic helper module",
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
        for framework in signals.get("frameworkImports", []):
            hints.append({"kind": "python-framework", "value": str(framework), "path": rel, "weak": True})

    if hints:
        fields["boundaryHints"] = hints
        fields["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in hints)
    return fields


def build_package_modules(
    modules: list[dict[str, Any]],
    symbols: list[dict[str, Any]],
    tests: list[dict[str, Any]],
    importers_by_target: dict[str, list[str]],
    context: dict[str, Any],
) -> list[dict[str, Any]]:
    package_modules: list[dict[str, Any]] = []
    symbols_by_path: dict[str, list[dict[str, Any]]] = {}
    for symbol in symbols:
        symbols_by_path.setdefault(str(symbol.get("path") or ""), []).append(symbol)
    modules_by_path = {str(module.get("path") or ""): module for module in modules}
    for package_dir in sorted(context.get("packageDirs", [])):
        source_files = sorted(
            path
            for path, module in modules_by_path.items()
            if module.get("language") == "python"
            and module.get("kind") == "source"
            and (path == package_dir or path.startswith(f"{package_dir}/"))
        )
        if not source_files:
            continue
        package_name = context.get("packageByDir", {}).get(package_dir) or package_dir.replace("/", ".")
        imported_by = sorted(
            {
                importer
                for source_file in source_files
                for importer in importers_by_target.get(source_file, [])
            }
        )
        public_symbols = sorted(
            {
                str(symbol.get("name"))
                for source_file in source_files
                for symbol in symbols_by_path.get(source_file, [])
                if symbol.get("exported") and isinstance(symbol.get("name"), str)
            }
        )
        private_symbols = sorted(
            {
                str(symbol.get("name"))
                for source_file in source_files
                for symbol in symbols_by_path.get(source_file, [])
                if str(symbol.get("visibility") or "") == "private" and isinstance(symbol.get("name"), str)
            }
        )
        test_files = sorted(
            str(test.get("path"))
            for test in tests
            if isinstance(test.get("path"), str)
            and (
                str(test.get("path")).startswith(f"tests/{Path(package_dir).name}")
                or set(tokens_for_path(str(test.get("path")))) & set(split_identifier(package_name))
                or set(tokens_for_path(str(test.get("path")))) & {token for symbol in public_symbols for token in split_identifier(symbol)}
            )
        )
        hints = [{"kind": "python-package", "value": str(package_name), "path": package_dir}]
        if any(bool(module.get("executableBoundary")) for path, module in modules_by_path.items() if path in source_files):
            hints.append(
                {
                    "kind": "python-cli-entrypoint",
                    "value": "Python CLI entrypoint",
                    "path": package_dir,
                    "risk": "Python CLI entrypoint package is not a generic helper module",
                }
            )
        module: dict[str, Any] = {
            "path": package_dir,
            "name": Path(package_dir).name,
            "directory": Path(package_dir).parent.as_posix() if Path(package_dir).parent.as_posix() != "." else "",
            "language": "python",
            "kind": "package",
            "packageName": package_name,
            "sourceFiles": source_files,
            "files": source_files,
            "symbols": public_symbols,
            "tokens": sorted(set(tokens_for_path(package_dir)) | set(split_identifier(package_name))),
            "lineCount": sum(int(modules_by_path.get(path, {}).get("lineCount", 0)) for path in source_files),
            "boundaryHints": hints,
            "boundaryKinds": sorted(str(hint.get("kind")) for hint in hints),
        }
        if imported_by:
            module["importedBy"] = imported_by
            module["importCount"] = len(imported_by)
        if test_files:
            module["pairedTests"] = test_files
        if private_symbols:
            module["privateSymbols"] = private_symbols
        if any(hint.get("kind") == "python-cli-entrypoint" for hint in hints):
            module["executableBoundary"] = True
        package_modules.append(module)
    return package_modules
