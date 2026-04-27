#!/usr/bin/env bash
# test-claude-overlay-runtime-parity.sh -- keep Claude overlay runtime assets aligned with root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAY_ROOT="$REPO_ROOT/platforms/claude-code"

passed=0
failed=0

assert_same_file() {
  local rel="$1"
  if diff -q "$REPO_ROOT/$rel" "$OVERLAY_ROOT/$rel" >/dev/null 2>&1; then
    printf '  PASS: mirror %s\n' "$rel"
    passed=$((passed + 1))
  else
    printf '  FAIL: mirror %s differs\n' "$rel"
    failed=$((failed + 1))
  fi
}

echo "=== Overlay command lib references exist ==="
REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os,re
repo_root = os.environ["REPO_ROOT"]
base = os.path.join(repo_root, "platforms/claude-code")
missing = []
for cmd in ["commands/signum.md", "commands/init.md"]:
    text = open(os.path.join(base, cmd), encoding="utf-8").read()
    refs = sorted(set(re.findall(r'lib/[A-Za-z0-9._/-]+', text)))
    for rel in refs:
        if not os.path.exists(os.path.join(base, rel)):
            missing.append(f"{cmd}: {rel}")
with open(os.path.join(repo_root, ".tmp-overlay-missing.txt"), "w", encoding="utf-8") as f:
    if missing:
        f.write("\\n".join(missing) + "\\n")
PY
if [ ! -s "$REPO_ROOT/.tmp-overlay-missing.txt" ]; then
  printf '  PASS: all referenced overlay libs exist\n'
  passed=$((passed + 1))
else
  printf '  FAIL: missing referenced overlay libs\n'
  cat "$REPO_ROOT/.tmp-overlay-missing.txt"
  failed=$((failed + 1))
fi
rm -f "$REPO_ROOT/.tmp-overlay-missing.txt"

echo ""
echo "=== Overlay runtime mirrors ==="
for rel in \
  "agents/contractor.md" \
  "agents/engineer.md" \
  "agents/reviewer-claude.md" \
  "agents/synthesizer.md" \
  "lib/adr-check.sh" \
  "lib/anti-entropy-report.sh" \
  "lib/assumption-check.sh" \
  "lib/boundary-verifier.sh" \
  "lib/dsl-runner.sh" \
  "lib/glossary-check.sh" \
  "lib/init-harness-scaffold.sh" \
  "lib/init-scanner.sh" \
  "lib/templates/init-harness/agents.md.tmpl" \
  "lib/templates/init-harness/architecture.md.tmpl" \
  "lib/templates/init-harness/plans.md.tmpl" \
  "lib/templates/init-harness/reliability.md.tmpl" \
  "lib/templates/init-harness/security.md.tmpl" \
  "lib/templates/init-harness/quality-score.md.tmpl" \
  "lib/overlap-check.sh" \
  "lib/pack-anti-entropy.sh" \
  "lib/policy-rules.json" \
  "lib/policy-scanner.sh" \
  "lib/prompts/review-template.md" \
  "lib/prompts/review-template-security.md" \
  "lib/prompts/review-template-performance.md" \
  "lib/schemas/contract.schema.json" \
  "lib/schemas/modules.schema.json" \
  "lib/schemas/proofpack.schema.json" \
  "lib/signum-ci.sh" \
  "lib/snapshot-tree.sh" \
  "lib/staleness-check.sh" \
  "lib/terminology-check.sh" \
  "lib/tool-versions.env" \
  "lib/transition-verifier.sh" \
  "scripts/init_scanner.py" \
  "scripts/render_signum_command.py" \
  "scripts/validate_proofpack.py"
do
  assert_same_file "$rel"
done

echo ""
echo "Passed: $passed"
echo "Failed: $failed"

if [ "$failed" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
fi
