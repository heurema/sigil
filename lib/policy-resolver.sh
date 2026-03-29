#!/usr/bin/env bash
# policy-resolver.sh -- resolve model and behavior overrides from .signum/policy.toml
# Based on specpunk's policy.toml pattern (declarative rules, match/set).
#
# Usage:
#   source lib/policy-resolver.sh
#   resolve_model "engineer" "medium"   # returns model name or empty (use default)
#   resolve_budget "max_iterations"     # returns value or empty
#
# Reads .signum/policy.toml if present. Falls back to agent frontmatter defaults.
# Requires python3 (stdlib only, no toml package — uses regex parser).

set -euo pipefail

POLICY_FILE="${SIGNUM_POLICY_FILE:-.signum/policy.toml}"

# Resolve model for a given role and risk level
# Args: role (contractor|engineer|reviewer|synthesizer) risk_level (low|medium|high)
# Returns: model name or empty string (caller uses default)
resolve_model() {
  local role="${1:?role required}"
  local risk="${2:-low}"

  [ -f "$POLICY_FILE" ] || return 0

  python3 - "$role" "$risk" "$POLICY_FILE" <<'PYEOF'
import re, sys

role = sys.argv[1]
risk = sys.argv[2]
key = role + '_model'

with open(sys.argv[3]) as f:
    text = f.read()

# Parse defaults
defaults = {}
in_defaults = False
for line in text.split('\n'):
    s = line.strip()
    if s == '[defaults]':
        in_defaults = True; continue
    if s.startswith('['):
        in_defaults = False; continue
    if in_defaults and '=' in s:
        k, _, v = s.partition('=')
        v = v.split('#')[0].strip().strip('\"')
        defaults[k.strip()] = v

# Strip comment lines before parsing rules
clean = '\n'.join(l for l in text.split('\n') if not l.strip().startswith('#'))

# Parse rules (match risk -> set overrides)
model = defaults.get(key, '')
rule_blocks = re.findall(r'\[\[rules\]\](.*?)(?=\[\[|\[(?!\[)|\Z)', clean, re.DOTALL)
for block in rule_blocks:
    match_m = re.search(r'match\s*=\s*\{([^}]*)\}', block)
    set_m = re.search(r'set\s*=\s*\{([^}]*)\}', block)
    if not match_m or not set_m:
        continue
    # Parse match conditions
    match_str = match_m.group(1)
    conditions_met = True
    for cond in match_str.split(','):
        cond = cond.strip()
        if '=' in cond:
            ck, _, cv = cond.partition('=')
            ck = ck.strip(); cv = cv.strip().strip('\"')
            if ck == 'risk' and cv != risk:
                conditions_met = False
    if conditions_met:
        # Parse set overrides
        for item in set_m.group(1).split(','):
            item = item.strip()
            if '=' in item:
                sk, _, sv = item.partition('=')
                sk = sk.strip(); sv = sv.strip().strip('\"')
                if sk == key:
                    model = sv

print(model)
PYEOF
}

# Resolve budget parameter
# Args: param_name (max_iterations|max_engineer_attempts)
# Returns: value or empty string
resolve_budget() {
  local param="${1:?param required}"

  [ -f "$POLICY_FILE" ] || return 0

  python3 - "$param" "$POLICY_FILE" <<'PYEOF'
import sys

param = sys.argv[1]
with open(sys.argv[2]) as f:
    text = f.read()

in_budget = False
for line in text.split('\n'):
    s = line.strip()
    if s == '[budget]':
        in_budget = True; continue
    if s.startswith('['):
        in_budget = False; continue
    if in_budget and '=' in s:
        k, _, v = s.partition('=')
        k = k.strip(); v = v.strip().split('#')[0].strip()
        if k == param:
            print(v)
            sys.exit(0)
PYEOF
}
