#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
RUN_ID="test-replay"
MISSING_RUN_ID="test-replay-missing"
RUN_DIR="$ROOT_DIR/experiments/signum_evolve/out/$RUN_ID"
MISSING_RUN_DIR="$ROOT_DIR/experiments/signum_evolve/out/$MISSING_RUN_ID"
WORK="$(mktemp -d)"
EXPORT_DIR="$(mktemp -d)"
HISTORICAL_ROOT="$WORK/history"
MISSING_ROOT="$WORK/missing-history"
trap 'rm -rf "$WORK" "$EXPORT_DIR"; rm -rf "$RUN_DIR" "$MISSING_RUN_DIR"' EXIT

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-scanner.sh")
CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-rules.json")
OVERLAY_SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh")
OVERLAY_CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-rules.json")

rm -rf "$RUN_DIR" "$MISSING_RUN_DIR"

python3 -m experiments.signum_evolve.cli generate \
  --repo-root "$ROOT_DIR" \
  --config experiments/signum_evolve/configs/evolve.v0.json \
  --run-id "$MISSING_RUN_ID" \
  --max-candidates 1 \
  --seed 42 \
  --historical-root "$MISSING_ROOT" \
  > "$WORK/generate-missing.json"

MISSING_REPLAY="$MISSING_RUN_DIR/candidates/cand_000001/historical_replay.json"
test -f "$MISSING_REPLAY"
python3 -m json.tool "$MISSING_REPLAY" >/dev/null
jq -e '.status == "skipped" and .reason == "missing_root"' "$MISSING_REPLAY" >/dev/null
jq -e '.candidates[0].historicalReplay.status == "skipped"' "$MISSING_RUN_DIR/leaderboard.json" >/dev/null

mkdir -p "$HISTORICAL_ROOT/sig-clean" "$HISTORICAL_ROOT/sig-weak-docs"
cat > "$HISTORICAL_ROOT/sig-clean/combined.patch" <<'PATCH'
diff --git a/src/readme.txt b/src/readme.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/src/readme.txt
@@ -0,0 +1 @@
+plain text with no scanner finding
PATCH

cat > "$HISTORICAL_ROOT/sig-weak-docs/combined.patch" <<'PATCH'
diff --git a/docs/legacy.py b/docs/legacy.py
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/docs/legacy.py
@@ -0,0 +1,2 @@
+import hashlib
+digest = hashlib.md5(data).hexdigest()
PATCH

python3 -m experiments.signum_evolve.cli generate \
  --repo-root "$ROOT_DIR" \
  --config experiments/signum_evolve/configs/evolve.v0.json \
  --run-id "$RUN_ID" \
  --max-candidates 1 \
  --seed 42 \
  --historical-root "$HISTORICAL_ROOT" \
  > "$WORK/generate.json"

REPLAY="$RUN_DIR/candidates/cand_000001/historical_replay.json"
test -f "$REPLAY"
python3 -m json.tool "$REPLAY" >/dev/null
jq -e '.status == "ok"' "$REPLAY" >/dev/null
jq -e '.itemCount == 2' "$REPLAY" >/dev/null
jq -e '.removedFindingsCount == 1' "$REPLAY" >/dev/null
jq -e '.removedCriticalFindingsCount == 0' "$REPLAY" >/dev/null
jq -e '.items | length == 2' "$REPLAY" >/dev/null
jq -e '.items[] | select(.contractId == "sig-weak-docs") | .removedFindings[] | select(.ruleId == "POLICY_WEAK_CRYPTO")' "$REPLAY" >/dev/null

if grep -Fq "$WORK" "$REPLAY"; then
  echo "historical replay output contains absolute temporary path" >&2
  exit 1
fi
jq -e '.items[].patchPath | startswith("external:")' "$REPLAY" >/dev/null

jq -e '.candidates[0].historicalReplay.itemCount == 2' "$RUN_DIR/leaderboard.json" >/dev/null
jq -e '.candidates[0].historicalReplay.removedFindingsCount == 1' "$RUN_DIR/leaderboard.json" >/dev/null

python3 -m experiments.signum_evolve.cli export \
  --run "$RUN_DIR" \
  --candidate cand_000001 \
  --out "$EXPORT_DIR/adoption-bundle" \
  > "$WORK/export.json"

test -f "$EXPORT_DIR/adoption-bundle/historical_replay.json"
grep -Fq "## Historical Replay" "$EXPORT_DIR/adoption-bundle/report.md"
grep -Fq "Removed findings: \`1\`" "$EXPORT_DIR/adoption-bundle/report.md"
grep -Fq "Review required: historical replay drift is a review signal" "$EXPORT_DIR/adoption-bundle/report.md"
grep -Fq "Historical replay reviewed" "$EXPORT_DIR/adoption-bundle/adoption-checklist.md"
grep -Fq "Removed critical findings checked" "$EXPORT_DIR/adoption-bundle/adoption-checklist.md"
grep -Fq "Drift accepted by maintainer" "$EXPORT_DIR/adoption-bundle/adoption-checklist.md"

jq '.decision = "accept" | .status = "better" | .hardGatePassed = true' \
  "$RUN_DIR/candidates/cand_000001/compare.json" > "$WORK/compare-critical.json"
mv "$WORK/compare-critical.json" "$RUN_DIR/candidates/cand_000001/compare.json"
jq '.removedCriticalFindingsCount = 1 | .removedFindingsCount = 1' \
  "$RUN_DIR/candidates/cand_000001/historical_replay.json" > "$WORK/replay-critical.json"
mv "$WORK/replay-critical.json" "$RUN_DIR/candidates/cand_000001/historical_replay.json"

python3 - "$RUN_DIR/candidates/cand_000001" > "$WORK/leaderboard-critical.json" <<'PY'
import sys
from pathlib import Path

from experiments.signum_evolve.candidate import canonical_json
from experiments.signum_evolve.report import leaderboard_entry

sys.stdout.write(canonical_json({"candidates": [leaderboard_entry(Path(sys.argv[1]))]}))
PY

jq -e '.candidates[0].decision == "review"' "$WORK/leaderboard-critical.json" >/dev/null
jq -e '.candidates[0].historicalReplay.removedCriticalFindingsCount == 1' "$WORK/leaderboard-critical.json" >/dev/null

python3 -m experiments.signum_evolve.cli export \
  --run "$RUN_DIR" \
  --candidate cand_000001 \
  --out "$EXPORT_DIR/critical-adoption-bundle" \
  > "$WORK/export-critical.json"

grep -Fq "Decision: \`review\`" "$EXPORT_DIR/critical-adoption-bundle/report.md"
grep -Fq "Removed critical findings: \`1\`" "$EXPORT_DIR/critical-adoption-bundle/report.md"

if [ "$SCANNER_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/lib/policy-scanner.sh")" ]; then
  echo "root scanner changed during replay run" >&2
  exit 1
fi
if [ "$CATALOG_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/lib/policy-rules.json")" ]; then
  echo "root policy catalog changed during replay run" >&2
  exit 1
fi
if [ "$OVERLAY_SCANNER_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh")" ]; then
  echo "overlay scanner changed during replay run" >&2
  exit 1
fi
if [ "$OVERLAY_CATALOG_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-rules.json")" ]; then
  echo "overlay policy catalog changed during replay run" >&2
  exit 1
fi

if git -C "$ROOT_DIR" status --short .signum | grep -q .; then
  echo ".signum has tracked or staged changes" >&2
  exit 1
fi

git -C "$ROOT_DIR" check-ignore -q experiments/signum_evolve/out/test-replay

echo "signum-evolve replay smoke passed"
