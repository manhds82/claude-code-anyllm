#!/usr/bin/env bash
# harness fingerprint -- which bundle version does this checkout REALLY match?
# Thin wrapper over .harness/scripts/lib/harness_fingerprint.py so bash and
# PowerShell emit identical output (C7). Read-only.
#   bash .harness/scripts/bash/harness-fingerprint.sh [ROOT] [--json] [--index FILE]
# Exit: 0 identified, 1 receipt disagrees, 2 could not identify (unproven).
set -euo pipefail

ROOT=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) EXTRA+=("--json"); shift ;;
    --index) EXTRA+=("--index" "$2"); shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "python required for harness fingerprint" >&2; exit 3; }

exec "$PY" "$(dirname "$0")/../lib/harness_fingerprint.py" "$ROOT" ${EXTRA[@]+"${EXTRA[@]}"}
