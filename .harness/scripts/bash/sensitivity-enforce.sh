#!/usr/bin/env bash
# Bat / tat cuong che F2 (sensitivity) o hook PreToolUse cho MOT du an.
# Doi xung voi sensitivity-enforce.ps1 (C7).
#
# Doi mot co duy nhat: enforce_at_pretooluse trong sensitive-paths.json.
#
# Sua DUNG MOT DONG bang sed, khong doc-roi-ghi-lai ca JSON: mot bo serialize
# khac se sap xep lai khoa va doi indent, bien thay doi mot-bit thanh diff toan
# file. Ban PowerShell lam y het bang regex, vi cung mot ly do.
#
#   ./sensitivity-enforce.sh --project /path/to/repo --status
#   ./sensitivity-enforce.sh --project /path/to/repo --on
#   ./sensitivity-enforce.sh --project /path/to/repo --off
set -euo pipefail

PROJECT=""; ACTION="status"

usage() {
    echo "usage: $(basename "$0") --project <duong dan> [--status|--on|--off]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project) PROJECT="${2:-}"; shift 2 ;;
        --on)         ACTION="on"; shift ;;
        --off)        ACTION="off"; shift ;;
        --status)     ACTION="status"; shift ;;
        -h|--help)    usage ;;
        *) echo "tham so la: $1" >&2; usage ;;
    esac
done

[ -n "$PROJECT" ] || { echo "thieu --project" >&2; usage; }
[ -d "$PROJECT" ] || { echo "khong thay thu muc du an: $PROJECT" >&2; exit 1; }

CFG="$PROJECT/.harness/control/sensitive-paths.json"
if [ ! -f "$CFG" ]; then
    echo "Du an nay CHUA co $CFG" >&2
    echo "" >&2
    echo "Nghia la harness chua duoc cai, hoac bundle cai vao con cu hon F2." >&2
    echo "Cai bundle truoc, roi chay lai." >&2
    exit 1
fi

cur="false"
grep -qE '"enforce_at_pretooluse"[[:space:]]*:[[:space:]]*true' "$CFG" && cur="true"

if [ "$ACTION" = "status" ]; then
    rules=$(grep -cE '^[[:space:]]*"id"[[:space:]]*:' "$CFG" || true)
    echo ""
    echo "  Du an   : $PROJECT"
    echo "  Cuong che F2 o PreToolUse : $(echo "$cur" | tr '[:lower:]' '[:upper:]')"
    echo "  So rule : $rules"
    echo ""
    echo "  Xem truoc file nao se bi chan:"
    echo "    python3 \"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/harness_sensitivity.py\" \"$PROJECT\" --scan"
    echo ""
    exit 0
fi

new="false"; [ "$ACTION" = "on" ] && new="true"
if [ "$new" = "$cur" ]; then
    echo "Da o trang thai do roi (enforce_at_pretooluse = $cur). Khong doi gi."
    exit 0
fi

grep -qE '"enforce_at_pretooluse"' "$CFG" || {
    echo "Khong tim thay khoa enforce_at_pretooluse trong $CFG" >&2; exit 1; }

tmp="$(mktemp)"
sed -E "0,/(\"enforce_at_pretooluse\"[[:space:]]*:[[:space:]]*)(true|false)/s//\\1$new/" "$CFG" > "$tmp"
mv "$tmp" "$CFG"

# Doc lai va kiem: mot config hong vi chinh script bat cong la kieu that bai te
# nhat -- cong trong nhu dang chay ma thuc te hook fail-open cho qua tat ca.
check="false"
grep -qE '"enforce_at_pretooluse"[[:space:]]*:[[:space:]]*true' "$CFG" && check="true"
[ "$check" = "$new" ] || { echo "Ghi xong nhung doc lai khong khop. Kiem tay: $CFG" >&2; exit 1; }

echo ""
if [ "$new" = "true" ]; then
    echo "  BAT cuong che F2 cho $PROJECT"
    echo "  Tu gio moi lenh GHI vao file nhay cam se bi chan, doi nguoi duyet."
else
    echo "  TAT cuong che F2 cho $PROJECT"
    echo "  gatekeeper van doc rule de nang bac rui ro (advisory), nhung hook khong chan."
fi
echo ""
