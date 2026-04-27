## Init Command Redirect

If the user's task is using Signum init command syntax instead of a feature request - for example:
- exactly `init`
- `init --force`
- `init --harness`
- `init --project-root <path>`

do NOT run the CONTRACT → EXECUTE → AUDIT → PACK pipeline.

Instead, tell the user:

Use `/signum:init [--force] [--harness] [--project-root <path>]`.

For Claude Code plugin usage, `/signum:init` is the canonical form.
`--harness` requires Signum `>= v4.18.0`.

Then stop.

