#!/usr/bin/env bash
# RTM (F7): story nao trong spec khong co test nao nhac toi? Doi xung voi rtm-check.ps1 (C7).
#
# Wrapper mong quanh harness_rtm.py: ca hai shell goi CHUNG mot file Python, nen khong
# co hai ban cai dat de troi khoi nhau -- dung ly do codex_collect.py duoc tach
# ra o v1.7.0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/harness_rtm.py"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ARGS=()

usage() {
    echo "usage: $(basename "$0") [--spec PATH] [--tests DIR] [--id-prefix US-] [--json] [--fail-on-gap]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --spec)      ARGS+=(--spec "${2:-}"); shift 2 ;;
        --tests)     ARGS+=(--tests "${2:-}"); shift 2 ;;
        --id-prefix) ARGS+=(--id-prefix "${2:-}"); shift 2 ;;
        --json)      ARGS+=(--json); shift ;;
        --fail-on-gap) ARGS+=(--fail-on-gap); shift ;;
        -r|--root)  ROOT="${2:-}"; shift 2 ;;
        -h|--help)  usage ;;
        *) echo "tham so la: $1" >&2; usage ;;
    esac
done

[ -f "$LIB" ] || { echo "khong thay harness_rtm.py tai: $LIB" >&2; exit 1; }
PY_BIN="python3"
command -v "$PY_BIN" >/dev/null 2>&1 || PY_BIN="python"
command -v "$PY_BIN" >/dev/null 2>&1 || { echo "khong tim thay python3" >&2; exit 1; }

set +e
"$PY_BIN" "$LIB" "$ROOT" "${ARGS[@]+"${ARGS[@]}"}"
code=$?
set -e
# exit 1 la KET QUA (con GAP), khong phai loi script -- giong rtm-check.ps1.
if [ $code -gt 1 ]; then echo "rtm-check that bai (exit $code)" >&2; fi
exit $code
