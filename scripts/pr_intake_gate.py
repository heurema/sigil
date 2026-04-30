#!/usr/bin/env python3
"""Deterministic PR intake gate for GitHub pull_request_target workflows.

Security model:
- Reads the trusted script/config from the base checkout.
- Fetches PR metadata, author permission, and changed-file metadata through GitHub REST API.
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
from dataclasses import dataclass, field
from fnmatch import fnmatchcase
from pathlib import PurePosixPath
from typing import Any, Callable, Iterable

ROOT = os.environ.get("GITHUB_WORKSPACE") or os.getcwd()
CONFIG_PATH = os.path.join(ROOT, ".github", "pr-intake-gate.yml")
DEFAULT_API_URL = "https://api.github.com"

NEEDS_ISSUE_COMMENT = """<!-- pr-intake-gate -->

## PR Intake Gate: Issue or Discussion needed

Thanks for the contribution. External non-trivial PRs need enough context before ordinary code review.

Please link the relevant GitHub Issue or Discussion in the PR body. The linked intent should explain:

1. The problem.
2. Why it is needed now.
3. Existing options checked.
4. Alternatives considered.
5. The no-code alternative.
6. Why code is needed.

A maintainer can bypass this gate by adding `maintainer/override-intake`, or accept non-high-risk external PRs with `intake/accepted-for-pr`.
"""

HIGH_RISK_COMMENT = """<!-- pr-intake-gate -->

## PR Intake Gate: maintainer review needed

Thanks for the contribution. This external PR touches high-risk Signum areas, so it needs explicit maintainer attention before ordinary code review proceeds.

High-risk areas may include workflows, dependencies, auth/security, install scripts, public APIs, schemas, command behavior, or runtime behavior.

A maintainer can bypass this gate by adding `maintainer/override-intake`. For non-high-risk external PRs, a maintainer can use `intake/accepted-for-pr`, but that label does not bypass high-risk intake.
"""

PASS_COMMENT = """<!-- pr-intake-gate -->

## PR Intake Gate: passed

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
    author_login: str
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
    extra_labels: tuple[str, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class AuthorPermission:
    permission: str | None
    error: str | None = None


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
        if current_text.startswith("- "):
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


def dry_run() -> bool:
    return env_flag("PR_INTAKE_GATE_DRY_RUN")


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
    user = pr.get("user") or {}
    author_login = user.get("login") if isinstance(user, dict) else ""

    return PullRequestContext(
        repository=str(repository),
        number=int(pr["number"]),
        title=str(pr.get("title") or ""),
        body=str(pr.get("body") or ""),
        author_login=str(author_login or ""),
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
    except (TimeoutError, urllib.error.URLError) as exc:
        raise GateError(f"GitHub API {method} {path} failed: {exc}") from exc


def get_token() -> str:
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise GateError("GITHUB_TOKEN is required for GitHub API reads and writes")
    return token


def resolve_author_permission(ctx: PullRequestContext) -> AuthorPermission:
    fixture = os.environ.get("PR_INTAKE_GATE_AUTHOR_PERMISSION")
    if fixture is not None:
        normalized = fixture.strip().lower()
        return AuthorPermission(None if normalized in {"", "none", "null"} else normalized)
    if dry_run():
        return AuthorPermission(None)
    if not ctx.author_login:
        return AuthorPermission(None, "missing author login")

    try:
        token = get_token()
        repo = urllib.parse.quote(ctx.repository, safe="/")
        login = urllib.parse.quote(ctx.author_login, safe="")
        payload = api_request("GET", f"/repos/{repo}/collaborators/{login}/permission", token)
    except GateError as exc:
        return AuthorPermission(None, str(exc))

    if not isinstance(payload, dict):
        return AuthorPermission(None, "unexpected author permission response")
    permission = payload.get("permission")
    return AuthorPermission(str(permission).lower() if permission else None)


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
    if not normalized or not pattern:
        return normalized == pattern
    return match_path_parts(tuple(PurePosixPath(normalized).parts), tuple(PurePosixPath(pattern).parts))


def match_path_parts(path_parts: tuple[str, ...], pattern_parts: tuple[str, ...]) -> bool:
    if not pattern_parts:
        return not path_parts

    head, *tail = pattern_parts
    if head == "**":
        if not tail:
            return True
        return any(match_path_parts(path_parts[index:], tuple(tail)) for index in range(len(path_parts) + 1))

    if not path_parts:
        return False
    return fnmatchcase(path_parts[0], head) and match_path_parts(path_parts[1:], tuple(tail))


def matching_patterns(path: str, patterns: Iterable[str]) -> list[str]:
    return [pattern for pattern in patterns if path_matches(path, pattern)]


def has_linked_intent(text: str, patterns: Iterable[str]) -> bool:
    return any(re.search(pattern, text, flags=re.IGNORECASE) for pattern in patterns)


def normalize_heading(value: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value.lower()).split())


def markdown_sections(text: str) -> dict[str, str]:
    matches = list(re.finditer(r"^#{2,6}\s+(.+?)\s*$", text, flags=re.MULTILINE))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections[normalize_heading(match.group(1))] = text[start:end].strip()
    return sections


def is_meaningful_section_value(value: str) -> bool:
    stripped_lines = [line.strip() for line in value.splitlines()]
    content_lines = [line for line in stripped_lines if line and line not in {"-", "N/A", "n/a"}]
    return bool(content_lines)


def missing_required_sections(body: str, required_sections: Iterable[str]) -> list[str]:
    sections = markdown_sections(body)
    missing: list[str] = []
    for section in required_sections:
        normalized = normalize_heading(section)
        if not is_meaningful_section_value(sections.get(normalized, "")):
            missing.append(section)
    return missing


def managed_verdict_labels(config: dict[str, Any]) -> set[str]:
    labels = config.get("labels", {})
    if not isinstance(labels, dict):
        return set()
    verdict_keys = {"pass", "needs_issue", "needs_more_context", "no_code_alternative", "high_risk"}
    return {str(labels[key]) for key in verdict_keys if labels.get(key) and str(labels[key]).startswith("intake/")}


def get_label_details(config: dict[str, Any], label: str) -> dict[str, str]:
    details = config.get("label_details", {})
    if not isinstance(details, dict):
        return {}
    raw = details.get(label, {})
    if not isinstance(raw, dict):
        return {}
    result: dict[str, str] = {}
    for key in ("color", "description"):
        value = raw.get(key)
        if value is not None:
            result[key] = str(value)
    return result


def ensure_label(ctx: PullRequestContext, config: dict[str, Any], label: str) -> None:
    if not label:
        return
    details = get_label_details(config, label)
    if not details:
        return
    if dry_run():
        print(f"dry-run: ensure label {label}", file=sys.stderr)
        return

    token = get_token()
    repo = urllib.parse.quote(ctx.repository, safe="/")
    encoded_label = urllib.parse.quote(label, safe="")
    existing = api_request("GET", f"/repos/{repo}/labels/{encoded_label}", token, allow_404=True)
    if existing is not None:
        return

    body = {"name": label, "color": details.get("color", "ededed")}
    if details.get("description"):
        body["description"] = details["description"]
    api_request("POST", f"/repos/{repo}/labels", token, body)


def apply_label(ctx: PullRequestContext, config: dict[str, Any], label: str) -> None:
    if not label:
        return
    ensure_label(ctx, config, label)
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


def sync_labels(ctx: PullRequestContext, config: dict[str, Any], target_label: str, extra_labels: Iterable[str]) -> None:
    stale = sorted((managed_verdict_labels(config) - {target_label}) & ctx.labels)
    apply_label(ctx, config, target_label)
    for label in extra_labels:
        apply_label(ctx, config, label)
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


def gate_comment_bot_logins() -> set[str]:
    raw = os.environ.get("PR_INTAKE_GATE_COMMENT_BOT_LOGINS", "github-actions[bot]")
    return {item.strip() for item in raw.split(",") if item.strip()}


def is_gate_comment(comment: dict[str, Any], marker: str) -> bool:
    if marker not in str(comment.get("body") or ""):
        return False
    user = comment.get("user") or {}
    if not isinstance(user, dict):
        return False
    login = str(user.get("login") or "")
    user_type = str(user.get("type") or "")
    return login in gate_comment_bot_logins() and user_type in {"", "Bot"}


def upsert_comment(ctx: PullRequestContext, marker: str, body: str) -> None:
    if dry_run():
        print("dry-run: upsert gate comment", file=sys.stderr)
        return
    token = get_token()
    repo = urllib.parse.quote(ctx.repository, safe="/")
    for comment in list_comments(ctx):
        if is_gate_comment(comment, marker):
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
        if is_gate_comment(comment, marker):
            comment_id = comment.get("id")
            if comment_id:
                api_request("PATCH", f"/repos/{repo}/issues/comments/{comment_id}", token, {"body": body})
            return


def run_optional_side_effect(name: str, action: Callable[[], None]) -> bool:
    try:
        action()
        return True
    except GateError as exc:
        print(f"pr-intake-gate warning: {name} skipped: {exc}", file=sys.stderr)
        return False


def format_list(values: Iterable[str]) -> str:
    items = list(values)
    if not items:
        return "none"
    return ", ".join(f"`{item}`" for item in items)


def write_step_summary(summary: dict[str, Any]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    high_risk_paths = summary.get("high_risk_paths") or []
    high_risk_text = "\n".join(f"  - `{item}`" for item in high_risk_paths) if high_risk_paths else "  - none"
    changed_paths = summary.get("changed_paths") or []
    changed_paths_text = "\n".join(f"  - `{item}`" for item in changed_paths) if changed_paths else "  - none"

    lines = [
        "## PR Intake Gate",
        "",
        f"- Verdict: `{summary['verdict']}`",
        f"- Author login: `{summary['author_login'] or 'unknown'}`",
        f"- Author association: `{summary['author_association'] or 'unknown'}`",
        f"- Author permission: `{summary['author_permission'] or 'unknown'}`",
        f"- Author permission error: `{summary['author_permission_error'] or 'none'}`",
        f"- Trusted author: `{'yes' if summary['trusted_author'] else 'no'}`",
        f"- Trust source: `{summary['trust_source']}`",
        f"- First-time external: `{'yes' if summary['first_time_external'] else 'no'}`",
        f"- Changed lines: `{summary['changed_lines']}`",
        "- Changed paths:",
        changed_paths_text,
        "- High-risk paths:",
        high_risk_text,
        f"- Linked intent: `{'yes' if summary['linked_intent'] else 'no'}`",
        f"- Accepted for PR: `{'yes' if summary['accepted_for_pr'] else 'no'}`",
        f"- Missing external context sections: {format_list(summary.get('missing_external_context_sections') or [])}",
        f"- Reason: {summary['reason']}",
        f"- Next step: {summary['next_step']}",
        "",
    ]
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def list_config(config: dict[str, Any], path: tuple[str, ...], default: list[str]) -> list[str]:
    raw: Any = config
    for key in path:
        if not isinstance(raw, dict):
            return default
        raw = raw.get(key)
    if not isinstance(raw, list):
        return default
    return [str(item) for item in raw]


def scalar_config(config: dict[str, Any], path: tuple[str, ...], default: str) -> str:
    raw: Any = config
    for key in path:
        if not isinstance(raw, dict):
            return default
        raw = raw.get(key)
    return str(raw) if raw is not None else default


def trust_author(ctx: PullRequestContext, config: dict[str, Any], author_permission: AuthorPermission) -> tuple[bool, str]:
    trusted_permissions = {
        item.lower()
        for item in list_config(config, ("trusted_authors", "permissions"), ["admin", "maintain", "write"])
    }
    trusted_associations = {
        item.upper()
        for item in list_config(
            config,
            ("trusted_authors", "fallback_author_associations"),
            ["OWNER", "MEMBER", "COLLABORATOR"],
        )
    }

    if author_permission.permission and author_permission.permission.lower() in trusted_permissions:
        return True, f"permission:{author_permission.permission.lower()}"
    if author_permission.permission is None and ctx.author_association.upper() in trusted_associations:
        return True, f"author_association:{ctx.author_association.upper()}"
    return False, "external"


def build_missing_context_comment(missing: list[str], no_code_only: bool) -> str:
    heading = "no-code alternative needed" if no_code_only else "more context needed"
    lines = [
        "<!-- pr-intake-gate -->",
        "",
        f"## PR Intake Gate: {heading}",
        "",
        "Thanks for the contribution. External non-trivial PRs need enough context before ordinary code review.",
        "",
        "Please fill these PR body sections:",
        "",
    ]
    lines.extend(f"- `{item}`" for item in missing)
    lines.extend(
        [
            "",
            "A maintainer can bypass this gate by adding `maintainer/override-intake`, or accept non-high-risk external PRs with `intake/accepted-for-pr`.",
        ]
    )
    return "\n".join(lines)


def determine_verdict(
    ctx: PullRequestContext,
    config: dict[str, Any],
    files: list[ChangedFile],
    author_permission: AuthorPermission,
) -> tuple[Verdict, dict[str, Any]]:
    labels = config.get("labels", {})
    if not isinstance(labels, dict):
        raise GateError("config.labels must be a mapping")

    override_label = str(labels.get("override") or "maintainer/override-intake")
    pass_label = str(labels.get("pass") or "intake/pass")
    needs_issue_label = str(labels.get("needs_issue") or "intake/needs-issue")
    needs_more_context_label = str(labels.get("needs_more_context") or "intake/needs-more-context")
    no_code_alternative_label = str(labels.get("no_code_alternative") or "intake/no-code-alternative")
    high_risk_label = str(labels.get("high_risk") or "intake/high-risk")
    accepted_for_pr_label = str(labels.get("accepted_for_pr") or "intake/accepted-for-pr")
    first_time_label = str(labels.get("first_time") or "intake/first-time-contributor")

    trivial_config = config.get("trivial", {})
    max_changed_lines = int(trivial_config.get("max_changed_lines", 30))
    allowed_path_globs = [str(item) for item in trivial_config.get("allowed_path_globs", [])]
    high_risk_globs = [str(item) for item in config.get("high_risk_path_globs", [])]
    accept_patterns = [str(item) for item in config.get("linked_intent", {}).get("accept_patterns", [])]
    required_sections = list_config(config, ("external_context", "required_sections"), [])
    no_code_section = scalar_config(config, ("external_context", "no_code_section"), "No-code alternative")
    first_time_associations = {
        item.upper()
        for item in list_config(
            config,
            ("external_context", "first_time_author_associations"),
            ["FIRST_TIMER", "FIRST_TIME_CONTRIBUTOR"],
        )
    }

    changed_lines = sum(item.additions + item.deletions for item in files)
    changed_paths = [item.filename for item in files]
    high_risk_paths = sorted(path for path in changed_paths if matching_patterns(path, high_risk_globs))
    all_paths_allowed = all(any(path_matches(path, pattern) for pattern in allowed_path_globs) for path in changed_paths)
    is_trivial = bool(changed_paths) and changed_lines <= max_changed_lines and all_paths_allowed and not high_risk_paths
    linked = has_linked_intent(ctx.body, accept_patterns)
    trusted_author, trust_source = trust_author(ctx, config, author_permission)
    first_time_external = (not trusted_author) and ctx.author_association.upper() in first_time_associations
    external_extra_labels = (first_time_label,) if first_time_external else ()
    accepted_for_pr = accepted_for_pr_label in ctx.labels
    missing_sections = missing_required_sections(ctx.body, required_sections) if required_sections else []
    missing_no_code = no_code_section in missing_sections

    marker = str(config.get("bot_comment", {}).get("marker") or "<!-- pr-intake-gate -->")
    details = {
        "repository": ctx.repository,
        "pull_request": ctx.number,
        "author_login": ctx.author_login,
        "author_association": ctx.author_association,
        "author_permission": author_permission.permission,
        "author_permission_error": author_permission.error,
        "trusted_author": trusted_author,
        "trust_source": trust_source,
        "first_time_external": first_time_external,
        "base_sha": ctx.base_sha,
        "head_sha": ctx.head_sha,
        "changed_lines": changed_lines,
        "changed_paths": changed_paths,
        "high_risk_paths": high_risk_paths,
        "linked_intent": linked,
        "accepted_for_pr": accepted_for_pr,
        "is_trivial": is_trivial,
        "missing_external_context_sections": missing_sections,
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
                extra_labels=external_extra_labels,
            ),
            details,
        )

    if trusted_author:
        return (
            Verdict(
                name="pass",
                reason=f"Trusted repository author ({trust_source}).",
                next_step="Code review can proceed; external-contributor intake checks are skipped.",
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
                reason="External PR touches configured high-risk Signum paths.",
                next_step="Maintainer should review intent/risk or add maintainer override.",
                label=high_risk_label,
                should_comment=True,
                comment_body=HIGH_RISK_COMMENT,
                exit_code=1,
                extra_labels=external_extra_labels,
            ),
            details,
        )

    if is_trivial:
        return (
            Verdict(
                name="pass",
                reason="External PR is within trivial direct-PR limits.",
                next_step="Code review can proceed.",
                label=pass_label,
                should_comment=False,
                comment_body=None,
                exit_code=0,
                extra_labels=external_extra_labels,
            ),
            details,
        )

    if accepted_for_pr:
        return (
            Verdict(
                name="pass",
                reason="Maintainer accepted this non-high-risk external PR for review.",
                next_step="Code review can proceed.",
                label=pass_label,
                should_comment=False,
                comment_body=None,
                exit_code=0,
                extra_labels=external_extra_labels,
            ),
            details,
        )

    if missing_no_code:
        return (
            Verdict(
                name="no-code-alternative",
                reason="External non-trivial PR is missing no-code alternative analysis.",
                next_step="Fill the no-code alternative section or ask a maintainer to accept the PR intent.",
                label=no_code_alternative_label,
                should_comment=True,
                comment_body=build_missing_context_comment(missing_sections, no_code_only=True),
                exit_code=1,
                extra_labels=external_extra_labels,
            ),
            details,
        )

    if missing_sections:
        return (
            Verdict(
                name="needs-more-context",
                reason="External non-trivial PR is missing required intake context sections.",
                next_step="Fill the required context sections or ask a maintainer to accept the PR intent.",
                label=needs_more_context_label,
                should_comment=True,
                comment_body=build_missing_context_comment(missing_sections, no_code_only=False),
                exit_code=1,
                extra_labels=external_extra_labels,
            ),
            details,
        )

    if not linked:
        return (
            Verdict(
                name="needs-issue",
                reason="External non-trivial PR does not include linked Issue or Discussion intent.",
                next_step="Add a linked Issue/Discussion or ask a maintainer to accept the PR intent.",
                label=needs_issue_label,
                should_comment=True,
                comment_body=NEEDS_ISSUE_COMMENT,
                exit_code=1,
                extra_labels=external_extra_labels,
            ),
            details,
        )

    return (
        Verdict(
            name="pass",
            reason="External non-trivial PR includes required context, linked intent, and avoids configured high-risk paths.",
            next_step="Code review can proceed.",
            label=pass_label,
            should_comment=False,
            comment_body=None,
            exit_code=0,
            extra_labels=external_extra_labels,
        ),
        details,
    )


def main() -> int:
    try:
        config = load_minimal_yaml(CONFIG_PATH)
        event = load_event()
        ctx = get_pr_context(event)
        author_permission = resolve_author_permission(ctx)
        files = load_changed_files(ctx)
        verdict, details = determine_verdict(ctx, config, files, author_permission)

        run_optional_side_effect("label sync", lambda: sync_labels(ctx, config, verdict.label, verdict.extra_labels))
        marker = str(details["marker"])
        if verdict.should_comment and verdict.comment_body:
            run_optional_side_effect("comment upsert", lambda: upsert_comment(ctx, marker, verdict.comment_body))
        elif verdict.exit_code == 0:
            run_optional_side_effect("comment update", lambda: update_existing_gate_comment(ctx, marker, PASS_COMMENT))

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
