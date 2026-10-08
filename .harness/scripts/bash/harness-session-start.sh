#!/usr/bin/env bash
# SessionStart hook (POSIX parity of harness-session-start.ps1). Initialises
# per-session state: verifies .harness/ layout, makes a session temp dir, emits
# a start line. Defense-in-depth, bypassable locally.
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"

# Worktree-aware root resolution (parity with harness-session-start.ps1). A
# session run inside a git worktree shares the main repo's .git but usually has
# no .harness/ of its own, so a hook resolving purely by path writes ledger and
# telemetry into a directory with no .harness -- lost SILENTLY. One consuming
# project reported two weeks of zero H2/H5 evidence from exactly this. If .harness
# is missing, ask git for the common dir and use its parent -- the main checkout.
if [ ! -d "$HARNESS_ROOT/.harness" ]; then
  _common="$(git -C "$HARNESS_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$_common" ]; then
    case "$_common" in /*) : ;; *) _common="$HARNESS_ROOT/$_common" ;; esac
    _main="$(cd "$_common/.." 2>/dev/null && pwd || true)"
    if [ -n "$_main" ] && [ -d "$_main/.harness" ]; then
      echo "[harness] worktree detected -- ledger/telemetry -> main checkout $_main"
      HARNESS_ROOT="$_main"
    fi
  fi
fi

SID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null \
      || python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || date +%s)"

# Record a hook failure durably instead of swallowing it (parity with the PS1).
# best-effort must not mean silent-forever: `harness doctor` reads this back.
_hook_err() {
  { log="$HARNESS_ROOT/.harness/telemetry/hook-errors.log"
    mkdir -p "$(dirname "$log")" 2>/dev/null
    printf '{"timestamp":"%s","hook":"%s","error":"%s","session_id":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr -d '"\n')" "$SID" >> "$log"
  } 2>/dev/null || true
}

for d in ".harness/control" ".harness/scripts/bash" ".harness/ledger" ".harness/telemetry" "contracts"; do
  [ -d "$HARNESS_ROOT/$d" ] || echo "[harness-session-start] Missing directory: $d" >&2
done

mkdir -p "$HARNESS_ROOT/.harness/tmp/$SID"
export HARNESS_SESSION_ID="$SID"
export HARNESS_ROOT
export HARNESS_SESSION_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# H1 — build/refresh the pipeline-context pointer store (best-effort).
CTX="$(dirname "$0")/harness-context-build.sh"
[ -f "$CTX" ] && HARNESS_ROOT="$HARNESS_ROOT" bash "$CTX" || true

# C9 — genesis the ledger if it has never been written (parity with the PS1).
# chain.jsonl is otherwise created lazily on the first side-effect, so a project
# that made none has no chain at all -- and a chain with no genesis cannot prove
# it is intact from the start. Three consuming projects were found in that state.
CHAIN="$HARNESS_ROOT/.harness/ledger/chain.jsonl"
if [ ! -f "$CHAIN" ]; then
  LEDGER="$(dirname "$0")/evidence-ledger.sh"
  if [ -f "$LEDGER" ]; then
    if HARNESS_ROOT="$HARNESS_ROOT" bash "$LEDGER" init >/dev/null 2>&1; then
      [ -f "$CHAIN" ] && echo "[harness] ledger genesis written -> $CHAIN"
    else
      _hook_err "session-start" "ledger genesis failed"
    fi
  fi
fi

echo "[harness] Session $SID started at $HARNESS_SESSION_START"
exit 0
