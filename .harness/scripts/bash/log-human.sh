#!/usr/bin/env bash
# Ghi mot khoi cong suc CUA NGUOI vao telemetry (F4). Doi xung voi log-human.ps1.
#
# -m/--minutes la so phut NGUOI that su ngoi lam. Khong bao gio suy tu thoi luong
# phien, tu latency_ms hay tu token.
# -e/--edits dem so lan ban sua lai thu AI lam ra vi no sai/thieu/lech huong.
#
#   ./log-human.sh -m 95 -e 6 -t "F4 telemetry"
#   ./log-human.sh -m 40 -e 0 --unplanned -n "doc lai spec"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/harness_human_log.py"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

MIN=""; EDITS=""; TASK=""; DATE=""; NOTE=""; BREF=""
SESSION="${CLAUDE_SESSION_ID:-}"
REWORK=""; UNPLANNED=""

usage() {
    echo "usage: $(basename "$0") -m MINUTES -e EDITS [-t TASK] [-s SESSION_ID]" >&2
    echo "                        [-d YYYY-MM-DD] [-n NOTE] [--rework] [--unplanned]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -m|--minutes)   MIN="${2:-}"; shift 2 ;;
        -e|--edits)     EDITS="${2:-}"; shift 2 ;;
        -t|--task)      TASK="${2:-}"; shift 2 ;;
        -s|--session-id) SESSION="${2:-}"; shift 2 ;;
        -d|--date)      DATE="${2:-}"; shift 2 ;;
        -n|--note)      NOTE="${2:-}"; shift 2 ;;
        -b|--baseline-ref) BREF="${2:-}"; shift 2 ;;
        --rework)       REWORK="1"; shift ;;
        --unplanned)    UNPLANNED="1"; shift ;;
        -r|--root)      ROOT="${2:-}"; shift 2 ;;
        -h|--help)      usage ;;
        *) echo "tham so la: $1" >&2; usage ;;
    esac
done

[ -n "$MIN" ] || { echo "thieu -m/--minutes" >&2; usage; }
[ -n "$EDITS" ] || { echo "thieu -e/--edits (dung 0 neu that su khong sua gi)" >&2; usage; }
[ -f "$LIB" ] || { echo "khong thay harness_human_log.py tai: $LIB" >&2; exit 1; }

PY="python3"
command -v "$PY" >/dev/null 2>&1 || PY="python"
command -v "$PY" >/dev/null 2>&1 || { echo "khong tim thay python3" >&2; exit 1; }

ARGS=("$LIB" "$ROOT" --minutes "$MIN" --edits "$EDITS")
[ -n "$TASK" ]    && ARGS+=(--task "$TASK")
[ -n "$SESSION" ] && ARGS+=(--session-id "$SESSION")
[ -n "$DATE" ]    && ARGS+=(--date "$DATE")
[ -n "$NOTE" ]    && ARGS+=(--note "$NOTE")
[ -n "$BREF" ]    && ARGS+=(--baseline-ref "$BREF")
[ -n "$REWORK" ]  && ARGS+=(--rework)
[ -n "$UNPLANNED" ] && ARGS+=(--unplanned)

exec "$PY" "${ARGS[@]}"
