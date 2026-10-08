#!/usr/bin/env bash
# Domain Firewall (bash parity) — checks if agent can read/write a path (H4).
# Reads guard-zones.json, exit 0 = allowed, exit 2 = blocked.
set -euo pipefail

AGENT_NAME="${1:-}"
TARGET_PATH="${2:-}"
OPERATION="${3:-read}"

if [ -z "$AGENT_NAME" ] || [ -z "$TARGET_PATH" ]; then
    echo "Usage: $0 <agent-name> <target-path> [read|write]" >&2
    exit 1
fi

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
ZONES_FILE="$HARNESS_ROOT/.harness/control/guard-zones.json"

if [ ! -f "$ZONES_FILE" ]; then
    exit 0
fi

python3 -c "
import json, re, sys

with open('$ZONES_FILE', 'r') as f:
    config = json.load(f)

normalised = '$TARGET_PATH'.replace('\\\\', '/')
root = '$HARNESS_ROOT'.replace('\\\\', '/')
if normalised.startswith(root):
    normalised = normalised[len(root)+1:]

default_action = config.get('default_action', 'deny')
zones = config.get('zones', [])
matched = False

for zone in zones:
    for pattern in zone.get('paths', []):
        p = pattern.replace('\\\\', '/')
        regex = '^' + re.escape(p).replace(r'\*\*', '.*').replace(r'\*', '[^/]*') + '$'
        if re.match(regex, normalised):
            matched = True
            agents = zone.get('allowed_agents', [])
            if '*' not in agents and '$AGENT_NAME' not in agents:
                print(f'BLOCKED: Agent not allowed in zone {zone[\"name\"]}', file=sys.stderr)
                sys.exit(2)
            ops = zone.get('allowed_operations', [])
            if '$OPERATION' not in ops:
                exceptions = zone.get('exceptions', [])
                exempt = any(e['agent'] == '$AGENT_NAME' and e['operation'] == '$OPERATION' for e in exceptions)
                if not exempt:
                    print(f'BLOCKED: Operation not allowed in zone {zone[\"name\"]}', file=sys.stderr)
                    sys.exit(2)

if not matched and default_action == 'deny':
    print(f'BLOCKED: No zone matches (default: deny)', file=sys.stderr)
    sys.exit(2)

sys.exit(0)
" 2>&1
