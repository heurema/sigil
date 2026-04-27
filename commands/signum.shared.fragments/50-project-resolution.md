## Project Resolution

Before setup, determine the correct project directory. The pipeline MUST run in the target project's root, not an unrelated session CWD.

**Resolution order:**

1. If `SIGNUM_PROJECT_ROOT` is set, validate and use it.
2. If the explicit `project` argument is provided, validate and use it.
3. Otherwise, infer the current git repository root with `git rev-parse --show-toplevel`.
4. If no git root exists, use the current directory only. Do not search arbitrary home or sibling directories.

Use the Bash tool to detect and switch to the target project:

```bash
CURRENT_DIR=$(pwd -P)
TARGET_DIR=""

canonicalize_project_root() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "ERROR: project root is not a directory: $dir" >&2
    exit 1
  fi
  (cd "$dir" && pwd -P)
}

# 1. Explicit environment override
if [ -n "${SIGNUM_PROJECT_ROOT:-}" ]; then
  TARGET_DIR=$(canonicalize_project_root "$SIGNUM_PROJECT_ROOT")
  echo "Using SIGNUM_PROJECT_ROOT: $TARGET_DIR"
fi

# 2. Explicit slash-command project argument, if provided
if [ -z "$TARGET_DIR" ]; then
  # TARGET_DIR=$(canonicalize_project_root "<value of project argument>")
  :
fi

# 3. Deterministic git-root fallback from the current directory
if [ -z "$TARGET_DIR" ]; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$GIT_ROOT" ]; then
    TARGET_DIR=$(canonicalize_project_root "$GIT_ROOT")
    echo "Using git repository root: $TARGET_DIR"
  fi
fi

# 4. Safe non-git fallback: current directory only
if [ -z "$TARGET_DIR" ]; then
  TARGET_DIR="$CURRENT_DIR"
  echo "WARNING: No git repository root detected. Using current directory only: $TARGET_DIR" >&2
fi

PROJECT_ROOT="$TARGET_DIR"
export PROJECT_ROOT
echo "PROJECT_DIR=$PROJECT_ROOT"
```

If `PROJECT_ROOT` differs from `CURRENT_DIR`, use `cd "$PROJECT_ROOT"` in ALL subsequent Bash tool calls, or prefix commands with `cd "$PROJECT_ROOT" &&`.

