#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
RUN_ID="test-run"
EXTERNAL_RUN_ID="test-run-external-config"
RUN_DIR="$ROOT_DIR/experiments/signum_evolve/out/$RUN_ID"
EXTERNAL_RUN_DIR="$ROOT_DIR/experiments/signum_evolve/out/$EXTERNAL_RUN_ID"
EXPORT_DIR="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$EXPORT_DIR" "$WORK"; rm -rf "$RUN_DIR" "$EXTERNAL_RUN_DIR"' EXIT

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-scanner.sh")
CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-rules.json")
OVERLAY_SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh")
OVERLAY_CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-rules.json")

rm -rf "$RUN_DIR" "$EXTERNAL_RUN_DIR"
mkdir -p "$RUN_DIR/candidates/cand_999999"
cat > "$RUN_DIR/candidates/cand_999999/candidate.json" <<'JSON'
{"candidateId":"cand_999999","mutation":{}}
JSON
cat > "$RUN_DIR/candidates/cand_999999/compare.json" <<'JSON'
{"decision":"review","hardGatePassed":true,"improvements":[],"regressions":[],"status":"equivalent"}
JSON

python3 -m experiments.signum_evolve.cli generate \
  --repo-root "$ROOT_DIR" \
  --config experiments/signum_evolve/configs/evolve.v0.json \
  --run-id "$RUN_ID" \
  --max-candidates 1 \
  --seed 42 \
  > "$WORK/generate.json"

test -f "$RUN_DIR/run_manifest.json"
test -f "$RUN_DIR/leaderboard.json"
test ! -e "$RUN_DIR/candidates/cand_999999"
python3 -m json.tool "$RUN_DIR/run_manifest.json" >/dev/null
python3 -m json.tool "$RUN_DIR/leaderboard.json" >/dev/null
jq -e '.candidateCount == 1' "$RUN_DIR/run_manifest.json" >/dev/null

CANDIDATE_COUNT=$(jq '.candidates | length' "$RUN_DIR/leaderboard.json")
if [ "$CANDIDATE_COUNT" -ne 1 ]; then
  echo "expected exactly one generated candidate after run reset" >&2
  exit 1
fi

CANDIDATE_ID=$(jq -r '.candidates[0].candidateId' "$RUN_DIR/leaderboard.json")
CANDIDATE_DIR="$RUN_DIR/candidates/$CANDIDATE_ID"
for file in candidate.json policy-rules.json eval.json compare.json; do
  test -f "$CANDIDATE_DIR/$file"
  python3 -m json.tool "$CANDIDATE_DIR/$file" >/dev/null
done

jq -e '.summary | has("hardGatePassed")' "$CANDIDATE_DIR/eval.json" >/dev/null
jq -e 'has("decision") and has("status") and has("regressions") and has("improvements")' "$CANDIDATE_DIR/compare.json" >/dev/null

python3 -m experiments.signum_evolve.cli leaderboard \
  --run "$RUN_DIR" \
  > "$WORK/leaderboard.json"
python3 -m json.tool "$WORK/leaderboard.json" >/dev/null

python3 -m experiments.signum_evolve.cli export \
  --run "$RUN_DIR" \
  --candidate "$CANDIDATE_ID" \
  --out "$EXPORT_DIR/adoption-bundle" \
  > "$WORK/export.json"

for file in candidate.json policy-rules.candidate.json eval.json compare.json report.md adoption-checklist.md; do
  test -f "$EXPORT_DIR/adoption-bundle/$file"
done

python3 - "$ROOT_DIR/evals/policy_scanner/baselines/current.json" "$WORK/custom-baseline.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
metrics = data["metrics"]
metrics["precision"] = 0.9
metrics["f1"] = 0.9
metrics["falsePositives"] = 1
metrics["knownBaselineFailures"] = 1
target.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

cat > "$WORK/external-config.json" <<JSON
{
  "allowedPrefixes": [
    "docs/",
    "examples/",
    "fixtures/",
    "tests/",
    "test/",
    "generated/"
  ],
  "baselineCatalog": "lib/policy-rules.json",
  "baselineScorecard": "$WORK/custom-baseline.json",
  "operators": [
    "add_excluded_path_prefix"
  ],
  "schemaVersion": "1.0"
}
JSON

python3 -m experiments.signum_evolve.cli generate \
  --repo-root "$ROOT_DIR" \
  --config "$WORK/external-config.json" \
  --run-id "$EXTERNAL_RUN_ID" \
  --max-candidates 1 \
  --seed 42 \
  > "$WORK/generate-external.json"

test -f "$EXTERNAL_RUN_DIR/run_manifest.json"
test -f "$EXTERNAL_RUN_DIR/candidates/cand_000001/compare.json"
python3 -m json.tool "$EXTERNAL_RUN_DIR/run_manifest.json" >/dev/null
jq -e '.config == "external:external-config.json"' "$EXTERNAL_RUN_DIR/run_manifest.json" >/dev/null
jq -e '.status == "better" and .decision == "accept"' "$EXTERNAL_RUN_DIR/candidates/cand_000001/compare.json" >/dev/null
jq -e '.improvements[] | select(.metric == "falsePositives")' "$EXTERNAL_RUN_DIR/candidates/cand_000001/compare.json" >/dev/null

if [ "$SCANNER_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/lib/policy-scanner.sh")" ]; then
  echo "root scanner changed during evolve run" >&2
  exit 1
fi
if [ "$CATALOG_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/lib/policy-rules.json")" ]; then
  echo "root policy catalog changed during evolve run" >&2
  exit 1
fi
if [ "$OVERLAY_SCANNER_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh")" ]; then
  echo "overlay scanner changed during evolve run" >&2
  exit 1
fi
if [ "$OVERLAY_CATALOG_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-rules.json")" ]; then
  echo "overlay policy catalog changed during evolve run" >&2
  exit 1
fi

if git -C "$ROOT_DIR" status --short .signum | grep -q .; then
  echo ".signum has tracked or staged changes" >&2
  exit 1
fi

git -C "$ROOT_DIR" check-ignore -q experiments/signum_evolve/out/test-run

echo "signum-evolve v0 smoke passed"
