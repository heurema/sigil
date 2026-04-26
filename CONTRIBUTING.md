# Contributing to Signum

Thanks for your interest in contributing.

Signum is an **experimental** contract-first development pipeline with a mix of:
- prompt/orchestration surfaces in `commands/` and `agents/`;
- deterministic shell logic in `lib/`;
- compatibility-sensitive schemas in `lib/schemas/`;
- tests and docs that explain trust boundaries and expected behavior.

Good contributions keep those surfaces aligned and avoid widening scope silently.

## Read this first

Before opening a non-trivial issue or pull request, read:

1. `README.md`
2. `AGENTS.md`
3. `QUICKSTART.md`
4. `docs/how-it-works.md`
5. `docs/reference.md`
6. `docs/SECURITY.md`

Then read the exact files you are changing.

## Useful contribution areas right now

- bounded fixes to deterministic pipeline behavior in `lib/`;
- test coverage for bug fixes and compatibility-sensitive logic;
- docs clarifications where runtime behavior and docs drift;
- repo hygiene and contributor experience improvements;
- tightly scoped improvements to `/signum:init`, harness scaffolding, and release guardrails.

## Ground rules

### 1) Keep changes bounded

Prefer one clear purpose per PR.

The repo already distinguishes three major change classes:
- docs-only;
- deterministic core / compatibility;
- prompt / orchestration behavior.

Do not mix all three unless the change is impossible to split.

### 2) Respect canonical surfaces

Use these source-of-truth rules:
- `commands/signum.md` is the canonical pipeline surface;
- `commands/init.md` is the canonical init/bootstrap surface;
- `platforms/*/commands/*.md` are overlays, not peer sources of truth;
- `lib/` is the deterministic core;
- `lib/schemas/` changes are compatibility-sensitive.

If behavior changes, update the matching docs or tests in the same PR.

### 3) Prefer deterministic fixes over more prompt complexity

If a problem can be solved in `lib/`, schemas, or tests, prefer that over pushing more logic into prompts.

### 4) Do not present experimental behavior as stable

Signum is explicitly experimental software.
Do not make stronger claims in docs, PR text, or release notes than the repo actually supports.

### 5) Treat release wiring as sensitive

Marketplace sync and release guardrails are part of the install path.
Changes under `.claude-plugin/`, `.github/workflows/release-guardrails.yml`, `lib/update-emporium-marketplace.sh`, or `lib/release-smoke.sh` need extra care and validation.

## Validation expectations

Bring proof for every meaningful change.

Examples:
- `bash tests/run.sh`
- targeted shell tests such as `bash tests/test-doc-parity.sh`
- targeted fixture/eval runs such as `python3 evals/run.py`
- before/after command output
- doc walkthrough for docs-only changes

For deterministic bug fixes, a failing test first is strongly preferred.


## PR Intake Gate

This repository uses a deterministic PR Intake Gate before ordinary code review.

For non-trivial changes, open an Issue or Discussion first and link it from the PR body. The intent should explain:
- the problem;
- the expected outcome;
- why existing behavior/options are insufficient;
- alternatives considered;
- why this cannot be solved without code.

Direct PRs are allowed for:
- typo/docs fixes;
- small test-only changes;
- clearly scoped bug fixes;
- maintainer-approved changes.

PRs touching security, auth, dependencies, workflows, public APIs, install scripts, schemas, command behavior, or runtime behavior require maintainer attention.

Maintainers can bypass the intake gate with the `maintainer/override-intake` label. Use that label only when taking explicit responsibility for reviewing the PR without the normal intake path.

### PR Intake Gate self-check

Expected behavior:
- docs-only PR: passes and receives `intake/pass`;
- non-trivial PR without linked Issue/Discussion: fails with `intake/needs-issue` and a short bot comment;
- PR touching `.github/workflows/**`: fails with `intake/high-risk` and a maintainer-review comment;
- PR with `maintainer/override-intake`: passes.

Local deterministic checks:

```bash
python3 -m py_compile scripts/pr_intake_gate.py
bash tests/test-pr-intake-gate.sh
```


## Commit sign-off (DCO)

This repository uses the **Developer Certificate of Origin (DCO)** instead of a CLA.

Sign off every commit:

```bash
git commit -s -m "Your message"
```

That adds:

```text
Signed-off-by: Your Name <you@example.com>
```

By doing so, you certify the terms in `DCO.md`.

## Pull request expectations

Please use the PR template and include:
- the goal / intent;
- explicit scope boundaries;
- sensitive surfaces touched;
- docs impact;
- validation / proof;
- reviewer notes for risky paths.

## Security

Do **not** report vulnerabilities in public issues.
See `SECURITY.md` for the reporting process.

For deeper trust-boundary context, see `docs/SECURITY.md`.

## Code of conduct

By participating in this project, you agree to follow `CODE_OF_CONDUCT.md`.
