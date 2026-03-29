#!/usr/bin/env bash
# metric-ratchet.sh -- weekly performance comparison from proofpack archive
# Autoresearch pattern: compute metrics from last N proofpacks, compare to previous period.
# Emit directive on regression.
#
# Usage: metric-ratchet.sh [days_current] [days_previous]
# Default: 7 days current vs 7 days previous
# Output: .signum/metrics/ratchet-report.json
# Exit 0: metrics computed (may include regressions)
# Exit 1: no data available
# Exit 2: usage error

set -euo pipefail

DAYS_CURRENT="${1:-7}"
DAYS_PREVIOUS="${2:-7}"

if ! [[ "$DAYS_CURRENT" =~ ^[0-9]+$ ]] || ! [[ "$DAYS_PREVIOUS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: days_current and days_previous must be positive integers" >&2
  exit 2
fi

METRICS_DIR=".signum/metrics"
ARCHIVE_DIR=".signum/archive"
INDEX_FILE=".signum/proofpack-index.jsonl"
REPORT_FILE="${METRICS_DIR}/ratchet-report.json"

mkdir -p "$METRICS_DIR"

# Collect proofpack data from archive and index
collect_proofpacks() {
  local since_days="$1"
  local cutoff
  cutoff=$(date -u -v-${since_days}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${since_days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  if [ -z "$cutoff" ]; then
    echo "ERROR: date command failed to compute cutoff" >&2
    exit 2
  fi

  # From index file (if exists)
  if [ -f "$INDEX_FILE" ]; then
    jq -c --arg cutoff "$cutoff" 'select(.createdAt >= $cutoff)' "$INDEX_FILE" 2>/dev/null
  fi

  # From archive dirs (fallback)
  for pp in "$ARCHIVE_DIR"/*/proofpack.json; do
    [ -f "$pp" ] || continue
    local created
    created=$(jq -r '.createdAt // ""' "$pp" 2>/dev/null)
    if [ -n "$created" ] && [[ "$created" > "$cutoff" ]]; then
      jq -c '{
        runId: .runId,
        createdAt: .createdAt,
        decision: .decision,
        releaseVerdict: (.releaseVerdict // "HOLD"),
        riskLevel: (.riskLevel // "low"),
        confidence: (.confidence.overall // 0),
        reviewCoverage: (.reviewCoverage.availableReviews // 0)
      }' "$pp" 2>/dev/null
    fi
  done
}

# Compute metrics from a set of proofpack entries (piped as JSONL)
compute_metrics() {
  python3 -c "
import json, sys

all_entries = [json.loads(line) for line in sys.stdin if line.strip()]
seen = set()
entries = []
for e in all_entries:
    rid = e.get('runId', '')
    if rid and rid in seen:
        continue
    seen.add(rid)
    entries.append(e)
if not entries:
    json.dump({'count': 0}, sys.stdout)
    sys.exit(0)

total = len(entries)
auto_ok = sum(1 for e in entries if e.get('decision') == 'AUTO_OK')
auto_block = sum(1 for e in entries if e.get('decision') == 'AUTO_BLOCK')
human_review = sum(1 for e in entries if e.get('decision') == 'HUMAN_REVIEW')
promotes = sum(1 for e in entries if e.get('releaseVerdict') == 'PROMOTE')

confidences = [e.get('confidence', 0) for e in entries if isinstance(e.get('confidence'), (int, float))]
avg_confidence = sum(confidences) / len(confidences) if confidences else 0

reviews = [e.get('reviewCoverage', 0) for e in entries if isinstance(e.get('reviewCoverage'), (int, float))]
avg_reviews = sum(reviews) / len(reviews) if reviews else 0

json.dump({
    'count': total,
    'auto_ok_rate': round(auto_ok / total * 100, 1) if total else 0,
    'auto_block_rate': round(auto_block / total * 100, 1) if total else 0,
    'human_review_rate': round(human_review / total * 100, 1) if total else 0,
    'promote_rate': round(promotes / total * 100, 1) if total else 0,
    'avg_confidence': round(avg_confidence, 1),
    'avg_reviews': round(avg_reviews, 1),
    'auto_ok': auto_ok,
    'auto_block': auto_block,
    'human_review': human_review
}, sys.stdout)
"
}

# Collect current and previous period
CURRENT_DATA=$(collect_proofpacks "$DAYS_CURRENT")
TOTAL_DAYS=$((DAYS_CURRENT + DAYS_PREVIOUS))
PREVIOUS_DATA=$(collect_proofpacks "$TOTAL_DAYS" | python3 - "$DAYS_CURRENT" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta, timezone
cutoff = datetime.now(timezone.utc) - timedelta(days=int(sys.argv[1]))
cutoff_str = cutoff.strftime('%Y-%m-%dT%H:%M:%SZ')
for line in sys.stdin:
    if line.strip():
        e = json.loads(line)
        if e.get('createdAt', '') < cutoff_str:
            print(line.strip())
PYEOF
)

CURRENT_METRICS=$(echo "$CURRENT_DATA" | compute_metrics)
PREVIOUS_METRICS=$(echo "$PREVIOUS_DATA" | compute_metrics)

CURRENT_COUNT=$(echo "$CURRENT_METRICS" | jq -r '.count')
PREVIOUS_COUNT=$(echo "$PREVIOUS_METRICS" | jq -r '.count')

if [ "$CURRENT_COUNT" -eq 0 ] && [ "$PREVIOUS_COUNT" -eq 0 ]; then
  echo "No proofpack data available for comparison" >&2
  exit 1
fi

# Compare and detect regressions
REPORT=$(printf '%s\n%s' "$CURRENT_METRICS" "$PREVIOUS_METRICS" | python3 - "$DAYS_CURRENT" "$DAYS_PREVIOUS" <<'PYEOF'
import json, sys

current = json.loads(sys.stdin.readline())
previous = json.loads(sys.stdin.readline())
regressions = []
improvements = []

def compare(metric, label, higher_is_better=True):
    c = current.get(metric, 0)
    p = previous.get(metric, 0)
    if previous.get('count', 0) == 0:
        return  # no baseline
    delta = c - p
    threshold = 10  # 10 percentage points
    if higher_is_better and delta < -threshold:
        regressions.append({'metric': label, 'current': c, 'previous': p, 'delta': round(delta, 1)})
    elif not higher_is_better and delta > threshold:
        regressions.append({'metric': label, 'current': c, 'previous': p, 'delta': round(delta, 1)})
    elif higher_is_better and delta > threshold:
        improvements.append({'metric': label, 'current': c, 'previous': p, 'delta': round(delta, 1)})
    elif not higher_is_better and delta < -threshold:
        improvements.append({'metric': label, 'current': c, 'previous': p, 'delta': round(delta, 1)})

compare('auto_ok_rate', 'AUTO_OK rate', True)
compare('auto_block_rate', 'AUTO_BLOCK rate', False)
compare('human_review_rate', 'HUMAN_REVIEW rate', False)
compare('avg_confidence', 'Average confidence', True)
compare('promote_rate', 'PROMOTE rate', True)

status = 'regression' if regressions else ('improved' if improvements else 'stable')
days_current = int(sys.argv[1])
days_previous = int(sys.argv[2])

report = {
    'status': status,
    'period': {'current_days': days_current, 'previous_days': days_previous},
    'current': current,
    'previous': previous,
    'regressions': regressions,
    'improvements': improvements
}
print(json.dumps(report, indent=2))
PYEOF
)

echo "$REPORT" > "$REPORT_FILE"

# Output summary
STATUS=$(echo "$REPORT" | jq -r '.status')
echo "Metric ratchet: $STATUS (current: ${CURRENT_COUNT} runs, previous: ${PREVIOUS_COUNT} runs)"

if [ "$STATUS" = "regression" ]; then
  echo "REGRESSIONS:"
  echo "$REPORT" | jq -r '.regressions[] | "  - \(.metric): \(.previous) -> \(.current) (delta: \(.delta))"'
fi

if [ "$STATUS" = "improved" ]; then
  echo "IMPROVEMENTS:"
  echo "$REPORT" | jq -r '.improvements[] | "  - \(.metric): \(.previous) -> \(.current) (delta: \(.delta))"'
fi
