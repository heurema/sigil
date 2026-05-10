"""Bash/Shell adapter for the shallow codebase awareness scanner."""

from __future__ import annotations

import re
import shlex
from pathlib import Path
from typing import Any

from scripts.codebase_awareness.adapters.common import (
    normalize_rel_parts,
    split_identifier,
    tokens_for_path,
)

SOURCE_EXTENSIONS = (".sh", ".bash", ".zsh", ".bats")
SHELL_NAMES = {"bash", "sh", "zsh"}
SHARED_DIR_HINTS = {"common", "lib", "shared", "utils"}

SHELL_SHEBANG_RE = re.compile(
    r"^#!\s*(?:/usr/bin/env\s+(?:bash|sh)|/bin/(?:bash|sh))(?:\s|$)"
)
FUNCTION_PATTERNS = (
    re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*\(\s*\)\s*(?:\{|$)"),
    re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\s*(?:\{|$)"),
)
SOURCE_RE = re.compile(r"^\s*(source|\.)\s+(.+)$")
BASH_TEST_RE = re.compile(r"^\s*@test\s+(['\"])(.+?)\1", re.MULTILINE)
JSON_PRINT_RE = re.compile(r"\b(?:printf|echo|cat)\b[^\n]*(?:\{|\[|json)", re.IGNORECASE)
PYTHON_JSON_RE = re.compile(r"\bpython3?\s+-\s+<<['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?.*?\bjson\.loads\b", re.DOTALL)
GITHUB_ANNOTATION_RE = re.compile(r"::(warning|error|notice)\b")
HEREDOC_RE = re.compile(r"<<-?\s*['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?")


def manifest_kinds() -> dict[str, str]:
    return {}


def language_for_manifest(kind: str) -> str | None:
    return None


def language_for_source(rel: str) -> str | None:
    return "shell" if Path(rel).suffix in SOURCE_EXTENSIONS else None


def has_shell_shebang(text: str) -> bool:
    first_line = text.splitlines()[0] if text.splitlines() else ""
    return bool(SHELL_SHEBANG_RE.search(first_line))


def language_for_text(rel: str, text: str) -> str | None:
    return "shell" if language_for_source(rel) == "shell" or has_shell_shebang(text) else None


def is_command_fragment_path(rel: str) -> bool:
    path = Path(rel)
    return (
        path.suffix == ".md"
        and len(path.parts) >= 2
        and path.parts[0] == "commands"
        and (path.parts[1] == "signum.fragments" or path.name.endswith(".md"))
    )


def is_shell_config_path(rel: str) -> bool:
    name = Path(rel).name
    return name in {".env.example", ".env.sample", ".bashrc", ".bash_profile", ".zshrc", ".profile"}


def strip_comment(line: str) -> str:
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
        if char in {"'", "\""}:
            quote = char
            continue
        if char == "#":
            return line[:index]
    return line


def shell_words(value: str) -> list[str]:
    try:
        return shlex.split(value, comments=True, posix=True)
    except ValueError:
        match = re.match(r"\s*(?:['\"]([^'\"]+)['\"]|(\S+))", value)
        if not match:
            return []
        return [match.group(1) or match.group(2) or ""]


def first_arg(value: str) -> str | None:
    words = shell_words(value)
    return words[0] if words else None


def token_list(*values: str) -> list[str]:
    tokens: set[str] = set()
    for value in values:
        tokens.update(split_identifier(value))
    return sorted(tokens)


def symbol_entry(*, rel: str, line_number: int, name: str) -> dict[str, Any]:
    return {
        "name": name,
        "kind": "function",
        "language": "shell",
        "path": rel,
        "line": line_number,
        "exported": True,
        "visibility": "function",
        "tokens": token_list(name),
    }


def extract_symbols(rel: str, text: str) -> list[dict[str, Any]]:
    symbols: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        candidate = strip_comment(line)
        for pattern in FUNCTION_PATTERNS:
            match = pattern.search(candidate)
            if not match:
                continue
            name = match.group(1)
            if name in {"case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "then", "while"}:
                continue
            if name in seen:
                continue
            seen.add(name)
            symbols.append(symbol_entry(rel=rel, line_number=line_number, name=name))
            break
    return symbols


def import_record(*, imported: str, kind: str, line_number: int, original: str | None = None) -> dict[str, Any]:
    record = {
        "imported": imported,
        "kind": kind,
        "line": line_number,
        "tokens": token_list(imported, original or ""),
    }
    if original and original != imported:
        record["original"] = original
    return record


def extract_source_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = strip_comment(line).strip()
        match = SOURCE_RE.match(stripped)
        if not match:
            continue
        arg = first_arg(match.group(2))
        if not arg:
            continue
        records.append(import_record(imported=arg, kind="source", line_number=line_number))
    return records


def shell_call_target(words: list[str]) -> str | None:
    if not words:
        return None
    command = Path(words[0]).name
    if command not in SHELL_NAMES:
        return None
    skip_next = False
    for word in words[1:]:
        if skip_next:
            skip_next = False
            continue
        if word == "-c":
            return None
        if word in {"-o", "--rcfile"}:
            skip_next = True
            continue
        if word.startswith("-"):
            continue
        if looks_like_local_shell_target(word):
            return word
        return None
    return None


def looks_like_local_shell_target(value: str) -> bool:
    if value.startswith(("$", "http://", "https://")):
        return False
    path = Path(value)
    return (
        path.suffix in SOURCE_EXTENSIONS
        or value.startswith(("./", "../", "lib/", "scripts/", "tests/"))
    )


def extract_shell_call_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        words = shell_words(strip_comment(line))
        target = shell_call_target(words)
        if target:
            records.append(import_record(imported=target, kind="shell-call", line_number=line_number))
    return records


def unique_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    unique: dict[tuple[str, str, int], dict[str, Any]] = {}
    for record in records:
        key = (str(record.get("kind")), str(record.get("imported")), int(record.get("line") or 0))
        unique[key] = record
    return [unique[key] for key in sorted(unique)]


def extract_import_records(rel: str, text: str) -> list[dict[str, Any]]:
    records = extract_source_records(text)
    records.extend(extract_shell_call_records(text))
    return unique_records(records)


def extract_command_fragment_import_records(rel: str, text: str) -> list[dict[str, Any]]:
    if not is_command_fragment_path(rel):
        return []
    return unique_records(extract_shell_call_records(text))


def candidate_paths_for_spec(source_rel: str, spec: str) -> list[str]:
    value = spec.strip().strip("\"'")
    value = re.sub(r"^\$\{?ROOT_DIR\}?/", "", value)
    value = re.sub(r"^\$\{?REPO_ROOT\}?/", "", value)
    value = re.sub(r"^\$\{?PROJECT_ROOT\}?/", "", value)

    dirname_match = re.match(
        r"^\$\(dirname\s+(?:--\s+)?['\"]?(?:\$0|\$\{BASH_SOURCE\[0\]\})['\"]?\)/(.*)$",
        value,
    )
    if dirname_match:
        value = (Path(source_rel).parent / dirname_match.group(1)).as_posix()
    elif value.startswith(("./", "../")):
        value = (Path(source_rel).parent / value).as_posix()

    if value.startswith("/") or value.startswith("$("):
        return []

    normalized = normalize_rel_parts(value)
    candidates = [normalized]
    if not Path(normalized).suffix:
        candidates.extend(f"{normalized}{suffix}" for suffix in SOURCE_EXTENSIONS)
    return [candidate for candidate in candidates if candidate]


def resolve_import(source_rel: str, spec: str, known_files: set[str]) -> str | None:
    for candidate in candidate_paths_for_spec(source_rel, spec):
        if candidate in known_files:
            return candidate
    return None


def approximate_target_path(source_rel: str, spec: str) -> str | None:
    candidates = candidate_paths_for_spec(source_rel, spec)
    return candidates[0] if candidates else None


def shell_exit_codes(text: str) -> list[int]:
    codes = {
        int(match.group(1))
        for match in re.finditer(r"(?m)^\s*exit\s+([0-9]{1,3})\b", text)
    }
    return sorted(codes)


def file_text_signals(rel: str, text: str, language: str | None) -> dict[str, Any]:
    tokens = set(tokens_for_path(rel))
    symbols = extract_symbols(rel, text) if language == "shell" else []
    symbol_tokens = {token for symbol in symbols for token in symbol.get("tokens", [])}
    tokens.update(symbol_tokens)
    exit_codes = shell_exit_codes(text)
    annotations = sorted(set(GITHUB_ANNOTATION_RE.findall(text)))
    uses_jq = bool(re.search(r"(?<![\w/-])jq(?![\w/-])", text))
    python_json_validation = bool(PYTHON_JSON_RE.search(text))
    has_printf = bool(re.search(r"(?m)^\s*printf\b", text))
    has_heredoc = bool(HEREDOC_RE.search(text))
    json_output = bool(
        JSON_PRINT_RE.search(text)
        or (("json" in tokens or ".json" in text) and (has_printf or has_heredoc))
    )
    json_validation = bool(uses_jq or python_json_validation)
    strict_mode = bool(re.search(r"(?m)^\s*set\s+-(?:[A-Za-z]*e[A-Za-z]*u[A-Za-z]*|euo)\s+pipefail\b", text))
    trap_exit = bool(re.search(r"(?m)^\s*trap\b[^\n]*\bEXIT\b", text))
    mktemp_dir = bool(re.search(r"\bmktemp\s+-d\b", text))

    return {
        "tokens": sorted(tokens),
        "shellShebang": has_shell_shebang(text),
        "shellStrictMode": strict_mode,
        "shellTrapExit": trap_exit,
        "shellMktempDir": mktemp_dir,
        "shellTempdirTrapCleanup": bool(trap_exit and mktemp_dir),
        "shellUsesJq": uses_jq,
        "shellPythonJsonValidation": python_json_validation,
        "shellPrintf": has_printf,
        "shellHeredoc": has_heredoc,
        "shellExitCodes": exit_codes,
        "shellExit78": 78 in exit_codes,
        "shellGithubAnnotations": annotations,
        "shellCiAnnotationPattern": bool(annotations),
        "shellJsonOutputPattern": json_output,
        "shellJsonValidationPattern": json_validation,
        "shellConfigPattern": is_shell_config_path(rel),
        "shellCommandFragment": is_command_fragment_path(rel),
    }


def is_shell_test_path(rel: str) -> bool:
    path = Path(rel)
    name = path.name
    parts = set(path.parts)
    return (
        path.suffix == ".bats"
        or "tests" in parts
        or "test" in parts
        or (name.startswith("test-") and path.suffix in SOURCE_EXTENSIONS)
        or (name.startswith("test_") and path.suffix in SOURCE_EXTENSIONS)
    )


def test_info(rel: str, text: str, language: str | None) -> dict[str, Any]:
    symbols = extract_symbols(rel, text)
    test_functions = [
        str(symbol.get("name"))
        for symbol in symbols
        if str(symbol.get("name") or "").startswith(("assert_", "test_"))
        or str(symbol.get("name") or "") in {"fail", "pass"}
    ]
    bats_tests = BASH_TEST_RE.findall(text)
    for _quote, name in bats_tests:
        test_functions.append(name)
    import_records = extract_import_records(rel, text)
    target_paths = sorted(
        {
            target
            for record in import_records
            if (target := approximate_target_path(rel, str(record.get("imported") or "")))
        }
    )
    has_assertions = bool(re.search(r"\b(assert_[A-Za-z0-9_]*|pass|fail)\b", text))
    path_marks_test = is_shell_test_path(rel)
    has_tests = bool(path_marks_test or bats_tests or test_functions or has_assertions)
    framework = "bats" if Path(rel).suffix == ".bats" or bats_tests else ("shell-test" if has_tests else None)
    info: dict[str, Any] = {
        "hasTests": has_tests,
        "framework": framework,
        "testFunctions": sorted(set(test_functions)),
    }
    if target_paths:
        info["targetPaths"] = target_paths
    fixtures = sorted(
        {
            normalize_rel_parts(match.group(0))
            for match in re.finditer(r"(?:tests/fixtures|fixtures)/[A-Za-z0-9_./-]+", text)
        }
    )
    if fixtures:
        info["fixtures"] = fixtures
    return info


def boundary_hints_for_path(rel: str, signals: dict[str, Any], test_info_value: dict[str, Any]) -> list[dict[str, Any]]:
    path = Path(rel)
    hints: list[dict[str, Any]] = []
    if path.suffix in SOURCE_EXTENSIONS and path.parts and path.parts[0] == "lib":
        hints.append(
            {
                "path": rel,
                "kind": "shell-lib-helper",
                "value": "lib/*.sh reusable shell helper boundary",
                "weak": True,
            }
        )
    if signals.get("shellCommandFragment") or is_command_fragment_path(rel):
        hints.append(
            {
                "path": rel,
                "kind": "shell-command-fragment",
                "value": "command fragment orchestrator boundary",
                "risk": "Command fragments guide orchestration patterns, not reusable shell helper placement.",
            }
        )
    if test_info_value.get("hasTests"):
        hints.append(
            {
                "path": rel,
                "kind": "shell-test-file",
                "value": "shell test file",
                "risk": "Shell test files should guide tests, not production helper placement.",
            }
        )
    if path.parts and path.parts[0] == "scripts":
        hints.append(
            {
                "path": rel,
                "kind": "shell-executable-script",
                "value": "shell script or CLI entrypoint boundary",
                "risk": "Executable shell scripts are not generic helpers unless sourced or reused by local files.",
            }
        )
    if set(path.parts) & SHARED_DIR_HINTS:
        hints.append(
            {
                "path": rel,
                "kind": "shared-name-weak",
                "value": "shared/common/utils/lib path name is weak evidence only",
                "weak": True,
            }
        )
    signal_hints = (
        ("shellStrictMode", "shell-strict-mode", "set -euo pipefail safety convention"),
        ("shellTempdirTrapCleanup", "shell-tempdir-trap-cleanup", "tempdir/trap cleanup convention"),
        ("shellJsonOutputPattern", "shell-json-output", "JSON-emitting checker pattern"),
        ("shellJsonValidationPattern", "shell-json-validation", "JSON validation convention"),
        ("shellCiAnnotationPattern", "shell-ci-annotation", "GitHub Actions annotation emitter pattern"),
        ("shellExit78", "shell-exit-78", "exit 78 human-review/neutral CI convention"),
        ("shellUsesJq", "shell-jq-convention", "jq JSON validation/emission convention"),
    )
    for signal_key, kind, value in signal_hints:
        if signals.get(signal_key):
            hints.append({"path": rel, "kind": kind, "value": value})
    return hints


def module_fields(rel: str, signals: dict[str, Any], test_info_value: dict[str, Any]) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    hints = boundary_hints_for_path(rel, signals, test_info_value)
    if hints:
        fields["boundaryHints"] = hints
        fields["boundaryKinds"] = sorted(str(hint.get("kind")) for hint in hints)
    for key in (
        "shellShebang",
        "shellStrictMode",
        "shellTrapExit",
        "shellMktempDir",
        "shellTempdirTrapCleanup",
        "shellUsesJq",
        "shellExit78",
        "shellJsonOutputPattern",
        "shellJsonValidationPattern",
        "shellCiAnnotationPattern",
    ):
        if signals.get(key):
            fields[key] = signals.get(key)
    if signals.get("shellGithubAnnotations"):
        fields["shellGithubAnnotations"] = signals.get("shellGithubAnnotations")
    if Path(rel).parts and Path(rel).parts[0] == "scripts":
        fields["executableBoundary"] = True
    if signals.get("shellCommandFragment"):
        fields["orchestratorFragment"] = True
    return fields


def sourced_helper_hint(rel: str) -> dict[str, Any]:
    return {
        "path": rel,
        "kind": "shell-sourced-helper",
        "value": "sourced helper boundary",
    }
