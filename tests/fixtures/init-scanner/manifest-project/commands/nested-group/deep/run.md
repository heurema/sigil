# Too deep — must be excluded.

This file lives at `commands/nested-group/deep/run.md` (4 path parts from repo
root). Historical `find -maxdepth 2` from `commands/` excludes it. The scanner
must keep it out of `signals.entrypoints`.
