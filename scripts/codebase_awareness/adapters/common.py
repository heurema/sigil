"""Shared stdlib helpers for codebase awareness scanner adapters."""

from __future__ import annotations

import re
from pathlib import Path


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


def is_test_fixture_path(rel: str) -> bool:
    return "testdata" in Path(rel).parts


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
