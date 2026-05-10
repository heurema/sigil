"""C#/.NET adapter for the shallow codebase awareness scanner."""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Any

from scripts.codebase_awareness.adapters.common import (
    is_test_path,
    normalize_rel_parts,
    split_identifier,
    tokens_for_path,
)

TEST_PACKAGE_FRAMEWORKS = {
    "microsoft.net.test.sdk": "dotnet-test",
    "mstest.testframework": "mstest",
    "nunit": "nunit",
    "xunit": "xunit",
}
EXTERNAL_NAMESPACE_PREFIXES = ("Microsoft.", "Newtonsoft.", "System.")


def manifest_kinds() -> dict[str, str]:
    return {
        "Directory.Build.props": "dotnet-props",
        "Directory.Build.targets": "dotnet-targets",
    }


def manifest_kind_for_path(rel: str) -> str | None:
    path = Path(rel)
    if path.suffix == ".sln":
        return "dotnet-solution"
    if path.suffix == ".csproj":
        return "dotnet-project"
    if path.name == "Directory.Build.props" or path.suffix == ".props":
        return "dotnet-props"
    if path.name == "Directory.Build.targets" or path.suffix == ".targets":
        return "dotnet-targets"
    return None


def language_for_manifest(kind: str) -> str | None:
    if kind in {"dotnet-project", "dotnet-props", "dotnet-solution", "dotnet-targets"}:
        return "csharp"
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
        if char in {"\"", "'"}:
            in_string = True
            quote = char
            continue
        if char == "/" and index + 1 < len(line) and line[index + 1] == "/":
            return line[:index]
    return line


def brace_delta(line: str) -> int:
    stripped = line_without_comment(line)
    return stripped.count("{") - stripped.count("}")


def normalize_visibility(modifiers: str, default_visibility: str) -> str:
    words = set(re.findall(r"\b(public|internal|private|protected)\b", modifiers))
    if "private" in words and "protected" in words:
        return "private protected"
    if "protected" in words and "internal" in words:
        return "protected internal"
    for visibility in ("public", "internal", "private", "protected"):
        if visibility in words:
            return visibility
    return default_visibility


def visibility_exported(visibility: str) -> bool:
    return visibility == "public"


def visibility_risk(visibility: str) -> str | None:
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


def symbol_record(
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
        "exported": visibility_exported(visibility),
        "visibility": visibility,
        "static": is_static,
        "tokens": sorted(tokens),
    }
    if namespace:
        record["namespace"] = namespace
    if container:
        record["container"] = container
    risk = visibility_risk(visibility)
    if risk:
        record["visibilityRisks"] = [risk]
    return record


def extract_namespaces(rel: str, text: str) -> list[dict[str, Any]]:
    namespaces: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = line_without_comment(line)
        match = re.search(r"^\s*namespace\s+([A-Za-z_][\w.]*)\s*(?:[;{]|$)", stripped)
        if not match:
            continue
        namespace = match.group(1)
        if namespace in seen:
            continue
        seen.add(namespace)
        namespaces.append(
            symbol_record(
                rel=rel,
                line_number=line_number,
                kind="namespace",
                name=namespace,
                visibility="public",
                namespace=namespace,
            )
        )
    return namespaces


def extract_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    symbols = extract_namespaces(rel, text)
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
        line = line_without_comment(raw_line)
        stripped = line.strip()
        if not stripped or stripped.startswith("["):
            brace_depth += brace_delta(line)
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
            visibility = normalize_visibility(type_match.group("mods") or "", "internal")
            key = (kind, name, type_stack[-1][1] if type_stack else None)
            if key not in seen:
                seen.add(key)
                symbols.append(
                    symbol_record(
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
            brace_depth += brace_delta(line)
            continue

        container = type_stack[-1][1] if type_stack else None
        if container:
            constructor_match = constructor_pattern.search(line)
            if constructor_match and constructor_match.group("name") == container:
                visibility = normalize_visibility(constructor_match.group("mods") or "", "private")
                key = ("constructor", container, container)
                if key not in seen:
                    seen.add(key)
                    symbols.append(
                        symbol_record(
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
                brace_depth += brace_delta(line)
                continue

            property_match = property_pattern.search(line)
            if property_match:
                name = property_match.group("name")
                visibility = normalize_visibility(property_match.group("mods") or "", "private")
                key = ("property", name, container)
                if key not in seen:
                    seen.add(key)
                    symbols.append(
                        symbol_record(
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
                brace_depth += brace_delta(line)
                continue

            method_match = method_pattern.search(line)
            if method_match and method_match.group("name") not in control_words:
                name = method_match.group("name")
                visibility = normalize_visibility(method_match.group("mods") or "", "private")
                key = ("method", name, container)
                if key not in seen:
                    seen.add(key)
                    symbols.append(
                        symbol_record(
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
                brace_depth += brace_delta(line)
                continue

            if "(" not in line and not stripped.startswith(("return ", "throw ")):
                field_match = field_pattern.search(line)
                if field_match:
                    name = field_match.group("name")
                    mods = field_match.group("mods") or ""
                    visibility = normalize_visibility(mods, "private")
                    kind = "constant" if re.search(r"\bconst\b", mods) else "field"
                    key = (kind, name, container)
                    if key not in seen:
                        seen.add(key)
                        symbols.append(
                            symbol_record(
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

        brace_depth += brace_delta(line)
        while type_stack and brace_depth < type_stack[-1][0]:
            type_stack.pop()
    return symbols


def extract_import_records(text: str) -> list[dict[str, Any]]:
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


def normalize_project_include(base_dir: str, include: str) -> str:
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
                    project_references.append(normalize_project_include(base_dir, include))
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
        or any(TEST_PACKAGE_FRAMEWORKS.get(package) for package in lower_packages)
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
        package for package in lower_packages if package in TEST_PACKAGE_FRAMEWORKS
    )
    if test_packages:
        manifest["testPackageHints"] = [
            {"package": package, "framework": TEST_PACKAGE_FRAMEWORKS[package]}
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


def extract_manifest(rel: str, text: str, kind: str) -> dict[str, Any] | None:
    if kind == "dotnet-solution":
        projects = parse_sln_projects(text)
        manifest: dict[str, Any] = {
            "path": rel,
            "kind": kind,
            "language": "csharp",
            "tokens": tokens_for_path(rel),
        }
        if projects:
            manifest["projects"] = projects
            project_tokens = {token for project in projects for token in split_identifier(" ".join(project.values()))}
            manifest["tokens"] = sorted(set(manifest["tokens"]) | project_tokens)
        return manifest
    if kind == "dotnet-project":
        return parse_dotnet_project(rel, text)
    if kind in {"dotnet-props", "dotnet-targets"}:
        return parse_dotnet_props_targets(rel, text, kind)
    return None


def build_context(manifests: list[dict[str, Any]], known_files: set[str]) -> dict[str, Any]:
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


def project_for_path(rel: str, csharp_context: dict[str, Any]) -> dict[str, Any] | None:
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


def transitive_project_references(project: dict[str, Any], csharp_context: dict[str, Any]) -> list[dict[str, Any]]:
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


def namespace_matches(imported: str, project: dict[str, Any]) -> bool:
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


def resolve_import(
    source_rel: str,
    imported: str,
    csharp_context: dict[str, Any],
) -> str | None:
    if not imported:
        return None
    source_project = project_for_path(source_rel, csharp_context)
    candidates: list[dict[str, Any]] = []
    if source_project:
        candidates.append(source_project)
        candidates.extend(transitive_project_references(source_project, csharp_context))
    else:
        projects = csharp_context.get("projects")
        if isinstance(projects, list):
            candidates.extend(project for project in projects if isinstance(project, dict))

    for project in candidates:
        if not namespace_matches(imported, project):
            continue
        root = str(project.get("root") or "")
        return root or "."

    if imported.startswith(EXTERNAL_NAMESPACE_PREFIXES):
        return None
    return None


def test_framework_for_text(rel: str, text: str) -> str | None:
    if re.search(r"\[(?:Fact|Theory)\b", text):
        return "xunit"
    if re.search(r"\[(?:Test|TestCase|TestFixture)\b", text):
        return "nunit"
    if re.search(r"\[(?:TestMethod|TestClass)\b", text):
        return "mstest"
    if is_test_path(rel):
        return "dotnet-test"
    return None


def test_info(
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
            framework = TEST_PACKAGE_FRAMEWORKS.get(str(package).lower())
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


def module_fields(
    rel: str,
    text: str,
    csharp_context: dict[str, Any],
    manifest: dict[str, Any] | None = None,
) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    hints: list[dict[str, Any]] = []
    project = project_for_path(rel, csharp_context)
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


def build_project_modules(
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
            project = project_for_path(path, csharp_context)
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
            project = project_for_path(path, csharp_context)
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


def update_module_boundaries(
    modules: list[dict[str, Any]],
    symbols_by_path: dict[str, list[dict[str, Any]]],
) -> None:
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
