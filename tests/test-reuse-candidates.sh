#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT_DIR/scripts/build_codebase_index.py"
MATCHER="$ROOT_DIR/scripts/build_reuse_candidates.py"
FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/basic-mixed"
GO_FIXTURE="$ROOT_DIR/tests/fixtures/codebase-awareness/go-basic"
CONTRACTS="$ROOT_DIR/tests/fixtures/codebase-awareness/contracts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

pass() {
  printf '  PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL: %s -- %s\n' "$1" "$2"
  failed=$((failed + 1))
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$name"
  else
    fail "$name" "missing $path"
  fi
}

setup_project() {
  local project="$1"
  cp -R "$FIXTURE" "$project"
  mkdir -p "$project/.signum/contracts/example" "$project/.signum/contracts/python"
  cp "$CONTRACTS/validation-contract.json" "$project/.signum/contracts/example/contract.json"
  cp "$CONTRACTS/validation-contract-engineer.json" "$project/.signum/contracts/example/contract-engineer.json"
  cp "$CONTRACTS/python-test-contract.json" "$project/.signum/contracts/python/contract.json"
}

setup_go_project() {
  local project="$1"
  cp -R "$GO_FIXTURE" "$project"
  mkdir -p "$project/.signum/contracts/go-validation"
  cp "$CONTRACTS/go-validation-contract.json" "$project/.signum/contracts/go-validation/contract.json"
}

run_scanner() {
  local project="$1"
  (
    cd "$project"
    python3 "$SCANNER" \
      --project-root "." \
      --output ".signum/cache/codebase-index-v1.json" \
      --style-output ".signum/cache/style-profile-v1.json" \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

run_matcher() {
  local project="$1"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/example/contract.json" \
      --contract-engineer ".signum/contracts/example/contract-engineer.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/example/reuse_candidates.json" \
      --implementation-context ".signum/contracts/example/implementation_context.json" \
      --max-candidates 8 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

run_go_matcher() {
  local project="$1"
  (
    cd "$project"
    python3 "$MATCHER" \
      --project-root "." \
      --contract ".signum/contracts/go-validation/contract.json" \
      --codebase-index ".signum/cache/codebase-index-v1.json" \
      --style-profile ".signum/cache/style-profile-v1.json" \
      --output ".signum/contracts/go-validation/reuse_candidates.json" \
      --implementation-context ".signum/contracts/go-validation/implementation_context.json" \
      --max-candidates 8 \
      --generated-at "2026-01-01T00:00:00Z"
  )
}

PROJECT_A="$WORK/run-a/basic-mixed"
PROJECT_B="$WORK/run-b/basic-mixed"
mkdir -p "$(dirname "$PROJECT_A")" "$(dirname "$PROJECT_B")"
setup_project "$PROJECT_A"
setup_project "$PROJECT_B"

INDEX_A="$PROJECT_A/.signum/cache/codebase-index-v1.json"
STYLE_A="$PROJECT_A/.signum/cache/style-profile-v1.json"
REUSE_A="$PROJECT_A/.signum/contracts/example/reuse_candidates.json"
CONTEXT_A="$PROJECT_A/.signum/contracts/example/implementation_context.json"
INDEX_B="$PROJECT_B/.signum/cache/codebase-index-v1.json"
STYLE_B="$PROJECT_B/.signum/cache/style-profile-v1.json"
REUSE_B="$PROJECT_B/.signum/contracts/example/reuse_candidates.json"
CONTEXT_B="$PROJECT_B/.signum/contracts/example/implementation_context.json"
PY_REUSE="$PROJECT_A/.signum/contracts/python/reuse_candidates.json"
PY_CONTEXT="$PROJECT_A/.signum/contracts/python/implementation_context.json"
PROJECT_GO="$WORK/go/go-basic"
mkdir -p "$(dirname "$PROJECT_GO")"
setup_go_project "$PROJECT_GO"
GO_REUSE="$PROJECT_GO/.signum/contracts/go-validation/reuse_candidates.json"
GO_CONTEXT="$PROJECT_GO/.signum/contracts/go-validation/implementation_context.json"

echo "=== Scanner prerequisite ==="
if run_scanner "$PROJECT_A"; then
  pass "scanner run A exits 0"
else
  fail "scanner run A exits 0" "command failed"
fi
if run_scanner "$PROJECT_B"; then
  pass "scanner run B exits 0"
else
  fail "scanner run B exits 0" "command failed"
fi
assert_file "codebase index created" "$INDEX_A"
assert_file "style profile created" "$STYLE_A"

echo ""
echo "=== Matcher run ==="
if run_matcher "$PROJECT_A"; then
  pass "matcher run A exits 0"
else
  fail "matcher run A exits 0" "command failed"
fi
if run_matcher "$PROJECT_B"; then
  pass "matcher run B exits 0"
else
  fail "matcher run B exits 0" "command failed"
fi
assert_file "reuse candidates created" "$REUSE_A"
assert_file "implementation context created" "$CONTEXT_A"

echo ""
echo "=== Fixed-time stability ==="
if cmp -s "$INDEX_A" "$INDEX_B"; then
  pass "codebase index is byte-stable with fixed generatedAt"
else
  fail "codebase index is byte-stable with fixed generatedAt" "$(diff -u "$INDEX_A" "$INDEX_B" || true)"
fi

if cmp -s "$STYLE_A" "$STYLE_B"; then
  pass "style profile is byte-stable with fixed generatedAt"
else
  fail "style profile is byte-stable with fixed generatedAt" "$(diff -u "$STYLE_A" "$STYLE_B" || true)"
fi

if cmp -s "$REUSE_A" "$REUSE_B"; then
  pass "reuse candidates are byte-stable with fixed generatedAt"
else
  fail "reuse candidates are byte-stable with fixed generatedAt" "$(diff -u "$REUSE_A" "$REUSE_B" || true)"
fi

if cmp -s "$CONTEXT_A" "$CONTEXT_B"; then
  pass "implementation context is byte-stable with fixed generatedAt"
else
  fail "implementation context is byte-stable with fixed generatedAt" "$(diff -u "$CONTEXT_A" "$CONTEXT_B" || true)"
fi

echo ""
echo "=== Matcher artifact contract ==="
if python3 - "$REUSE_A" "$CONTEXT_A" "$WORK" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text())
context = json.loads(Path(sys.argv[2]).read_text())
work = sys.argv[3]
errors = []

required_reuse = (
    "schemaVersion",
    "contractId",
    "generatedAt",
    "maxCandidates",
    "candidateCount",
    "taskIntent",
    "candidates",
)
required_context = (
    "schemaVersion",
    "contractId",
    "generatedAt",
    "goalSummary",
    "primaryLanguages",
    "targetAreas",
    "dominantConventions",
    "candidateSummary",
)
for field in required_reuse:
    if field not in reuse:
        errors.append(f"missing reuse field {field}")
for field in required_context:
    if field not in context:
        errors.append(f"missing context field {field}")
if reuse.get("schemaVersion") != "1.0":
    errors.append("reuse schemaVersion")
if context.get("schemaVersion") != "1.0":
    errors.append("context schemaVersion")
if reuse.get("contractId") != "validation-contract":
    errors.append("contractId")
if reuse.get("candidateCount") != len(reuse.get("candidates", [])):
    errors.append("candidate count mismatch")
if reuse.get("candidateCount", 0) > reuse.get("maxCandidates", 0):
    errors.append("candidateCount exceeds maxCandidates")
if work in json.dumps(reuse) or work in json.dumps(context):
    errors.append("matcher artifacts leaked temp project path")

strong_terms = (
    "symbol",
    "imported",
    "paired test",
    "shared candidate",
    "exported symbol",
    "existing test",
    "style profile",
    "referenced by local import",
)
for index, candidate in enumerate(reuse.get("candidates", []), start=1):
    if candidate.get("candidateId") != f"cand-{index:03d}":
        errors.append("candidate IDs are not deterministic")
    if not candidate.get("kind"):
        errors.append(f"{candidate.get('candidateId')} missing kind")
    if not isinstance(candidate.get("score"), (int, float)):
        errors.append(f"{candidate.get('candidateId')} missing numeric score")
    elif round(candidate["score"], 4) != candidate["score"]:
        errors.append(f"{candidate.get('candidateId')} score not rounded")
    if not isinstance(candidate.get("confidence"), (int, float)):
        errors.append(f"{candidate.get('candidateId')} missing numeric confidence")
    elif round(candidate["confidence"], 4) != candidate["confidence"]:
        errors.append(f"{candidate.get('candidateId')} confidence not rounded")
    if not candidate.get("whyRelevant"):
        errors.append(f"{candidate.get('candidateId')} has empty whyRelevant")
    if not candidate.get("suggestedAction"):
        errors.append(f"{candidate.get('candidateId')} missing suggestedAction")
    source = candidate.get("source")
    if not isinstance(source, dict) or not source.get("artifact") or not source.get("section"):
        errors.append(f"{candidate.get('candidateId')} missing stable source")
    if index <= 3 and len(candidate.get("whyRelevant", [])) < 2:
        errors.append(f"{candidate.get('candidateId')} top candidate has too little evidence")
    why = " ".join(candidate.get("whyRelevant", [])).lower()
    if candidate.get("score", 0) >= 0.5 and not any(term in why for term in strong_terms):
        errors.append(f"{candidate.get('candidateId')} ranks highly without real evidence")

top = reuse.get("candidates", [{}])[0]
top_why = " ".join(top.get("whyRelevant", [])).lower()
if top.get("path") != "src/shared/validation.ts" or top.get("kind") != "existing-helper":
    errors.append("top validation candidate is not the shared validation helper")
if not any(term in top_why for term in ("symbol", "imported", "paired test", "shared candidate")):
    errors.append("top validation candidate lacks real evidence")

validation_helpers = [
    candidate for candidate in reuse.get("candidates", [])
    if candidate.get("kind") == "existing-helper"
    and candidate.get("path") == "src/shared/validation.ts"
    and candidate.get("symbol") in {"validateEmail", "normalizeEmail"}
]
if not validation_helpers:
    errors.append("validation helper candidate not surfaced")
tests = context.get("dominantConventions", {}).get("tests", [])
if not tests:
    errors.append("test conventions missing from implementation context")
if not any("*.test.*" in item or "test_*.py" in item for item in tests):
    errors.append("expected test convention pattern missing")
summary = context.get("candidateSummary", {})
if summary.get("total") != reuse.get("candidateCount"):
    errors.append("candidate summary total mismatch")
if not context.get("nearbyModules"):
    errors.append("nearby modules missing")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "matcher schema, privacy, and candidate quality are valid"
else
  fail "matcher schema, privacy, and candidate quality are valid" "Python assertion failed"
fi

echo ""
echo "=== Missing input handling ==="
if (
  cd "$PROJECT_A"
  python3 "$MATCHER" \
    --project-root "." \
    --contract ".signum/contracts/example/contract.json" \
    --codebase-index ".signum/cache/codebase-index-v1.json" \
    --style-profile ".signum/cache/missing-style-profile-v1.json" \
    --output ".signum/contracts/example/missing/reuse_candidates.json" \
    --implementation-context ".signum/contracts/example/missing/implementation_context.json" \
    --generated-at "2026-01-01T00:00:00Z"
) >/dev/null 2>"$WORK/missing-style.stderr"; then
  fail "matcher fails on missing required style profile" "expected non-zero exit"
else
  if grep -q "Required style-profile JSON not found" "$WORK/missing-style.stderr"; then
    pass "matcher fails on missing required style profile"
  else
    fail "matcher fails on missing required style profile" "$(cat "$WORK/missing-style.stderr")"
  fi
fi

echo ""
echo "=== Secondary contract ==="
if (
  cd "$PROJECT_A"
  python3 "$MATCHER" \
    --project-root "." \
    --contract ".signum/contracts/python/contract.json" \
    --codebase-index ".signum/cache/codebase-index-v1.json" \
    --style-profile ".signum/cache/style-profile-v1.json" \
    --output ".signum/contracts/python/reuse_candidates.json" \
    --implementation-context ".signum/contracts/python/implementation_context.json" \
    --max-candidates 5 \
    --generated-at "2026-01-01T00:00:00Z"
); then
  pass "matcher supports contract without engineer overlay"
else
  fail "matcher supports contract without engineer overlay" "command failed"
fi

if python3 - "$PY_REUSE" "$PY_CONTEXT" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text())
context = json.loads(Path(sys.argv[2]).read_text())
errors = []
if reuse.get("candidateCount", 0) > 5:
    errors.append("python contract max candidates")
if not any(candidate.get("kind") == "test-pattern" and candidate.get("path") == "tests/python_app/test_service.py" for candidate in reuse.get("candidates", [])):
    errors.append("python test-pattern candidate missing")
if not context.get("dominantConventions", {}).get("tests"):
    errors.append("python context test conventions missing")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "secondary python contract surfaces test pattern"
else
  fail "secondary python contract surfaces test pattern" "Python assertion failed"
fi

echo ""
echo "=== Go contract ==="
if run_scanner "$PROJECT_GO"; then
  pass "Go scanner prerequisite exits 0"
else
  fail "Go scanner prerequisite exits 0" "command failed"
fi
if run_go_matcher "$PROJECT_GO"; then
  pass "matcher supports Go validation contract"
else
  fail "matcher supports Go validation contract" "command failed"
fi

if python3 - "$GO_REUSE" "$GO_CONTEXT" <<'PY'
import json
import sys
from pathlib import Path

reuse = json.loads(Path(sys.argv[1]).read_text())
context = json.loads(Path(sys.argv[2]).read_text())
errors = []
candidates = reuse.get("candidates", [])
top = candidates[0] if candidates else {}
if reuse.get("contractId") != "go-validation-contract":
    errors.append("go contractId")
if top.get("path") != "pkg/validation":
    errors.append("top Go candidate should be pkg/validation")
if top.get("kind") not in {"existing-helper", "shared-module"}:
    errors.append("top Go candidate kind")
why = " ".join(top.get("whyRelevant", [])).lower()
for term in ("validation", "shared candidate", "imported", "paired test"):
    if term not in why:
        errors.append(f"missing Go whyRelevant evidence: {term}")
if "pkg/" in why and not any(term in why for term in ("imported", "paired test", "symbol")):
    errors.append("pkg path used without stronger Go evidence")
internal = [candidate for candidate in candidates if candidate.get("path") == "internal/auth"]
if not internal or not any(candidate.get("risks") for candidate in internal):
    errors.append("internal boundary risk missing")
if "go" not in context.get("primaryLanguages", []):
    errors.append("Go primary language missing")
if not context.get("dominantConventions", {}).get("go"):
    errors.append("Go conventions missing")
if not context.get("moduleBoundaries"):
    errors.append("Go module boundaries missing")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "Go contract surfaces validation helper with non-path-only evidence"
else
  fail "Go contract surfaces validation helper with non-path-only evidence" "Python assertion failed"
fi

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "ok: reuse candidates and implementation context are deterministic"
