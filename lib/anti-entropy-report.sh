#!/usr/bin/env bash
# anti-entropy-report.sh -- report-only anti-entropy findings for completed or near-completed Signum work
# Usage:
#   anti-entropy-report.sh [--project-root <path>] [--contract <path>] [--proofpack <path>] \
#     [--doc-parity-json <path>] [--metric-ratchet-json <path>] [--as-of YYYY-MM-DD] [--output <path>]
#
# Output: JSON to stdout. If --output is provided, also writes the same JSON to that file.
# Exit 0: report generated (status may be ok or warn)
# Exit 1: infra error (bad args, missing jq/python3, unreadable JSON)

set -euo pipefail

PROJECT_ROOT="."
CONTRACT_PATH=""
PROOFPACK_PATH=""
DOC_PARITY_JSON=""
METRIC_RATCHET_JSON=""
AS_OF="$(date +%F)"
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --contract) CONTRACT_PATH="$2"; shift 2 ;;
    --proofpack) PROOFPACK_PATH="$2"; shift 2 ;;
    --doc-parity-json) DOC_PARITY_JSON="$2"; shift 2 ;;
    --metric-ratchet-json) METRIC_RATCHET_JSON="$2"; shift 2 ;;
    --as-of) AS_OF="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v jq > /dev/null 2>&1; then
  echo '{"error":"jq not found"}' >&2
  exit 1
fi
if ! command -v python3 > /dev/null 2>&1; then
  echo '{"error":"python3 not found"}' >&2
  exit 1
fi

cd "$PROJECT_ROOT"
ROOT_ABS="$(pwd)"

abspath_from_root() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$ROOT_ABS" "$path"
  fi
}

resolve_active_artifact_root() {
  local index_path="$ROOT_ABS/.signum/contracts/index.json"
  local active_id=""

  [ -f "$index_path" ] || return 1
  active_id="$(jq -r '.activeContractId // empty' "$index_path" 2>/dev/null || true)"
  [ -n "$active_id" ] || return 1
  [ -d "$ROOT_ABS/.signum/contracts/$active_id" ] || return 1

  printf '%s\n' "$ROOT_ABS/.signum/contracts/$active_id"
}

resolve_artifact_root() {
  local output_dir=""

  if [ -n "$OUTPUT_PATH" ]; then
    output_dir="$(dirname "$(abspath_from_root "$OUTPUT_PATH")")"
    if [ -f "$output_dir/contract.json" ] || [ -f "$output_dir/proofpack.json" ] || [ "$(basename "$OUTPUT_PATH")" = "anti_entropy_report.json" ]; then
      printf '%s\n' "$output_dir"
      return 0
    fi
  fi

  if [ -n "$CONTRACT_PATH" ]; then
    dirname "$(abspath_from_root "$CONTRACT_PATH")"
    return 0
  fi

  if [ -n "$PROOFPACK_PATH" ]; then
    dirname "$(abspath_from_root "$PROOFPACK_PATH")"
    return 0
  fi

  if resolve_active_artifact_root >/dev/null 2>&1; then
    resolve_active_artifact_root
    return 0
  fi

  printf '%s\n' "$ROOT_ABS/.signum"
}

ARTIFACT_ROOT="$(resolve_artifact_root)"

[ -n "$OUTPUT_PATH" ] && OUTPUT_PATH="$(abspath_from_root "$OUTPUT_PATH")"
[ -n "$CONTRACT_PATH" ] || CONTRACT_PATH="$ARTIFACT_ROOT/contract.json"
[ -n "$PROOFPACK_PATH" ] || PROOFPACK_PATH="$ARTIFACT_ROOT/proofpack.json"

if [ -n "$DOC_PARITY_JSON" ] && [ ! -f "$DOC_PARITY_JSON" ]; then
  echo "doc parity JSON not found: $DOC_PARITY_JSON" >&2
  exit 1
fi
if [ -n "$METRIC_RATCHET_JSON" ] && [ ! -f "$METRIC_RATCHET_JSON" ]; then
  echo "metric ratchet JSON not found: $METRIC_RATCHET_JSON" >&2
  exit 1
fi
if [ -f "$CONTRACT_PATH" ]; then
  jq empty "$CONTRACT_PATH" >/dev/null 2>&1 || { echo "invalid contract JSON: $CONTRACT_PATH" >&2; exit 1; }
fi
if [ -f "$PROOFPACK_PATH" ]; then
  jq empty "$PROOFPACK_PATH" >/dev/null 2>&1 || { echo "invalid proofpack JSON: $PROOFPACK_PATH" >&2; exit 1; }
fi

TMP_FINDINGS="$(mktemp)"
trap 'rm -f "$TMP_FINDINGS"' EXIT
touch "$TMP_FINDINGS"

SOURCE_FLAGS=()

emit_finding() {
  local category="$1"
  local severity="$2"
  local target="$3"
  local source="$4"
  local summary="$5"
  local action="$6"
  local details="$7"

  jq -nc \
    --arg category "$category" \
    --arg severity "$severity" \
    --arg target "$target" \
    --arg source "$source" \
    --arg summary "$summary" \
    --arg recommendedAction "$action" \
    --arg details "$details" \
    '{category:$category,severity:$severity,target:$target,source:$source,summary:$summary,recommendedAction:$recommendedAction,details:$details}' \
    >> "$TMP_FINDINGS"
}

# ---------------------------------------------------------------------------
# Source 1: cleanup obligations and removal evidence
# ---------------------------------------------------------------------------
if [ -f "$CONTRACT_PATH" ]; then
  SOURCE_FLAGS+=("cleanup_obligations")

  python3 - "$CONTRACT_PATH" "$PROOFPACK_PATH" <<'PY' > "${TMP_FINDINGS}.cleanup"
import json, os, sys

contract_path, proofpack_path = sys.argv[1], sys.argv[2]
with open(contract_path) as f:
    contract = json.load(f)

proofpack = {}
if proofpack_path and os.path.exists(proofpack_path):
    with open(proofpack_path) as f:
        proofpack = json.load(f)

obligation_evidence = {}
for item in proofpack.get("removalEvidence", {}).get("obligations", []):
    if "id" in item:
        obligation_evidence[item["id"]] = item

removal_evidence = {}
for item in proofpack.get("removalEvidence", {}).get("removals", []):
    if "id" in item:
        removal_evidence[item["id"]] = item

for obligation in contract.get("cleanupObligations", []):
    oid = obligation.get("id", "")
    evidence = obligation_evidence.get(oid)
    blocking = obligation.get("blocking", True)
    severity = "high" if blocking else "medium"
    if evidence and evidence.get("fulfilled") is False:
        print(json.dumps({
            "category": "cleanup_obligation_unfulfilled",
            "severity": severity,
            "target": obligation.get("target", ""),
            "source": "cleanup_obligations",
            "summary": f"{oid} remains unfulfilled after proofpack evidence",
            "recommendedAction": "follow_up_contract",
            "details": obligation.get("description", "")
        }))
    elif not evidence and proofpack:
        print(json.dumps({
            "category": "cleanup_obligation_missing_evidence",
            "severity": "medium",
            "target": obligation.get("target", ""),
            "source": "cleanup_obligations",
            "summary": f"{oid} has no fulfillment evidence in proofpack",
            "recommendedAction": "investigate",
            "details": obligation.get("description", "")
        }))

for removal in contract.get("removals", []):
    rid = removal.get("id", "")
    evidence = removal_evidence.get(rid)
    if evidence and evidence.get("removed") is False:
        print(json.dumps({
            "category": "removal_incomplete",
            "severity": "high",
            "target": removal.get("path", ""),
            "source": "cleanup_obligations",
            "summary": f"{rid} target still exists according to proofpack removal evidence",
            "recommendedAction": "follow_up_contract",
            "details": removal.get("reason", "")
        }))
    if evidence and int(evidence.get("orphanReferences", 0) or 0) > 0:
        print(json.dumps({
            "category": "removal_orphan_references",
            "severity": "high",
            "target": removal.get("path", ""),
            "source": "cleanup_obligations",
            "summary": f"{rid} still has orphan references after removal",
            "recommendedAction": "follow_up_contract",
            "details": str(evidence.get("orphanReferences"))
        }))
    transition = removal.get("modulesYamlTransition", "none")
    if transition != "none" and evidence and evidence.get("modulesYamlUpdated") is False:
        print(json.dumps({
            "category": "module_manifest_sync_missing",
            "severity": "medium",
            "target": "modules.yaml",
            "source": "cleanup_obligations",
            "summary": f"{rid} removal did not update modules.yaml state",
            "recommendedAction": "follow_up_contract",
            "details": transition
        }))
PY

  if [ -s "${TMP_FINDINGS}.cleanup" ]; then
    cat "${TMP_FINDINGS}.cleanup" >> "$TMP_FINDINGS"
  fi
  rm -f "${TMP_FINDINGS}.cleanup"
fi

# ---------------------------------------------------------------------------
# Source 2: modules.yaml drift (simple parser for Signum modules manifest shape)
# ---------------------------------------------------------------------------
if [ -f "modules.yaml" ]; then
  SOURCE_FLAGS+=("modules_yaml")

  python3 - "modules.yaml" "$AS_OF" <<'PY' > "${TMP_FINDINGS}.modules"
import json, os, re, sys

modules_path, as_of = sys.argv[1], sys.argv[2]
modules = []
current = None

with open(modules_path, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if re.match(r'^\s*-\s+path:\s+', line):
            if current:
                modules.append(current)
            current = {"path": line.split(":", 1)[1].strip().strip('"').strip("'")}
            continue
        if current is None:
            continue
        m = re.match(r'^\s+([A-Za-z_]+):\s*(.+?)\s*$', line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        current[key] = value.strip('"').strip("'")

if current:
    modules.append(current)

for mod in modules:
    path = mod.get("path", "")
    status = mod.get("status", "")
    remove_after = mod.get("remove_after", "")
    exists = os.path.exists(path)

    if status == "deprecated" and remove_after and remove_after < as_of and exists:
        print(json.dumps({
            "category": "module_deadline_passed",
            "severity": "medium",
            "target": path,
            "source": "modules_yaml",
            "summary": f"Deprecated module passed remove_after deadline ({remove_after}) and still exists",
            "recommendedAction": "follow_up_contract",
            "details": mod.get("name", path)
        }))

    if status == "removed" and exists:
        print(json.dumps({
            "category": "removed_module_still_exists",
            "severity": "high",
            "target": path,
            "source": "modules_yaml",
            "summary": "Module is marked removed in modules.yaml but path still exists",
            "recommendedAction": "follow_up_contract",
            "details": mod.get("name", path)
        }))
PY

  if [ -s "${TMP_FINDINGS}.modules" ]; then
    cat "${TMP_FINDINGS}.modules" >> "$TMP_FINDINGS"
  fi
  rm -f "${TMP_FINDINGS}.modules"
fi

# ---------------------------------------------------------------------------
# Source 3: doc parity output (consume existing report, do not rerun)
# ---------------------------------------------------------------------------
if [ -n "$DOC_PARITY_JSON" ]; then
  SOURCE_FLAGS+=("doc_parity")
  jq -c '.findings[]? | {
      category: "docs_sync",
      severity: "medium",
      target: (.file // ""),
      source: "doc_parity",
      summary: (.message // "Documentation parity finding"),
      recommendedAction: "follow_up_contract",
      details: ((.code // "unknown") + ": " + (.details // ""))
    }' "$DOC_PARITY_JSON" >> "$TMP_FINDINGS"
fi

# ---------------------------------------------------------------------------
# Source 4: metric ratchet output (consume existing report, do not rerun)
# ---------------------------------------------------------------------------
if [ -n "$METRIC_RATCHET_JSON" ]; then
  SOURCE_FLAGS+=("metric_ratchet")
  jq -c 'if (.status // "") == "regression"
    then (.regressions[]? | {
      category: "metric_regression",
      severity: "medium",
      target: (.metric // ""),
      source: "metric_ratchet",
      summary: "Metric regression detected",
      recommendedAction: "investigate",
      details: ("previous=" + ((.previous // "")|tostring) + ", current=" + ((.current // "")|tostring) + ", delta=" + ((.delta // "")|tostring))
    })
    else empty end' "$METRIC_RATCHET_JSON" >> "$TMP_FINDINGS"
fi

SOURCE_JSON="$(printf '%s\n' "${SOURCE_FLAGS[@]:-}" | sed '/^$/d' | jq -R . | jq -s .)"
FINDINGS_JSON="$(jq -s '
  to_entries
  | map(.value + {
      id: (
        "AE"
        + (if (.key + 1) < 10 then "0" else "" end)
        + ((.key + 1) | tostring)
      )
    })
' "$TMP_FINDINGS")"
FINDINGS_COUNT="$(echo "$FINDINGS_JSON" | jq 'length')"
STATUS="ok"
SUMMARY="No anti-entropy follow-up found"
if [ "$FINDINGS_COUNT" -gt 0 ]; then
  STATUS="warn"
  SUMMARY="${FINDINGS_COUNT} anti-entropy follow-up finding(s)"
fi

REPORT="$(jq -n \
  --arg check "anti_entropy" \
  --arg status "$STATUS" \
  --arg summary "$SUMMARY" \
  --arg as_of "$AS_OF" \
  --arg project_root "$ROOT_ABS" \
  --arg contract_path "$CONTRACT_PATH" \
  --arg proofpack_path "$PROOFPACK_PATH" \
  --argjson sources "$SOURCE_JSON" \
  --argjson findings "$FINDINGS_JSON" \
  '{
    check: $check,
    status: $status,
    summary: $summary,
    asOf: $as_of,
    projectRoot: $project_root,
    inputs: {
      contract: $contract_path,
      proofpack: $proofpack_path
    },
    sources: $sources,
    findings: $findings
  }')"

if [ -n "$OUTPUT_PATH" ]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  printf '%s\n' "$REPORT" > "$OUTPUT_PATH"
fi

printf '%s\n' "$REPORT"
