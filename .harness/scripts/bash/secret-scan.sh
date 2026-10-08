#!/usr/bin/env bash
# Secret scanner (bash parity) — detects API keys, DB passwords, tokens.
# Reads from stdin or a file path argument.
# exit 0 = clean, 1 = low/medium, 2 = high/critical (hard stop).
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
PATTERNS_FILE="$HARNESS_ROOT/.harness/control/secret-patterns.json"

CONTENT=""
if [ $# -ge 1 ] && [ -f "$1" ]; then
    CONTENT=$(cat "$1")
else
    CONTENT=$(cat)
fi

if [ -z "$CONTENT" ]; then
    exit 0
fi

if [ ! -f "$PATTERNS_FILE" ]; then
    echo "[secret-scan] No patterns file at $PATTERNS_FILE, skipping" >&2
    exit 0
fi

# Parse patterns and scan
python3 -c "
import json, sys, re

with open('$PATTERNS_FILE', 'r') as f:
    config = json.load(f)

patterns = config if isinstance(config, list) else config.get('patterns', [])
content = '''$CONTENT'''

findings = []
for entry in patterns:
    matches = list(re.finditer(entry['pattern'], content))
    for m in matches:
        val = m.group()
        masked = val[:4] + '...' + val[-4:] if len(val) > 8 else '****'
        findings.append({
            'severity': entry['severity'],
            'name': entry['name'],
            'match': masked
        })

total = len(findings)
high = sum(1 for f in findings if f['severity'] in ('high', 'critical'))

if total == 0:
    sys.exit(0)

print(f'[secret-scan] Found {total} potential secret(s) ({high} high/critical)', file=sys.stderr)
for f in findings:
    print(f'[secret-scan] [{f[\"severity\"].upper()}] {f[\"name\"]}: {f[\"match\"]}', file=sys.stderr)

report = {'scanner': 'secret-scan', 'total': total, 'high_critical': high, 'findings': findings}
print(json.dumps(report))

sys.exit(2 if high > 0 else 1)
" 2>&1
