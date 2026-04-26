# Signum Copilot Review Instructions

Review code only after the PR intake gate is satisfied (`intake/pass` or maintainer override). If intake is not satisfied, focus on the missing intent/risk signal instead of detailed code style.

Priorities, in order:
1. Correctness and regressions.
2. Security and trust boundaries.
3. Maintainability and minimal scope.
4. Minimal dependencies.

Flag risky changes in:
- `.github/workflows/**` and custom GitHub Actions.
- Dependencies, lockfiles, install scripts, Docker files, and release wiring.
- Auth, security, crypto, subprocess/shell/eval, and file-system execution paths.
- Public APIs, schemas, command behavior, and runtime behavior.

Do not recommend new dependencies unless the benefit is explicit and smaller stdlib/built-in options are insufficient.

Do not treat stylistic issues as blockers unless they affect correctness, security, maintainability, or contributor usability.

Keep public review comments concise, polite, and actionable. Do not publish contributor trust scores.

Repo map:
- `commands/signum.md` is the canonical Signum pipeline surface.
- `commands/init.md` is the canonical init/bootstrap surface.
- `agents/` contains LLM prompt surfaces.
- `lib/` contains deterministic behavior.
- `lib/schemas/` is compatibility-sensitive.
- `tests/` contains verification.
