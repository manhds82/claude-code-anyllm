#!/usr/bin/env bash
# Idempotency Executor (bash parity) — ensures side-effect tools run at most once.
set -euo pipefail

TOOL_NAME="${1:-}"
TOOL_INPUT="${2:-}"

if [ -z "$TOOL_NAME" ]; then
    echo '{"status":"error","error":"tool_name required"}'
    exit 1
fi

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
LOCK_DIR="$HARNESS_ROOT/.harness/ledger/idempotency"
mkdir -p "$LOCK_DIR"

REGISTRY="$HARNESS_ROOT/.harness/control/tool-registry.json"

if [ ! -f "$REGISTRY" ]; then
    echo '{"status":"executed","key":null}'
    exit 0
fi

# Extract idempotency key pattern (simplified)
ID_PATTERN=$(python3 -c "
import json
with open('$REGISTRY', 'r') as f:
    r = json.load(f)
t = r.get('tools', {}).get('$TOOL_NAME', {})
print(t.get('idempotency_key_pattern', ''))
")

if [ -z "$ID_PATTERN" ]; then
    echo '{"status":"executed","key":null}'
    exit 0
fi

# Compute key hash
KEY_HASH=$(echo "$ID_PATTERN" | sha256sum | cut -c1-32)
LOCK_FILE="$LOCK_DIR/$KEY_HASH.json"

if [ -f "$LOCK_FILE" ]; then
    echo "{\"status\":\"skipped\",\"key\":\"$ID_PATTERN\",\"key_hash\":\"$KEY_HASH\"}"
    exit 0
fi

# Create lock and execute
cat > "$LOCK_FILE" << LOCKEOL
{"tool":"$TOOL_NAME","key":"$ID_PATTERN","key_hash":"$KEY_HASH","status":"completed","executed_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
LOCKEOL

echo "{\"status\":\"executed\",\"key\":\"$ID_PATTERN\",\"key_hash\":\"$KEY_HASH\"}"
