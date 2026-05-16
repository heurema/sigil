#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
RUN_ID="test-v1"
RUN_DIR="$ROOT_DIR/experiments/signum_evolve/out/$RUN_ID"
WORK="$(mktemp -d)"
EXPORT_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK" "$EXPORT_DIR"; rm -rf "$RUN_DIR"' EXIT

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-scanner.sh")
CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/lib/policy-rules.json")
OVERLAY_SCANNER_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh")
OVERLAY_CATALOG_HASH_BEFORE=$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-rules.json")

rm -rf "$RUN_DIR"

cat > "$WORK/evolve-v1-test.json" <<'JSON'
{
  "allowedPrefixes": [
    "docs/",
    "examples/"
  ],
  "baselineCatalog": "lib/policy-rules.json",
  "baselineScorecard": "evals/policy_scanner/baselines/current.json",
  "maxMutationDepth": 2,
  "operators": [
    "add_excluded_path_prefix"
  ],
  "schemaVersion": "1.0"
}
JSON

python3 -m experiments.signum_evolve.cli generate \
  --repo-root "$ROOT_DIR" \
  --config "$WORK/evolve-v1-test.json" \
  --run-id "$RUN_ID" \
  --max-candidates 3 \
  --seed 42 \
  > "$WORK/generate.json"

test -f "$RUN_DIR/run_manifest.json"
test -f "$RUN_DIR/leaderboard.json"
python3 -m json.tool "$RUN_DIR/run_manifest.json" >/dev/null
python3 -m json.tool "$RUN_DIR/leaderboard.json" >/dev/null
jq -e '.candidateCount == 3 and .maxMutationDepth == 2' "$RUN_DIR/run_manifest.json" >/dev/null
jq -e '.config == "external:evolve-v1-test.json"' "$RUN_DIR/run_manifest.json" >/dev/null

for candidate in cand_000001 cand_000002 cand_000003; do
  candidate_dir="$RUN_DIR/candidates/$candidate"
  for file in candidate.json policy-rules.json catalog_diff.json eval.json compare.json; do
    test -f "$candidate_dir/$file"
    python3 -m json.tool "$candidate_dir/$file" >/dev/null
  done
done

MULTI="$RUN_DIR/candidates/cand_000003"
jq -e '.mutation.operator == "add_excluded_path_prefix_set"' "$MULTI/candidate.json" >/dev/null
jq -e '.mutationCount == 2 and (.mutations | length == 2)' "$MULTI/candidate.json" >/dev/null
jq -e '.mutation.prefixes == ["docs/", "examples/"]' "$MULTI/candidate.json" >/dev/null
jq -e '.changes[0].ruleId == "POLICY_WEAK_CRYPTO"' "$MULTI/catalog_diff.json" >/dev/null
jq -e '.changes[0].addedExcludedPathPrefixes == ["docs/", "examples/"]' "$MULTI/catalog_diff.json" >/dev/null
jq -e '.criticalRuleChangesCount == 0' "$MULTI/catalog_diff.json" >/dev/null

jq -e '.candidates | length == 3' "$RUN_DIR/leaderboard.json" >/dev/null
jq -e '.candidates[0] | has("rank") and has("score") and has("catalogDiff") and has("mutationCount")' "$RUN_DIR/leaderboard.json" >/dev/null
jq -e '[.candidates[].rank] == [1, 2, 3]' "$RUN_DIR/leaderboard.json" >/dev/null
jq -e '.candidates[] | select(.candidateId == "cand_000003") | .mutationCount == 2' "$RUN_DIR/leaderboard.json" >/dev/null
jq -e '.candidates[] | select(.candidateId == "cand_000003") | .catalogDiff.changedRuleCount == 1' "$RUN_DIR/leaderboard.json" >/dev/null

python3 -m experiments.signum_evolve.cli export \
  --run "$RUN_DIR" \
  --candidate cand_000003 \
  --out "$EXPORT_DIR/adoption-bundle" \
  > "$WORK/export.json"

for file in candidate.json policy-rules.candidate.json catalog_diff.json eval.json compare.json report.md adoption-checklist.md; do
  test -f "$EXPORT_DIR/adoption-bundle/$file"
done

grep -Fq "## Catalog Diff" "$EXPORT_DIR/adoption-bundle/report.md"
grep -Fq "Changed rules: \`1\`" "$EXPORT_DIR/adoption-bundle/report.md"
grep -Fq "POLICY_WEAK_CRYPTO" "$EXPORT_DIR/adoption-bundle/report.md"
grep -Fq "Catalog diff reviewed" "$EXPORT_DIR/adoption-bundle/adoption-checklist.md"

if [ "$SCANNER_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/lib/policy-scanner.sh")" ]; then
  echo "root scanner changed during v1 evolve run" >&2
  exit 1
fi
if [ "$CATALOG_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/lib/policy-rules.json")" ]; then
  echo "root policy catalog changed during v1 evolve run" >&2
  exit 1
fi
if [ "$OVERLAY_SCANNER_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-scanner.sh")" ]; then
  echo "overlay scanner changed during v1 evolve run" >&2
  exit 1
fi
if [ "$OVERLAY_CATALOG_HASH_BEFORE" != "$(hash_file "$ROOT_DIR/platforms/claude-code/lib/policy-rules.json")" ]; then
  echo "overlay policy catalog changed during v1 evolve run" >&2
  exit 1
fi

if git -C "$ROOT_DIR" status --short .signum | grep -q .; then
  echo ".signum has tracked or staged changes" >&2
  exit 1
fi

git -C "$ROOT_DIR" check-ignore -q experiments/signum_evolve/out/test-v1

echo "signum-evolve v1 smoke passed"
