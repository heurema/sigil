"""Rust adapter for the shallow codebase awareness scanner."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from scripts.codebase_awareness.adapters.common import (
    is_test_path,
    normalize_rel_parts,
    split_identifier,
    tokens_for_path,
)

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11 fallback
    tomllib = None


def manifest_kinds() -> dict[str, str]:
    return {
        "Cargo.lock": "cargo-lock",
        "Cargo.toml": "cargo",
    }


def language_for_manifest(kind: str) -> str | None:
    if kind in {"cargo", "cargo-lock"}:
        return "toml"
    return None


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


def normalize_visibility(raw: str | None) -> str:
    if not raw:
        return "private"
    compact = re.sub(r"\s+", " ", raw.strip())
    compact = compact.replace("pub (", "pub(")
    compact = re.sub(r"\(\s+", "(", compact)
    compact = re.sub(r"\s+\)", ")", compact)
    return compact


def visibility_exported(visibility: str) -> bool:
    return visibility == "pub"


def line_without_comment(line: str) -> str:
    return line.split("//", 1)[0]


def brace_delta(line: str) -> int:
    stripped = line_without_comment(line)
    return stripped.count("{") - stripped.count("}")


def impl_type(line: str) -> str | None:
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


def symbol_record(
    *,
    rel: str,
    line_number: int,
    kind: str,
    name: str,
    visibility: str,
    impl_type_name: str | None = None,
    test_only: bool = False,
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "language": "rust",
        "path": rel,
        "line": line_number,
        "exported": visibility_exported(visibility),
        "visibility": visibility,
        "tokens": sorted(set(split_identifier(name))),
    }
    if impl_type_name:
        record["implType"] = impl_type_name
        record["tokens"] = sorted(set(record["tokens"]) | set(split_identifier(impl_type_name)))
    if test_only:
        record["testOnly"] = True
    return record


def extract_symbols(rel: str, text: str) -> list[dict[str, Any]]:
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
            brace_depth += brace_delta(line)
            continue

        if test_attr_re.search(line):
            pending_test_attr = True
            brace_depth += brace_delta(line)
            continue

        cfg_test_item = pending_cfg_test
        pending_cfg_test = False
        test_mod_line = bool(cfg_test_item and re.search(r"^\s*(?:pub\s+)?mod\s+[A-Za-z_][\w]*\s*\{", line))
        if test_mod_line:
            test_module_stack.append(brace_depth + 1)
        test_attr_item = pending_test_attr
        pending_test_attr = False
        in_test_module = bool(test_module_stack) or cfg_test_item or test_attr_item

        current_impl_type = impl_type(line)
        if current_impl_type and not in_test_module:
            impl_stack.append((brace_depth + 1, current_impl_type))
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
                visibility = normalize_visibility(match.groupdict().get("vis"))
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
                    symbol_record(
                        rel=rel,
                        line_number=line_number,
                        kind=kind,
                        name=name,
                        visibility=visibility,
                        impl_type_name=active_impl if kind == "method" else None,
                    )
                )
                break

        brace_depth += brace_delta(line)
        while impl_stack and brace_depth < impl_stack[-1][0]:
            impl_stack.pop()
        while test_module_stack and brace_depth < test_module_stack[-1]:
            test_module_stack.pop()
    return symbols


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


def clean_use_spec(spec: str) -> str:
    spec = re.sub(r"\s+as\s+[A-Za-z_][\w]*$", "", spec.strip())
    spec = spec.strip(":")
    spec = re.sub(r"\s+", "", spec)
    return spec


def expand_use_tree(value: str) -> list[str]:
    value = value.strip()
    brace_index = value.find("{")
    if brace_index == -1:
        cleaned = clean_use_spec(value)
        return [cleaned] if cleaned else []
    end = find_matching_brace(value, brace_index)
    if end is None:
        cleaned = clean_use_spec(value)
        return [cleaned] if cleaned else []

    prefix = value[:brace_index]
    suffix = value[end + 1 :]
    inner = value[brace_index + 1 : end]
    expanded: list[str] = []
    for item in split_top_level_commas(inner):
        for child in expand_use_tree(item):
            if child == "self":
                combined = prefix.rstrip(":")
            elif prefix.endswith("::"):
                combined = f"{prefix}{child}"
            elif prefix:
                combined = f"{prefix}::{child}"
            else:
                combined = child
            combined = clean_use_spec(f"{combined}{suffix}")
            if combined:
                expanded.append(combined)
    return sorted(set(expanded))


def extract_import_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    use_pattern = re.compile(r"^\s*(?P<vis>pub(?:\s*\([^)]*\))?)?\s*use\s+(?P<body>[^;]+);")
    mod_pattern = re.compile(r"^\s*(?P<vis>pub(?:\s*\([^)]*\))?)?\s*mod\s+(?P<name>[A-Za-z_][\w]*)\s*(?:;|\{)")
    seen: set[tuple[str, str, int]] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        use_match = use_pattern.search(line)
        if use_match:
            visibility = normalize_visibility(use_match.group("vis"))
            kind = "pub use" if visibility == "pub" else "use"
            for spec in expand_use_tree(use_match.group("body")):
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
            visibility = normalize_visibility(mod_match.group("vis"))
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


def extract_manifest(rel: str, text: str, kind: str) -> dict[str, Any] | None:
    if kind not in {"cargo", "cargo-lock"}:
        return None
    path = Path(rel)
    manifest: dict[str, Any] = {
        "path": rel,
        "kind": kind,
        "language": "toml",
        "tokens": tokens_for_path(rel),
    }
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
    return manifest


def crate_name_for_package(package_name: str) -> str:
    return package_name.replace("-", "_")


def build_context(manifests: list[dict[str, Any]], known_files: set[str]) -> dict[str, Any]:
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
            "crateName": crate_name_for_package(package_name) if package_name else "",
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


def src_root(crate: dict[str, Any] | None) -> str:
    if not crate:
        return "src"
    root = str(crate.get("root") or "")
    return f"{root}/src" if root else "src"


def crate_for_path(rel: str, rust_context: dict[str, Any]) -> dict[str, Any] | None:
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


def module_path_candidates(base_dir: str, module_parts: list[str]) -> list[str]:
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


def resolve_import(
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
    crate = crate_for_path(source_rel, rust_context)
    crate_by_name = rust_context.get("crateByName")
    if not isinstance(crate_by_name, dict):
        crate_by_name = {}

    first = parts[0]
    rest = parts[1:]
    if first == "crate":
        base = src_root(crate)
        module_parts = rest
    elif first == "self":
        base = Path(source_rel).parent.as_posix()
        module_parts = rest
    elif first == "super":
        base = Path(source_rel).parent.parent.as_posix()
        module_parts = rest
    elif first in crate_by_name:
        target = crate_by_name[first]
        base = src_root(target if isinstance(target, dict) else None)
        module_parts = rest
    elif crate:
        base = src_root(crate)
        module_parts = parts
    else:
        return None

    for candidate in module_path_candidates(base, module_parts):
        if candidate in known_files:
            return candidate
    return None


def test_info(rel: str, text: str, language: str | None) -> dict[str, Any]:
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


def test_framework(text: str) -> str:
    if "#[tokio::test]" in text:
        return "tokio-test"
    if "#[async_std::test]" in text:
        return "async-std-test"
    return "rust-test"


def module_role(rel: str, crate: dict[str, Any] | None) -> str | None:
    if not crate:
        if rel.startswith("crates/"):
            return "crates-directory"
        if Path(rel).parts and "tests" in Path(rel).parts:
            return "integration-test"
        return None
    root = src_root(crate)
    if rel == f"{root}/lib.rs":
        return "library-crate-root"
    if rel == f"{root}/main.rs":
        return "binary-crate-root"
    if Path(rel).parts and "tests" in Path(rel).parts:
        return "integration-test"
    if Path(rel).name == "mod.rs":
        return "module-root"
    return None


def module_fields(rel: str, text: str, rust_context: dict[str, Any]) -> dict[str, Any]:
    crate = crate_for_path(rel, rust_context)
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
    role = module_role(rel, crate)
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


def update_module_boundaries(
    modules: list[dict[str, Any]],
    symbols_by_path: dict[str, list[dict[str, Any]]],
) -> None:
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
