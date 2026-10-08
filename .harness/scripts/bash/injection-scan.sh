#!/usr/bin/env bash
# Prompt Injection Scanner (bash parity) — UserPromptSubmit hook (H4).
# Reads stdin, scans for injection patterns, exits 2 on high-severity.
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
PATTERNS_FILE="$HARNESS_ROOT/.harness/control/injection-patterns.json"

INPUT_TEXT=$(cat)
if [ -z "$INPUT_TEXT" ]; then
    exit 0
fi

if [ ! -f "$PATTERNS_FILE" ]; then
    exit 0
fi

# Pass prompt text + config via env (never string-interpolate untrusted prompt
# into a python literal -- injection/breakage hole). Persist findings to
# security-events.jsonl (parity with the PS scanner) with a context-rich
# excerpt the Portal can display.
HARNESS_SCAN_INPUT="$INPUT_TEXT" \
HARNESS_PATTERNS_FILE="$PATTERNS_FILE" \
HARNESS_SECRET_PATTERNS_FILE="$HARNESS_ROOT/.harness/control/secret-patterns.json" \
HARNESS_EVENTS_FILE="$HARNESS_ROOT/.harness/telemetry/security-events.jsonl" \
HARNESS_SESSION="${HARNESS_SESSION_ID:-}" HARNESS_ACTOR="${HARNESS_USER:-${USER:-}}" \
python3 - <<'PY'
import json, os, sys, re, hashlib, datetime

with open(os.environ['HARNESS_PATTERNS_FILE'], encoding='utf-8-sig') as f:
    config = json.load(f)
patterns = config if isinstance(config, list) else config.get('patterns', [])
text = os.environ.get('HARNESS_SCAN_INPUT', '')

# --- Redaction (parity with injection-scan.ps1) -----------------------------
# `excerpt` is persisted to security-events.jsonl and shipped to the Portal by
# push-telemetry. It embeds a 240-character window of the raw prompt, so a
# prompt that mentioned a credential next to an injection phrase wrote that
# credential into a durable, synced store -- the detector became the leak.
#
# Patterns come from .harness/control/secret-patterns.json (C2) so a shape
# added for secret-scan protects this path too, plus generic high-entropy
# shapes: a redactor that only knows vendor prefixes misses the value nobody
# wrote a pattern for.
_redactors = []
try:
    with open(os.environ['HARNESS_SECRET_PATTERNS_FILE'], encoding='utf-8-sig') as _f:
        _sp = json.load(_f)
    for _e in (_sp if isinstance(_sp, list) else _sp.get('patterns', [])):
        _pat = _e.get('pattern') if isinstance(_e, dict) else None
        if _pat:
            try:
                _redactors.append(re.compile(_pat))
            except re.error:
                pass
except Exception:
    pass
for _generic in (
    r'(?i)(secret|passwd|password|token|api[_\-]?key|bearer|authorization)\s*["\':=]+\s*\S+',
    r'\b[A-Za-z0-9+/]{40,}={0,2}\b',
    r'\b[0-9a-fA-F]{32,}\b',
):
    _redactors.append(re.compile(_generic))


def _redact(value):
    for _rx in _redactors:
        value = _rx.sub('[REDACTED]', value)
    return value


findings = []
for entry in patterns:
    try:
        rx = re.compile(entry['pattern'])
    except re.error:
        continue
    for m in rx.finditer(text):
        # Redact BOTH the window and the matched signature: an injection
        # pattern can match text that itself contains a credential, so
        # sanitising only the context would still log it via `sig`.
        sig = _redact(m.group()[:80])
        start = max(0, m.start() - 60)
        ctx = _redact(re.sub(r'\s+', ' ', text[start:m.end() + 120]).strip()[:240])
        findings.append({
            'severity': entry.get('severity', 'medium'),
            'category': entry.get('category', 'unknown'),
            'match': sig,
            'excerpt': f'matched [{entry.get("category","")}] "{sig}" | prompt: ...{ctx}...',
        })

total = len(findings)
high = sum(1 for f in findings if f['severity'] == 'high')
if total == 0:
    sys.exit(0)

# Persist authoritative security events
ev_path = os.environ['HARNESS_EVENTS_FILE']
os.makedirs(os.path.dirname(ev_path), exist_ok=True)
ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(ev_path, 'a', encoding='utf-8') as out:
    for f in findings:
        eid = 'se-' + hashlib.sha256(f'{ts}|injection|{f["category"]}|{f["match"]}'.encode()).hexdigest()[:24]
        out.write(json.dumps({
            'event_id': eid, 'timestamp': ts, 'type': 'injection',
            'severity': f['severity'], 'category': f['category'][:50],
            'excerpt': f['excerpt'], 'detected_by': 'injection-scan',
            'actor_user': os.environ.get('HARNESS_ACTOR', ''),
            'session_id': os.environ.get('HARNESS_SESSION', ''),
        }) + '\n')

print(f'[injection-scan] Detected {total} injection signature(s) ({high} high)', file=sys.stderr)
for f in findings:
    print(f'[injection-scan] [{f["severity"].upper()}][{f["category"]}] {f["match"]}', file=sys.stderr)
print(json.dumps({'scanner': 'injection-scan', 'total': total, 'high': high, 'findings': findings}))
sys.exit(2 if high > 0 else 1)
PY
