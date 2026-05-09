#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
RUN_ID="test-run"
RUN_DIR="$ROOT_DIR/experiments/signum_evolve/out/$RUN_ID"
EXPORT_DIR="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$EXPORT_DIR" "$WORK"; rm -rf "$RUN_DIR"' EXIT

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-scanner.sh")
CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-rules.json")
OVERLAY_SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh")
OVERLAY_CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-rules.json")

rm -rf "$RUN_DIR"

python3 -m experiments.signum_evolve.cli generate \
  --repo-root "$ROOT_DIR" \
  --config experiments/signum_evolve/configs/evolve.v0.json \
  --run-id "$RUN_ID" \
  --max-candidates 3 \
  --seed 42 \
  > "$WORK/generate.json"

test -f "$RUN_DIR/run_manifest.json"
test -f "$RUN_DIR/leaderboard.json"
python3 -m json.tool "$RUN_DIR/run_manifest.json" >/dev/null
python3 -m json.tool "$RUN_DIR/leaderboard.json" >/dev/null

CANDIDATE_COUNT=$(jq '.candidates | length' "$RUN_DIR/leaderboard.json")
if [ "$CANDIDATE_COUNT" -lt 1 ]; then
  echo "expected at least one generated candidate" >&2
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
