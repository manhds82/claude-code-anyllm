#!/usr/bin/env bash
# harness doctor — local self-check for a project's evidence pipeline.
# Thin wrapper over .harness/scripts/lib/harness_doctor.py so bash and PowerShell
# emit identical output (C7). Read-only diagnostic.
#   bash .harness/scripts/bash/harness-doctor.sh [ROOT] [--strict] [--ci]
#   --ci: on a CI runner, report machine-local checks (ledger, telemetry, context)
#         as not checkable instead of FAIL; bundle integrity stays graded (B-78).
set -euo pipefail

ROOT=""
STRICT=""
CI_MODE=""
for a in "$@"; do
  case "$a" in
    --strict) STRICT="--strict" ;;
    --ci) CI_MODE="--ci" ;;
    -*) : ;;
    *) ROOT="$a" ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# Worktree-aware, same as the hooks: report on the .harness the hooks write to.
if [ ! -d "$ROOT/.harness" ]; then
  _common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$_common" ]; then
    case "$_common" in /*) : ;; *) _common="$ROOT/$_common" ;; esac
    _main="$(cd "$_common/.." 2>/dev/null && pwd || true)"
    [ -n "$_main" ] && [ -d "$_main/.harness" ] && ROOT="$_main"
  fi
fi

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "python required for harness doctor" >&2; exit 3; }

exec "$PY" "$(dirname "$0")/../lib/harness_doctor.py" "$ROOT" $STRICT $CI_MODE
