#!/usr/bin/env bash
# In KPI don bay: Nen, hieu qua token, so lan nguoi sua AI (F5). Doi xung voi kpi-report.ps1 (C7).
#
# Wrapper mong quanh harness_kpi.py: ca hai shell goi CHUNG mot file Python, nen khong
# co hai ban cai dat de troi khoi nhau -- dung ly do codex_collect.py duoc tach
# ra o v1.7.0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/harness_kpi.py"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ARGS=()

usage() {
    echo "usage: $(basename "$0") [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--json]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)    ARGS+=(--since "${2:-}"); shift 2 ;;
        --until)    ARGS+=(--until "${2:-}"); shift 2 ;;
        --json)     ARGS+=(--json); shift ;;
        -r|--root)  ROOT="${2:-}"; shift 2 ;;
        -h|--help)  usage ;;
        *) echo "tham so la: $1" >&2; usage ;;
    esac
done

[ -f "$LIB" ] || { echo "khong thay harness_kpi.py tai: $LIB" >&2; exit 1; }
PY_BIN="python3"
command -v "$PY_BIN" >/dev/null 2>&1 || PY_BIN="python"
command -v "$PY_BIN" >/dev/null 2>&1 || { echo "khong tim thay python3" >&2; exit 1; }

set +e
"$PY_BIN" "$LIB" "$ROOT" "${ARGS[@]+"${ARGS[@]}"}"
code=$?
set -e
# kpi-report chi in bao cao: moi ma khac 0 deu la loi that.
if [ $code -ne 0 ]; then echo "kpi-report that bai (exit $code)" >&2; fi
exit $code
