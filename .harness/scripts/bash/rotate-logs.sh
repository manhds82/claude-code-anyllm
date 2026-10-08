#!/usr/bin/env bash
# D9 (bash parity of rotate-logs.ps1): size-based rotation of the
# security-events telemetry log. Does NOT touch the append-only ledger
# chain.jsonl (rotating it would break the hash-chain verification).
#
#   HARNESS_ROOT=/path/to/repo ./rotate-logs.sh [max_mb] [retain]
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
MAX_MB="${1:-50}"
RETAIN="${2:-10}"

LOG="$HARNESS_ROOT/.harness/telemetry/security-events.jsonl"
if [[ ! -f "$LOG" ]]; then
  echo "[rotate] no log at $LOG (nothing to do)"
  exit 0
fi

SIZE_MB=$(( $(wc -c < "$LOG") / 1048576 ))
if (( SIZE_MB < MAX_MB )); then
  echo "[rotate] ${SIZE_MB} MB < ${MAX_MB} MB threshold, skip"
  exit 0
fi

DIR="$(dirname "$LOG")"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
ARCHIVE="$DIR/security-events-$STAMP.jsonl.gz"

gzip -c "$LOG" > "$ARCHIVE"
: > "$LOG"   # truncate live log in place so appenders keep writing
echo "[rotate] archived -> $ARCHIVE and truncated live log"

# Retention: keep newest $RETAIN archives.
ls -1t "$DIR"/security-events-*.jsonl.gz 2>/dev/null | tail -n +$((RETAIN + 1)) | while read -r old; do
  echo "[rotate] prune $(basename "$old")"
  rm -f "$old"
done
echo "[rotate] done (retain=$RETAIN)"
