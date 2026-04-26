#!/usr/bin/env python3
"""Deterministic PR intake gate for GitHub pull_request_target workflows.

Security model:
- Reads the trusted script/config from the base checkout.
- Fetches PR metadata and changed-file metadata through GitHub REST API.
- Does not checkout, import, install, or execute PR head code.
- Does not interpolate PR title/body into shell commands.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import PurePosixPath
from typing import Any, Iterable

ROOT = os.environ.get("GITHUB_WORKSPACE") or os.getcwd()
CONFIG_PATH = os.path.join(ROOT, ".github", "pr-intake-gate.yml")
DEFAULT_API_URL = "https://api.github.com"

NEEDS_ISSUE_COMMENT = """<!-- pr-intake-gate -->

## PR Intake Gate: Issue or Discussion needed

Thanks for the contribution. Before code review, this PR needs a linked Issue or Discussion because it appears to be non-trivial.

Please add a link to the relevant Issue/Discussion, or open one describing:

1. The problem.
2. The expected outcome.
3. Why existing options are insufficient.
4. Alternatives considered.
5. Why this cannot be solved without code.

A maintainer can bypass this gate by adding `maintainer/override-intake`.
"""

HIGH_RISK_COMMENT = """<!-- pr-intake-gate -->

## PR Intake Gate: Maintainer review needed

Thanks for the contribution. This PR touches high-risk areas, so it needs explicit maintainer attention before code review proceeds.

High-risk areas may include workflows, dependencies, auth/security, install scripts, public APIs, or runtime behavior.

A maintainer can bypass this gate by adding `maintainer/override-intake`.
"""

PASS_COMMENT = """<!-- pr-intake-gate -->

## PR Intake Gate: Passed

This PR passed the intake gate. Code review can proceed.
"""


class GateError(RuntimeError):
    """Raised for configuration, event, or API errors."""


@dataclass(frozen=True)
class PullRequestContext:
    repository: str
    number: int
    title: str
    body: str
    author_association: str
    labels: set[str]
    base_sha: str
    head_sha: str


@dataclass(frozen=True)
class ChangedFile:
    filename: str
    additions: int
    deletions: int


@dataclass(frozen=True)
class Verdict:
    name: str
    reason: str
    next_step: str
    label: str
    should_comment: bool
    comment_body: str | None
    exit_code: int


def parse_scalar(raw: str) -> Any:
    raw = raw.strip()
    if raw == "":
        return ""
    if (raw.startswith("'") and raw.endswith("'")) or (raw.startswith('"') and raw.endswith('"')):
        return raw[1:-1]
    if raw in {"true", "True"}:
        return True
    if raw in {"false", "False"}:
        return False
    if raw in {"null", "Null", "~"}:
        return None
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw


def load_minimal_yaml(path: str) -> dict[str, Any]:
    """Load the limited YAML subset used by .github/pr-intake-gate.yml.

    Supported constructs: nested mappings, scalar lists, quoted/unquoted scalars,
    booleans, nulls, and integers. This avoids a PyYAML dependency in Actions.
    """

    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw_lines = handle.readlines()
    except FileNotFoundError as exc:
        raise GateError(f"missing config file: {path}") from exc

    lines: list[tuple[int, str]] = []
    for line in raw_lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        lines.append((indent, line.strip()))

    def parse_block(index: int, indent: int) -> tuple[Any, int]:
        if index >= len(lines):
            return {}, index

        current_indent, current_text = lines[index]
        if current_indent < indent:
            return {}, index
        is_list = current_text.startswith("- ")
        if is_list:
            values: list[Any] = []
            while index < len(lines):
                line_indent, text = lines[index]
                if line_indent != indent or not text.startswith("- "):
                    break
                values.append(parse_scalar(text[2:].strip()))
                index += 1
            return values, index

        values_dict: dict[str, Any] = {}
        while index < len(lines):
            line_indent, text = lines[index]
            if line_indent < indent:
                break
            if line_indent != indent:
                raise GateError(f"invalid indentation near: {text}")
            if text.startswith("- "):
                break
            if ":" not in text:
                raise GateError(f"invalid mapping line: {text}")
            key, value = text.split(":", 1)
            key = key.strip()
            value = value.strip()
            index += 1
            if value:
                values_dict[key] = parse_scalar(value)
            else:
                nested, index = parse_block(index, indent + 2)
                values_dict[key] = nested
        return values_dict, index

    parsed, final_index = parse_block(0, 0)
    if final_index != len(lines):
        raise GateError("failed to parse complete YAML config")
    if not isinstance(parsed, dict):
        raise GateError("config root must be a mapping")
    return parsed


def env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def load_event() -> dict[str, Any]:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        raise GateError("GITHUB_EVENT_PATH is required")
    with open(event_path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def get_pr_context(event: dict[str, Any]) -> PullRequestContext:
    pr = event.get("pull_request")
    if not isinstance(pr, dict):
        raise GateError("event does not contain pull_request")

    repository = event.get("repository", {}).get("full_name") or os.environ.get("GITHUB_REPOSITORY")
    if not repository:
        raise GateError("repository full name is missing")

    labels = {
        label.get("name", "")
        for label in pr.get("labels", [])
        if isinstance(label, dict) and label.get("name")
    }

    return PullRequestContext(
        repository=str(repository),
        number=int(pr["number"]),
        title=str(pr.get("title") or ""),
        body=str(pr.get("body") or ""),
        author_association=str(pr.get("author_association") or ""),
        labels=labels,
        base_sha=str(pr.get("base", {}).get("sha") or ""),
        head_sha=str(pr.get("head", {}).get("sha") or ""),
    )


def api_request(method: str, path: str, token: str, body: Any | None = None, allow_404: bool = False) -> Any:
    base_url = os.environ.get("GITHUB_API_URL", DEFAULT_API_URL).rstrip("/")
    url = f"{base_url}{path}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("User-Agent", "pr-intake-gate")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        request.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
            if not payload:
                return None
            return json.loads(payload.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if allow_404 and exc.code == 404:
            return None
        detail = exc.read().decode("utf-8", errors="replace")
        raise GateError(f"GitHub API {method} {path} failed: HTTP {exc.code}: {detail}") from exc


def get_token() -> str:
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise GateError("GITHUB_TOKEN is required unless PR_INTAKE_GATE_CHANGED_FILES_JSON is set")
    return token


def load_changed_files(ctx: PullRequestContext) -> list[ChangedFile]:
    fixture = os.environ.get("PR_INTAKE_GATE_CHANGED_FILES_JSON")
    if fixture:
        raw_files = json.loads(fixture)
    else:
        token = get_token()
        encoded_repo = urllib.parse.quote(ctx.repository, safe="/")
        raw_files = []
        page = 1
        per_page = 100
        while True:
            page_files = api_request(
                "GET",
                f"/repos/{encoded_repo}/pulls/{ctx.number}/files?per_page={per_page}&page={page}",
                token,
            )
            if not isinstance(page_files, list):
                raise GateError("unexpected changed files response")
            raw_files.extend(page_files)
            if len(page_files) < per_page:
                break
            page += 1

    changed: list[ChangedFile] = []
    for item in raw_files:
        changed.append(
            ChangedFile(
                filename=str(item.get("filename") or ""),
                additions=int(item.get("additions") or 0),
                deletions=int(item.get("deletions") or 0),
            )
        )
    return changed


def path_matches(path: str, pattern: str) -> bool:
    normalized = path.strip("/")
    pattern = pattern.strip("/")
    pure = PurePosixPath(normalized)
    if fnmatchcase(normalized, pattern):
        return True
    if pure.match(pattern):
        return True
    if pattern.startswith("**/") and (fnmatchcase(normalized, pattern[3:]) or pure.match(pattern[3:])):
        return True
    return False


def matching_patterns(path: str, patterns: Iterable[str]) -> list[str]:
    return [pattern for pattern in patterns if path_matches(path, pattern)]


def has_linked_intent(text: str, patterns: Iterable[str]) -> bool:
    for pattern in patterns:
        if re.search(pattern, text, flags=re.IGNORECASE):
            return True
    return False


def managed_intake_labels(config: dict[str, Any]) -> set[str]:
    labels = config.get("labels", {})
    if not isinstance(labels, dict):
        return set()
    override = labels.get("override")
    return {str(value) for value in labels.values() if value and value != override and str(value).startswith("intake/")}


def dry_run() -> bool:
    return env_flag("PR_INTAKE_GATE_DRY_RUN")


def apply_label(ctx: PullRequestContext, label: str) -> None:
    if not label:
        return
    if dry_run():
        print(f"dry-run: apply label {label}", file=sys.stderr)
        return
    token = get_token()
    repo = urllib.parse.quote(ctx.repository, safe="/")
    api_request("POST", f"/repos/{repo}/issues/{ctx.number}/labels", token, {"labels": [label]})


def remove_labels(ctx: PullRequestContext, labels: Iterable[str]) -> None:
    if dry_run():
        for label in labels:
            print(f"dry-run: remove label {label}", file=sys.stderr)
        return
    token = get_token()
    repo = urllib.parse.quote(ctx.repository, safe="/")
    for label in labels:
        encoded_label = urllib.parse.quote(label, safe="")
        api_request("DELETE", f"/repos/{repo}/issues/{ctx.number}/labels/{encoded_label}", token, allow_404=True)


def sync_labels(ctx: PullRequestContext, config: dict[str, Any], target_label: str) -> None:
    stale = sorted((managed_intake_labels(config) - {target_label}) & ctx.labels)
    apply_label(ctx, target_label)
    remove_labels(ctx, stale)


def list_comments(ctx: PullRequestContext) -> list[dict[str, Any]]:
    if dry_run():
        return []
    token = get_token()
    repo = urllib.parse.quote(ctx.repository, safe="/")
    comments: list[dict[str, Any]] = []
    page = 1
    per_page = 100
    while True:
        page_comments = api_request(
            "GET",
            f"/repos/{repo}/issues/{ctx.number}/comments?per_page={per_page}&page={page}",
            token,
        )
        if not isinstance(page_comments, list):
            raise GateError("unexpected comments response")
        comments.extend(page_comments)
        if len(page_comments) < per_page:
            break
        page += 1
    return comments


def upsert_comment(ctx: PullRequestContext, marker: str, body: str) -> None:
    if dry_run():
        print("dry-run: upsert gate comment", file=sys.stderr)
        return
    token = get_token()
    repo = urllib.parse.quote(ctx.repository, safe="/")
    for comment in list_comments(ctx):
        if marker in str(comment.get("body") or ""):
            comment_id = comment.get("id")
            if comment_id:
                api_request("PATCH", f"/repos/{repo}/issues/comments/{comment_id}", token, {"body": body})
                return
    api_request("POST", f"/repos/{repo}/issues/{ctx.number}/comments", token, {"body": body})


def update_existing_gate_comment(ctx: PullRequestContext, marker: str, body: str) -> None:
    if dry_run():
        return
    token = get_token()
    repo = urllib.parse.quote(ctx.repository, safe="/")
    for comment in list_comments(ctx):
        if marker in str(comment.get("body") or ""):
            comment_id = comment.get("id")
            if comment_id:
                api_request("PATCH", f"/repos/{repo}/issues/comments/{comment_id}", token, {"body": body})
            return


def write_step_summary(summary: dict[str, Any]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    high_risk_paths = summary.get("high_risk_paths") or []
    if high_risk_paths:
        high_risk_text = "\n".join(f"  - `{item}`" for item in high_risk_paths)
    else:
        high_risk_text = "  - none"

    lines = [
        "## PR Intake Gate",
        "",
        f"- Verdict: `{summary['verdict']}`",
        f"- Changed lines: `{summary['changed_lines']}`",
        f"- Linked intent: `{'yes' if summary['linked_intent'] else 'no'}`",
        "- High-risk paths:",
        high_risk_text,
        f"- Reason: {summary['reason']}",
        f"- Next step: {summary['next_step']}",
        "",
    ]
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def determine_verdict(
    ctx: PullRequestContext,
    config: dict[str, Any],
    files: list[ChangedFile],
) -> tuple[Verdict, dict[str, Any]]:
    labels = config.get("labels", {})
    if not isinstance(labels, dict):
        raise GateError("config.labels must be a mapping")

    override_label = str(labels.get("override") or "maintainer/override-intake")
    pass_label = str(labels.get("pass") or "intake/pass")
    needs_issue_label = str(labels.get("needs_issue") or "intake/needs-issue")
    high_risk_label = str(labels.get("high_risk") or "intake/high-risk")

    trivial_config = config.get("trivial", {})
    max_changed_lines = int(trivial_config.get("max_changed_lines", 30))
    allowed_path_globs = [str(item) for item in trivial_config.get("allowed_path_globs", [])]
    high_risk_globs = [str(item) for item in config.get("high_risk_path_globs", [])]
    accept_patterns = [str(item) for item in config.get("linked_intent", {}).get("accept_patterns", [])]

    changed_lines = sum(item.additions + item.deletions for item in files)
    changed_paths = [item.filename for item in files]
    high_risk_paths = sorted(
        path
        for path in changed_paths
        if matching_patterns(path, high_risk_globs)
    )
    all_paths_allowed = all(
        any(path_matches(path, pattern) for pattern in allowed_path_globs)
        for path in changed_paths
    )
    is_trivial = changed_lines <= max_changed_lines and all_paths_allowed and not high_risk_paths
    linked = has_linked_intent(ctx.body, accept_patterns)

    marker = str(config.get("bot_comment", {}).get("marker") or "<!-- pr-intake-gate -->")
    details = {
        "repository": ctx.repository,
        "pull_request": ctx.number,
        "author_association": ctx.author_association,
        "base_sha": ctx.base_sha,
        "head_sha": ctx.head_sha,
        "changed_lines": changed_lines,
        "changed_paths": changed_paths,
        "high_risk_paths": high_risk_paths,
        "linked_intent": linked,
        "is_trivial": is_trivial,
        "marker": marker,
    }

    if override_label in ctx.labels:
        return (
            Verdict(
                name="pass",
                reason="Maintainer override label is present.",
                next_step="Code review can proceed; maintainer accepted intake responsibility.",
                label=pass_label,
                should_comment=False,
                comment_body=None,
                exit_code=0,
            ),
            details,
        )

    if high_risk_paths:
        return (
            Verdict(
                name="high-risk",
                reason="PR touches high-risk paths.",
                next_step="Maintainer should review intent/risk or add maintainer override.",
                label=high_risk_label,
                should_comment=True,
                comment_body=HIGH_RISK_COMMENT,
                exit_code=1,
            ),
            details,
        )

    if is_trivial:
        return (
            Verdict(
                name="pass",
                reason="PR is within trivial direct-PR limits.",
                next_step="Code review can proceed.",
                label=pass_label,
                should_comment=False,
                comment_body=None,
                exit_code=0,
            ),
            details,
        )

    if not linked:
        return (
            Verdict(
                name="needs-issue",
                reason="Non-trivial PR does not include linked Issue or Discussion intent.",
                next_step="Add a linked Issue/Discussion or ask a maintainer for override.",
                label=needs_issue_label,
                should_comment=True,
                comment_body=NEEDS_ISSUE_COMMENT,
                exit_code=1,
            ),
            details,
        )

    return (
        Verdict(
            name="pass",
            reason="Non-trivial PR includes linked intent and avoids configured high-risk paths.",
            next_step="Code review can proceed.",
            label=pass_label,
            should_comment=False,
            comment_body=None,
            exit_code=0,
        ),
        details,
    )


def main() -> int:
    try:
        config = load_minimal_yaml(CONFIG_PATH)
        event = load_event()
        ctx = get_pr_context(event)
        files = load_changed_files(ctx)
        verdict, details = determine_verdict(ctx, config, files)

        sync_labels(ctx, config, verdict.label)
        marker = str(details["marker"])
        if verdict.should_comment and verdict.comment_body:
            upsert_comment(ctx, marker, verdict.comment_body)
        elif verdict.exit_code == 0:
            update_existing_gate_comment(ctx, marker, PASS_COMMENT)

        summary = {
            **details,
            "verdict": verdict.name,
            "reason": verdict.reason,
            "next_step": verdict.next_step,
        }
        write_step_summary(summary)
        print(json.dumps(summary, sort_keys=True))
        return verdict.exit_code
    except GateError as exc:
        print(f"pr-intake-gate error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
