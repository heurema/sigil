#!/usr/bin/env python3
"""Render Signum command markdown from an explicit fragment manifest."""

from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path
from typing import Any


class RenderError(Exception):
    pass


def _looks_like_repo_root(candidate: Path) -> bool:
    return (
        (candidate / ".claude-plugin" / "plugin.json").is_file()
        and (candidate / "commands" / "signum.shared.fragments").is_dir()
        and (candidate / "scripts" / "render_signum_command.py").is_file()
    )


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for candidate in [here.parent, *here.parents]:
        if (candidate / ".git").exists() or _looks_like_repo_root(candidate):
            return candidate
    return here.parents[1]


def _load_manifest(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RenderError(f"manifest not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise RenderError(f"invalid manifest JSON: {path}: line {exc.lineno} column {exc.colno}: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise RenderError("manifest top-level value must be object")
    if data.get("version") != 1:
        raise RenderError("manifest.version must be 1")
    fragments = data.get("fragments")
    if not isinstance(fragments, list) or not fragments:
        raise RenderError("manifest.fragments must be a non-empty array")
    return data


def _fragment_path(manifest_dir: Path, repo_root: Path, value: Any) -> Path:
    scope = "manifest"
    if isinstance(value, str):
        rel = value
    elif isinstance(value, dict) and isinstance(value.get("path"), str):
        rel = value["path"]
        scope = value.get("scope", "manifest")
        if scope not in {"manifest", "repo"}:
            raise RenderError(f"fragment scope must be 'manifest' or 'repo': {scope!r}")
    else:
        raise RenderError("each fragment entry must be a string or object with path")

    rel_path = Path(rel)
    if rel_path.is_absolute():
        raise RenderError(f"absolute fragment paths are not allowed: {rel}")
    if ".." in rel_path.parts:
        raise RenderError(f"path traversal in fragment path is not allowed: {rel}")
    if rel in {"", "."}:
        raise RenderError("empty fragment path is not allowed")
    base = repo_root if scope == "repo" else manifest_dir
    return base / rel_path


def render(manifest_path: Path) -> bytes:
    manifest_path = manifest_path.resolve()
    manifest_dir = manifest_path.parent
    repo_root = _repo_root().resolve()
    try:
        manifest_dir.relative_to(repo_root)
    except ValueError as exc:
        raise RenderError(f"manifest must live inside repository root: {manifest_path}") from exc

    manifest = _load_manifest(manifest_path)
    rendered = bytearray()
    seen: set[Path] = set()
    for entry in manifest["fragments"]:
        fragment = _fragment_path(manifest_dir, repo_root, entry).resolve()
        try:
            fragment.relative_to(repo_root)
        except ValueError as exc:
            raise RenderError(f"fragment escapes repository root: {fragment}") from exc
        if fragment in seen:
            raise RenderError(f"duplicate fragment entry: {fragment.relative_to(repo_root)}")
        seen.add(fragment)
        try:
            rendered.extend(fragment.read_bytes())
        except FileNotFoundError as exc:
            raise RenderError(f"fragment not found: {fragment}") from exc
    return bytes(rendered)


def _diff_summary(expected: bytes, actual: bytes, output_path: Path) -> str:
    expected_text = expected.decode("utf-8", errors="replace").splitlines(keepends=True)
    actual_text = actual.decode("utf-8", errors="replace").splitlines(keepends=True)
    diff = difflib.unified_diff(
        actual_text,
        expected_text,
        fromfile=str(output_path),
        tofile="rendered",
        n=3,
    )
    lines = list(diff)
    if not lines:
        return "byte mismatch with no textual diff (possibly line ending or encoding difference)"
    return "".join(lines[:80])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render Signum command markdown from fragments")
    parser.add_argument("--manifest", required=True, help="path to manifest.json")
    parser.add_argument("--output", required=True, help="path to rendered command file")
    parser.add_argument("--check", action="store_true", help="compare rendered output to --output without writing")
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest)
    output_path = Path(args.output)
    try:
        rendered = render(manifest_path)
        if args.check:
            current = output_path.read_bytes()
            if current != rendered:
                print(f"rendered output differs: {output_path}", file=sys.stderr)
                print(_diff_summary(rendered, current, output_path), file=sys.stderr)
                return 1
            return 0
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(rendered)
        return 0
    except (OSError, RenderError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
