# Nested entrypoint at depth 2 inside commands/

This file lives at `commands/nested-group/run.md` (3 path parts from repo root)
to exercise the historical `find -maxdepth 2` semantics: scanner must include
files one directory below the entrypoint dir.
