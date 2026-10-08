#!/usr/bin/env bash
# Record one Agent Pack pipeline run (P-7). Thin wrapper over
# .harness/scripts/lib/harness_pipeline_log.py so bash and PowerShell behave
# identically (C7).
#
#   bash .harness/scripts/bash/harness-pipeline-log.sh --skill impact-review \
#        --verdict APPROVED --found 7 --confirmed 3 --dropped 4 --fixed 3
#
# The record is a SELF-REPORT by the agent that ran the loop, not proof it ran.
# The library rejects internally inconsistent counts (more fixed than confirmed,
# more confirmed than found) rather than writing a row a dashboard would then
# present as measurement.
set -euo pipefail

ROOT=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    *)      ARGS+=("$1"); shift;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# Worktree-aware, same as the hooks: write to the .harness the hooks write to,
# or a run made in a worktree lands in a telemetry directory nothing ships.
if [ ! -d "$ROOT/.harness" ]; then
  _common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$_common" ]; then
    case "$_common" in /*) : ;; *) _common="$ROOT/$_common" ;; esac
    _main="$(cd "$_common/.." 2>/dev/null && pwd || true)"
    [ -n "$_main" ] && [ -d "$_main/.harness" ] && ROOT="$_main"
  fi
fi

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "python required for harness pipeline-log" >&2; exit 3; }

exec "$PY" "$ROOT/.harness/scripts/lib/harness_pipeline_log.py" "$ROOT" "${ARGS[@]}"
