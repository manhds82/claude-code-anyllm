#!/usr/bin/env bash
# SessionEnd hook (POSIX parity of harness-session-end.ps1). Archives session
# telemetry and cleans up the session temp workspace.
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SID="${HARNESS_SESSION_ID:-unknown}"
TEL="$HARNESS_ROOT/.harness/telemetry"

# Capture stdin once (hook JSON) so we can both archive and sample it.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat || true)
fi

# H6: sample the whole session's real token usage from the transcript.
# SubagentStop only covers subagents; this covers the main agent.
if [ -n "$INPUT" ] && [ -f "$HARNESS_ROOT/.harness/scripts/bash/agentops-sampler.sh" ]; then
  printf '%s' "$INPUT" | bash "$HARNESS_ROOT/.harness/scripts/bash/agentops-sampler.sh" >/dev/null 2>&1 || true
fi

# C9 — seal the session: append one ledger entry recording the session ended and
# the chain head it ended at. Written BEFORE push so the seal ships in the same
# telemetry run. A chain that only ever grows on tool calls has no marker for
# "this session's contribution ends here"; the seal gives an auditor a per-session
# boundary. Best-effort -- a ledger failure must never fail session end.
LEDGER="$HARNESS_ROOT/.harness/scripts/bash/evidence-ledger.sh"
CHAIN="$HARNESS_ROOT/.harness/ledger/chain.jsonl"
if [ -f "$LEDGER" ] && [ -f "$CHAIN" ]; then
  HEAD_HASH="$(tail -1 "$CHAIN" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("entry_hash",""))' 2>/dev/null || true)"
  SEAL=$(printf '{"actor":{"agent":"harness","user":"%s","session_id":"%s","role":"system"},"action":{"type":"pipeline_event","tool":"session-end","description":"session sealed; chain head %s"},"decision":{"result":"allow","reason":"session end","risk_level":"none"}}' \
    "${HARNESS_USER:-${USER:-local}}" "$SID" "${HEAD_HASH:0:16}")
  bash "$LEDGER" append --entry-json "$SEAL" >/dev/null 2>&1 || true
fi

# Codex collection is NOT called here. It lives inside push-telemetry.sh, which
# runs a few lines down, so it happens on this path anyway -- and on the fleet
# driver's timer, which needs no Claude session. Two call sites would be a second
# copy to keep in step (B-13/B-14).

# Push telemetry to the Control Portal if configured (.harness/portal-sync.json)
# — the sync path for checkouts the backend can't read. Best-effort.
if [ -f "$HARNESS_ROOT/.harness/scripts/bash/push-telemetry.sh" ]; then
  bash "$HARNESS_ROOT/.harness/scripts/bash/push-telemetry.sh" >/dev/null 2>&1 || true
fi

if [ -f "$TEL/tool-calls.log" ]; then
  cp -f "$TEL/tool-calls.log" "$TEL/session-$SID-$(date +%Y%m%d%H%M%S).log"
fi
[ -d "$HARNESS_ROOT/.harness/tmp/$SID" ] && rm -rf "$HARNESS_ROOT/.harness/tmp/$SID" || true

echo "[harness] Session $SID ended at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit 0
