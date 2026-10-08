#!/usr/bin/env bash
# Cong hieu (F6) -- cong duy nhat may khong dung thay nguoi duoc. Doi xung voi comprehension-gate.ps1 (C7).
#
# Wrapper mong quanh harness_comprehension.py: ca hai shell goi CHUNG mot file Python, nen khong
# co hai ban cai dat de troi khoi nhau -- dung ly do codex_collect.py duoc tach
# ra o v1.7.0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/harness_comprehension.py"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ARGS=()

usage() {
    echo "usage: $(basename "$0") --check" >&2
    echo "       $(basename "$0") --tier high --restate \"...\" --ai-error \"...\" [--ref ID]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)    ARGS+=(--check); shift ;;
        --tier)     ARGS+=(--tier "${2:-}"); shift 2 ;;
        --restate)  ARGS+=(--restate "${2:-}"); shift 2 ;;
        --ai-error) ARGS+=(--ai-error "${2:-}"); shift 2 ;;
        --ref)      ARGS+=(--ref "${2:-}"); shift 2 ;;
        -r|--root)  ROOT="${2:-}"; shift 2 ;;
        -h|--help)  usage ;;
        *) echo "tham so la: $1" >&2; usage ;;
    esac
done

[ -f "$LIB" ] || { echo "khong thay harness_comprehension.py tai: $LIB" >&2; exit 1; }
PY_BIN="python3"
command -v "$PY_BIN" >/dev/null 2>&1 || PY_BIN="python"
command -v "$PY_BIN" >/dev/null 2>&1 || { echo "khong tim thay python3" >&2; exit 1; }

set +e
"$PY_BIN" "$LIB" "$ROOT" "${ARGS[@]+"${ARGS[@]}"}"
code=$?
set -e
# exit 1 la KET QUA (chua qua cong), khong phai loi script.
if [ $code -gt 1 ]; then echo "comprehension-gate that bai (exit $code)" >&2; fi
exit $code
