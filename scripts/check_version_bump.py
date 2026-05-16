#!/usr/bin/env python3
"""Require a plugin version bump for runtime/plugin surface changes."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable


SCHEMA_VERSION = "1.0"
PLUGIN_MANIFEST = ".claude-plugin/plugin.json"
SENSITIVE_PREFIXES = (
    "agents/",
    "commands/",
    "lib/",
    "platforms/claude-code/agents/",
    "platforms/claude-code/commands/",
    "platforms/claude-code/lib/",
    "platforms/claude-code/scripts/",
    "platforms/codex/",
    "scripts/",
)
SENSITIVE_EXACT = {
    ".agents/plugins/marketplace.json",
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    "platforms/claude-code/.claude-plugin/plugin.json",
}
SEMVER_RE = re.compile(r"^([0-9]+)\.([0-9]+)\.([0-9]+)$")


def run_git(repo_root: Path, args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"git {' '.join(args)} failed")
    return result


def repo_rel(path: str) -> str:
    normalized = path.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def resolve_base_ref(repo_root: Path, explicit: str | None) -> tuple[str | None, str | None]:
    if explicit:
        result = run_git(repo_root, ["rev-parse", "--verify", f"{explicit}^{{commit}}"], check=False)
        return (explicit, None) if result.returncode == 0 else (explicit, "base_ref_unavailable")

    env_ref = os.environ.get("SIGNUM_VERSION_BUMP_BASE")
    if env_ref:
        result = run_git(repo_root, ["rev-parse", "--verify", f"{env_ref}^{{commit}}"], check=False)
        return (env_ref, None) if result.returncode == 0 else (env_ref, "base_ref_unavailable")

    for ref in ("origin/main", "HEAD^"):
        result = run_git(repo_root, ["rev-parse", "--verify", f"{ref}^{{commit}}"], check=False)
        if result.returncode == 0:
            return ref, None
    return None, "base_ref_unavailable"


def load_current_version(repo_root: Path) -> str | None:
    path = repo_root / PLUGIN_MANIFEST
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    value = data.get("version")
    return value if isinstance(value, str) else None


def load_base_version(repo_root: Path, base_ref: str) -> str | None:
    result = run_git(repo_root, ["show", f"{base_ref}:{PLUGIN_MANIFEST}"], check=False)
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    value = data.get("version")
    return value if isinstance(value, str) else None


def parse_semver(version: str | None) -> tuple[int, int, int] | None:
    if not version:
        return None
    match = SEMVER_RE.match(version)
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def changed_files(repo_root: Path, base_ref: str) -> list[str]:
    result = run_git(repo_root, ["diff", "--name-only", base_ref, "--"])
    files = {repo_rel(line) for line in result.stdout.splitlines() if line.strip()}
    untracked = run_git(repo_root, ["ls-files", "--others", "--exclude-standard"])
    files.update(repo_rel(line) for line in untracked.stdout.splitlines() if line.strip())
    return sorted(files)


def is_sensitive(path: str) -> bool:
    return path in SENSITIVE_EXACT or any(path.startswith(prefix) for prefix in SENSITIVE_PREFIXES)


def check(repo_root: Path, base_ref_arg: str | None) -> dict:
    base_ref, skip_reason = resolve_base_ref(repo_root, base_ref_arg)
    current_version = load_current_version(repo_root)
    report = {
        "schemaVersion": SCHEMA_VERSION,
        "status": "ok",
        "baseRef": base_ref,
        "baseVersion": None,
        "currentVersion": current_version,
        "versionBumpRequired": False,
        "hardGatePassed": True,
        "sensitiveChangedFiles": [],
        "violations": [],
    }

    if skip_reason is not None:
        report["status"] = "skipped"
        report["violations"] = []
        report["skipReason"] = skip_reason
        return report

    base_version = load_base_version(repo_root, base_ref)
    sensitive = [path for path in changed_files(repo_root, base_ref) if is_sensitive(path)]
    report["baseVersion"] = base_version
    report["sensitiveChangedFiles"] = sensitive
    report["versionBumpRequired"] = bool(sensitive)

    if not sensitive:
        return report

    base_semver = parse_semver(base_version)
    current_semver = parse_semver(current_version)
    violations: list[dict[str, str]] = []

    if base_semver is None:
        violations.append({"id": "version.base_unreadable", "message": f"cannot read semver from {base_ref}:{PLUGIN_MANIFEST}"})
    if current_semver is None:
        violations.append({"id": "version.current_unreadable", "message": f"cannot read semver from {PLUGIN_MANIFEST}"})
    if base_semver is not None and current_semver is not None and current_semver <= base_semver:
        violations.append(
            {
                "id": "version.bump_required",
                "message": "runtime/plugin changes require .claude-plugin/plugin.json version to increase",
            }
        )

    if violations:
        report["status"] = "error"
        report["hardGatePassed"] = False
        report["violations"] = violations
    return report


def write_report(report: dict, output: Path | None) -> None:
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if output:
        output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root to inspect")
    parser.add_argument("--base-ref", help="base git ref to compare against")
    parser.add_argument("--json-output", help="write deterministic JSON report to this path")
    args = parser.parse_args(list(argv) if argv is not None else None)

    repo_root = Path(args.repo_root).resolve()
    output = Path(args.json_output) if args.json_output else None
    try:
        report = check(repo_root, args.base_ref)
    except Exception as exc:  # pragma: no cover - defensive CLI boundary
        report = {
            "schemaVersion": SCHEMA_VERSION,
            "status": "error",
            "baseRef": args.base_ref,
            "baseVersion": None,
            "currentVersion": None,
            "versionBumpRequired": False,
            "hardGatePassed": False,
            "sensitiveChangedFiles": [],
            "violations": [{"id": "version.check_failed", "message": str(exc)}],
        }
    write_report(report, output)
    return 0 if report.get("hardGatePassed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
