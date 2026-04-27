---
status: draft
owner: @vi
last_reviewed: 2026-04-26
review_cadence: quarterly
---

# Init Scanner Behavior Baseline

This document freezes the current init scanner behavior after the Python compatibility rewrite.
It is descriptive, not aspirational.

## CLI

```bash
bash lib/init-scanner.sh [--project-root <path>]
```

- `lib/init-scanner.sh` is a thin compatibility wrapper around `scripts/init_scanner.py`.
- Default `--project-root` is `.`.
- Unknown arguments fail with exit code `1` and an error on stderr.
- Missing or invalid project root fails before scanning.
- For public wrapper compatibility with the historical shell implementation, `jq` is still checked by `lib/init-scanner.sh`. If missing, the wrapper prints `{"error":"jq not found"}` to stderr and exits non-zero.
- The Python implementation itself uses only the Python standard library.

## Output

The scanner writes JSON to stdout and does not write project files.
Successful output shape:

```json
{
  "schemaVersion": "1.0",
  "scanTarget": "<absolute project root>",
  "signals": {
    "authoritative_docs": "...",
    "docs_deep": "...",
    "claude_md": "...",
    "agents_md": "...",
    "readme": "...",
    "package_json": "...",
    "pyproject_toml": "...",
    "cargo_toml": "...",
    "go_mod": "...",
    "ci_signals": "...",
    "entrypoints": "...",
    "console_scripts": "...",
    "pkg_bin": "...",
    "git_dirstat": "...",
    "git_recent": "...",
    "adr_signals": "...",
    "readme_negative": "...",
    "claude_negative": "...",
    "module_dirs": "..."
  },
  "existingFiles": {
    "glossary": {"path": "...", "content": "..."},
    "intent": {"path": "...", "content": "..."}
  },
  "glossarySchema": {
    "canonicalTerms": [],
    "aliases": {}
  }
}
```

Sparse projects still exit `0`; missing optional files become empty strings.

## Scanned Inputs

Current signal sources:

- Authoritative docs, first 300 lines each:
  - `docs/how-it-works.md`
  - `ARCHITECTURE.md`
  - `docs/architecture.md`
  - `docs/reference.md`
  - `docs/design.md`
- Deep docs scan, first 100 lines per file, up to 30 markdown files under `docs/`, excluding files named `how-it-works.md` and ignored paths.
- Convention files:
  - `CLAUDE.md`, first 300 lines
  - `AGENTS.md`, first 300 lines
- README candidates, first match only, first 150 lines:
  - `README.md`
  - `README.rst`
  - `README.txt`
  - `README`
- Manifests:
  - `package.json`, first 100 lines
  - `pyproject.toml`, first 100 lines
  - `Cargo.toml`, first 50 lines
  - `go.mod`, first 50 lines
- CI/build signals:
  - `.github/workflows/*.yml`
  - `.github/workflows/*.yaml`
  - `Makefile`
  - `justfile`
  - `Taskfile.yml`
  - `tox.ini`
- Public entrypoint file lists under:
  - `bin/`
  - `commands/`
  - `skills/`
- Script metadata:
  - `[project.scripts]` or `[tool.poetry.scripts]` from `pyproject.toml`
  - `bin` from `package.json`
- Git signals when the project is inside a git repository:
  - six-month `git log --dirstat=files`
  - six-month recent commit messages
- Negative signals:
  - rejected/deprecated/superseded ADRs under `docs/adr/`
  - README sections named `Not supported`, `Out of scope`, `Limitations`, `Non-goals`, or similar
  - selected `CLAUDE.md` negative guidance
- Existing files, first found wins:
  - `project.glossary.json`, then `.signum/project.glossary.json`
  - `project.intent.md`, then `.signum/project.intent.md`
- Top-level module directory names from shell glob `*/`, after ignore filtering.

## Ignore Behavior

The ignore list is:

```text
.git
.signum
node_modules
dist
build
.venv
__pycache__
coverage
tests/fixtures
```

The general scan ignores those paths, but explicit existing-file fallback still reads `.signum/project.intent.md` and `.signum/project.glossary.json`.
The `module_dirs` signal also excludes the top-level `tests/` directory so test suites are not classified as product/runtime modules.

## Symlinks

The scanner uses `-f` checks for file inputs, so symlinks to regular files are followed by current behavior.
It writes no files and does not resolve symlink targets for reporting.

## Current Limitations

- This is a shell heuristic scanner, not a parser.
- Go checksum files such as `go.sum` are not captured as manifest signals.
- `docs_deep` uses filesystem `find` order; tests normalize section order for golden comparison.
- Git output is environment-dependent; golden tests run fixture copies outside a git repository.
- The output contains large text blobs rather than structured source records.
