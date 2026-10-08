#!/usr/bin/env bash
# Stop hook (C15) -- POSIX parity of harness-handoff-check.ps1. Thin wrapper over
# .harness/scripts/lib/harness_handoff.py so both shells decide identically (C7).
# Reads the Stop-hook JSON on stdin; prints a block decision or nothing.
# Always exits 0 (fail-open, C14). Defense-in-depth, bypassable locally (C10).
ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)" || exit 0
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || exit 0
LIB="$ROOT/.harness/scripts/lib/harness_handoff.py"
[ -f "$LIB" ] || exit 0
"$PY" "$LIB" "$ROOT" 2>/dev/null || true
exit 0
