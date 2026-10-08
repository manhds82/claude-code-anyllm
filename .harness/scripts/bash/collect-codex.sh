#!/usr/bin/env bash
# Collect Codex token usage into this project's telemetry (B9b) — bash parity (C7).
#
# Codex has NO hook mechanism, so nothing stamps usage as it happens. Codex does
# write a transcript per session under ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl,
# and this reads those directly — which makes the Codex path more robust than the
# Claude one, that collects nothing when its hook is not wired.
#
# The arithmetic lives in ../lib/codex_collect.py, shared with the PowerShell
# twin. This script only locates things and reports; it never computes a token
# or a cost. Two hand-written copies of the same calculation drift, and the
# drift shows up as a cost that differs by machine.
#
# Best-effort by design: no `set -e`. A collector must not be the reason a
# session-end hook fails (C10 — this is measurement, not enforcement).
set -uo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-}"
if [ -z "$CODEX_SESSIONS_DIR" ]; then
    _home="${HOME:-${USERPROFILE:-$HOME}}"
    CODEX_SESSIONS_DIR="$_home/.codex/sessions"
fi
PRICING_PATH="${PRICING_PATH:-$HARNESS_ROOT/.harness/control/token-pricing.json}"
LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)/codex_collect.py"

if [ ! -f "$LIB" ]; then
    echo "[collect-codex] missing shared collector: $LIB" >&2
    exit 0
fi

if [ ! -d "$CODEX_SESSIONS_DIR" ]; then
    # Not a warning: a machine that does not run Codex is the normal case, and a
    # warning channel that fires on the normal case stops being read (C14).
    echo "[collect-codex] no Codex sessions dir ($CODEX_SESSIONS_DIR) -- nothing to collect."
    exit 0
fi

PY=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
    echo "[collect-codex] python not found -- Codex usage NOT collected." >&2
    exit 0
fi

MEMBER="${HARNESS_USER:-}"
if [ -z "$MEMBER" ]; then
    # Same attribution source the Claude path uses, so a Codex row lands on the
    # same member as a Claude row from this machine.
    # Portal v2 P1 1.7: member_email lives in .harness/local/checkout.json; the shared reader
    # falls back to portal-sync.json and reports where the value came from (stderr).
    STATE_LIB="$HARNESS_ROOT/.harness/scripts/lib/harness_local_state.py"
    if [ -f "$STATE_LIB" ]; then
        MEMBER=$("$PY" "$STATE_LIB" member-email "$HARNESS_ROOT" 2>/dev/null | "$PY" -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
    if d.get("value") and d.get("warning"):
        sys.stderr.write("[collect-codex] " + d["warning"] + "
")
    print(d.get("value") or "")
except Exception:
    print("")')
    fi
fi

"$PY" "$LIB" "$HARNESS_ROOT" "$CODEX_SESSIONS_DIR" "$PRICING_PATH" "$MEMBER"
exit 0
