#!/usr/bin/env python3
"""init_scanner.py -- deterministic signal extraction for /signum init.

Compatibility implementation for the historical lib/init-scanner.sh output.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

IGNORE_DIRS = [
    ".git",
    ".signum",
    "node_modules",
    "dist",
    "build",
    ".venv",
    "__pycache__",
    "coverage",
    "tests/fixtures",
]


def parse_args(argv: list[str]) -> Path:
    project_root = "."
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--project-root":
            if index + 1 >= len(argv):
                print("Unknown argument: --project-root", file=sys.stderr)
                raise SystemExit(1)
            project_root = argv[index + 1]
            index += 2
            continue
        print(f"Unknown argument: {arg}", file=sys.stderr)
        raise SystemExit(1)
    return Path(project_root)


def is_ignored(path: str) -> bool:
    for ignored in IGNORE_DIRS:
        if path == ignored or path.startswith(f"{ignored}/"):
            return True
    return False


def safe_head(root: Path, rel: str, lines: int = 200) -> str:
    path = root / rel
    if not path.is_file():
        return ""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            out: list[str] = []
            for index, line in enumerate(handle):
                if index >= lines:
                    break
                out.append(line)
        return "".join(out).rstrip("\n")
    except OSError:
        return ""


def append_section(current: str, rel: str, content: str) -> str:
    return f"{current}\n=== {rel} ===\n{content}\n"


def shell_glob_files(root: Path, pattern: str) -> list[Path]:
    # Bash leaves unmatched globs literal, then [ -f ] skips them. Path.glob with
    # no matches is equivalent for this scanner.
    return [path for path in root.glob(pattern) if path.is_file()]


def find_docs_markdown(root: Path) -> list[Path]:
    docs_root = root / "docs"
    if not docs_root.is_dir():
        return []
    results: list[Path] = []
    try:
        for dirpath, dirnames, filenames in os.walk(docs_root):
            # Keep os.walk filesystem ordering to match the shell find behavior;
            # tests normalize docs_deep ordering instead of changing semantics.
            dirnames[:] = [d for d in dirnames if True]
            for filename in filenames:
                if not filename.endswith(".md"):
                    continue
                if filename == "how-it-works.md":
                    continue
                path = Path(dirpath) / filename
                rel = path.relative_to(root).as_posix()
                if is_ignored(rel):
                    continue
                results.append(path)
                if len(results) >= 30:
                    return results
    except OSError:
        return results
    return results


def grep_after(lines: list[str], pattern: re.Pattern[str], after: int) -> str:
    out: list[str] = []
    for index, line in enumerate(lines):
        if pattern.search(line):
            out.extend(lines[index : min(len(lines), index + after + 1)])
    return "\n".join(out)


def read_lines(root: Path, rel: str) -> list[str]:
    path = root / rel
    if not path.is_file():
        return []
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def grep_block(root: Path, rel: str, pattern: str, after: int, flags: int = re.IGNORECASE) -> str:
    return grep_after(read_lines(root, rel), re.compile(pattern, flags), after)


def first_grep_line(lines: list[str], pattern: str, flags: int = re.IGNORECASE) -> str:
    rx = re.compile(pattern, flags)
    for line in lines:
        if rx.search(line):
            return line
    return ""


def first_heading_title(lines: list[str], fallback: str) -> str:
    for line in lines:
        if line.startswith("#"):
            # Historical sed expression used \s literally under basic sed on macOS,
            # so preserve the leading space after '#'.
            return re.sub(r"^#", "", line)
    return fallback


def grep_matching_lines(lines: list[str], pattern: str, flags: int = re.IGNORECASE, limit: int | None = None) -> list[str]:
    rx = re.compile(pattern, flags)
    out = [line for line in lines if rx.search(line)]
    if limit is not None:
        return out[:limit]
    return out


def run_git(root: Path, args: list[str]) -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout.rstrip("\n")


def in_git_repo(root: Path) -> bool:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--git-dir"],
            cwd=root,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return False
    return completed.returncode == 0


def compute_git_dirstat(root: Path) -> str:
    raw = run_git(root, ["log", "--dirstat=files", "--since=6 months ago", "--format=", "--", "."])
    if not raw:
        return ""
    lines = [line for line in raw.splitlines() if line.strip()]
    decorated = []
    for line in lines:
        parts = line.split()
        if not parts:
            continue
        # Preserve the historical shell pipeline:
        # awk '{print $NF, $0}' | sort -rn | awk '{$1=""; print $0}'
        decorated.append(f"{parts[-1]} {line}")
    decorated.sort(reverse=True)
    output = []
    for line in decorated[:50]:
        parts = line.split()
        if len(parts) > 1:
            output.append(" " + " ".join(parts[1:]))
    return "\n".join(output)


def compute_package_bin(root: Path) -> str:
    path = root / "package.json"
    if not path.is_file():
        return ""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return ""
    bin_value = data.get("bin", {})
    if isinstance(bin_value, str):
        return "bin: " + bin_value
    if isinstance(bin_value, dict):
        return "\n".join(f"{key}: {value}" for key, value in bin_value.items())
    return ""


def compute_console_scripts(root: Path) -> str:
    lines = read_lines(root, "pyproject.toml")
    if not lines:
        return ""
    for header in (r"\[project\.scripts\]", r"\[tool\.poetry\.scripts\]"):
        out = grep_after(lines, re.compile(header), 20)
        if out:
            return out
    return ""


def compute_entrypoints(root: Path) -> str:
    entrypoints = ""
    for ep_dir in ("bin", "commands", "skills"):
        path = root / ep_dir
        if not path.is_dir():
            continue
        entries: list[str] = []
        try:
            for candidate in path.rglob("*"):
                if not candidate.is_file():
                    continue
                rel = candidate.relative_to(root).as_posix()
                if "__pycache__" in rel:
                    continue
                # Historical find -maxdepth 2 includes files directly in the dir
                # and one level below it.
                if len(Path(rel).parts) <= 2:
                    entries.append(rel)
        except OSError:
            entries = []
        entries.sort()
        if entries:
            entrypoints = append_section(entrypoints, f"{ep_dir}/", "\n".join(entries))
    return entrypoints


def compute_adr_signals(root: Path) -> str:
    adr_root = root / "docs" / "adr"
    if not adr_root.is_dir():
        return ""
    out = ""
    for adr in [*adr_root.glob("*.md"), *adr_root.glob("*.rst")]:
        if not adr.is_file():
            continue
        rel = adr.relative_to(root).as_posix()
        lines = read_lines(root, rel)
        status_line = first_grep_line(lines, r"^status:")
        if not re.search(r"(rejected|deprecated|superseded|declined|won.t)", status_line, re.IGNORECASE):
            continue
        title = first_heading_title(lines, adr.name)
        detail = "\n".join(grep_matching_lines(lines, r"context|decision|consequences", limit=5))
        out = f"{out}\nREJECTED ADR: {title} ({rel})\n{status_line}\n{detail}\n"
    return out


def compute_ci_signals(root: Path) -> str:
    out = ""
    workflows = root / ".github" / "workflows"
    if workflows.is_dir():
        for pattern in ("*.yml", "*.yaml"):
            for wf in workflows.glob(pattern):
                if wf.is_file():
                    rel = wf.relative_to(root).as_posix()
                    out = append_section(out, rel, safe_head(root, rel, 50))
    for runner in ("Makefile", "justfile", "Taskfile.yml", "tox.ini"):
        if (root / runner).is_file():
            out = append_section(out, runner, safe_head(root, runner, 60))
    return out


def compute_module_dirs(root: Path) -> str:
    module_dirs = ""
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return ""
    for name in names:
        path = root / name
        if not path.is_dir():
            continue
        if is_ignored(name):
            continue
        if name == "tests":
            continue
        if name in (".", ".."):
            continue
        module_dirs += f" {name}"
    return module_dirs


def scan(root: Path) -> dict[str, object]:
    authoritative_docs = ""
    for candidate in ("docs/how-it-works.md", "ARCHITECTURE.md", "docs/architecture.md", "docs/reference.md", "docs/design.md"):
        if (root / candidate).is_file():
            authoritative_docs = append_section(authoritative_docs, candidate, safe_head(root, candidate, 300))

    docs_deep = ""
    for path in find_docs_markdown(root):
        rel = path.relative_to(root).as_posix()
        docs_deep = append_section(docs_deep, rel, safe_head(root, rel, 100))

    readme = ""
    for candidate in ("README.md", "README.rst", "README.txt", "README"):
        if (root / candidate).is_file():
            readme = safe_head(root, candidate, 150)
            break

    git_dirstat = ""
    git_recent = ""
    if in_git_repo(root):
        git_dirstat = compute_git_dirstat(root)
        git_recent = run_git(root, ["log", "--oneline", "--since=6 months ago"])
        if git_recent:
            git_recent = "\n".join(git_recent.splitlines()[:30])

    existing_glossary = ""
    glossary_file = ""
    for rel in ("project.glossary.json", ".signum/project.glossary.json"):
        path = root / rel
        if path.is_file():
            try:
                existing_glossary = path.read_text(encoding="utf-8", errors="replace").rstrip("\n")
            except OSError:
                existing_glossary = ""
            glossary_file = rel
            break

    existing_intent = ""
    intent_file = ""
    for rel in ("project.intent.md", ".signum/project.intent.md"):
        path = root / rel
        if path.is_file():
            try:
                existing_intent = path.read_text(encoding="utf-8", errors="replace").rstrip("\n")
            except OSError:
                existing_intent = ""
            intent_file = rel
            break

    return {
        "schemaVersion": "1.0",
        "scanTarget": str(root),
        "signals": {
            "authoritative_docs": authoritative_docs,
            "docs_deep": docs_deep,
            "claude_md": safe_head(root, "CLAUDE.md", 300),
            "agents_md": safe_head(root, "AGENTS.md", 300),
            "readme": readme,
            "package_json": safe_head(root, "package.json", 100),
            "pyproject_toml": safe_head(root, "pyproject.toml", 100),
            "cargo_toml": safe_head(root, "Cargo.toml", 50),
            "go_mod": safe_head(root, "go.mod", 50),
            "ci_signals": compute_ci_signals(root),
            "entrypoints": compute_entrypoints(root),
            "console_scripts": compute_console_scripts(root),
            "pkg_bin": compute_package_bin(root),
            "git_dirstat": git_dirstat,
            "git_recent": git_recent,
            "adr_signals": compute_adr_signals(root),
            "readme_negative": grep_block(root, "README.md", r"^#{1,3}\s+(not supported|out of scope|limitations|non.?goals?|won.t support|excluded)", 5),
            "claude_negative": "\n".join(grep_matching_lines(read_lines(root, "CLAUDE.md"), r"^-\s.*(not|never|don.t|avoid|excluded|out.of.scope|prohibited)|^##\s+(non.?goals?|excluded|out.of.scope)", limit=30)),
            "module_dirs": compute_module_dirs(root),
        },
        "existingFiles": {
            "glossary": {
                "path": glossary_file,
                "content": existing_glossary,
            },
            "intent": {
                "path": intent_file,
                "content": existing_intent,
            },
        },
        "glossarySchema": {
            "canonicalTerms": [],
            "aliases": {},
        },
    }


def main(argv: list[str]) -> int:
    project_root = parse_args(argv)
    try:
        os.chdir(project_root)
    except OSError as exc:
        print(f"cd: {project_root}: {exc.strerror}", file=sys.stderr)
        return 1
    root = Path.cwd()
    json.dump(scan(root), sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
