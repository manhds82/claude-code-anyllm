#!/usr/bin/env bash
# PM lock (POSIX parity of harness-lock.ps1). Sets/clears/reports an approval
# requirement that uninstall.sh/uninstall.ps1 enforce. The code is stored
# salted-SHA-256, never in clear text.
#
# HONESTY (C10): gates the uninstall SCRIPT + audits; not an OS lock. Pair with
# CODEOWNERS + branch protection on .harness/** for merge-time enforcement.
#
#   ./harness-lock.sh --target <project> --action set    --pm "Dau Sy Manh <manhds@>"
#   ./harness-lock.sh --target <project> --action status
#   ./harness-lock.sh --target <project> --action clear   [--approval-code <c>]
set -euo pipefail

TARGET=""; ACTION="status"; PM=""; CODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2;;
    --action) ACTION="$2"; shift 2;;
    --pm) PM="$2"; shift 2;;
    --approval-code) CODE="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$TARGET" && -d "$TARGET/.harness" ]] || { echo "--target must be a project with .harness/ (bundle installed)" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[[ -n "$PY" ]] || { echo "python3 required" >&2; exit 3; }
POLICY="$TARGET/.harness/uninstall-policy.json"

case "$ACTION" in
  status)
    if [[ -f "$POLICY" ]]; then
      "$PY" - "$POLICY" <<'PY'
import json,sys; p=json.load(open(sys.argv[1],encoding="utf-8"))
print("[lock] LOCKED. require_approval=%s pm='%s' since=%s" % (p.get("require_approval"), p.get("pm"), p.get("created_at")))
PY
    else echo "[lock] not locked (uninstall needs only interactive confirmation)."; fi
    ;;
  set)
    [[ -n "$PM" ]] || { echo "set requires --pm '<name/email>'" >&2; exit 2; }
    read -r -s -p "Set uninstall approval code (hidden): " C1; echo
    read -r -s -p "Re-enter the code: " C2; echo
    [[ -n "$C1" && "$C1" == "$C2" ]] || { echo "empty or mismatched code." >&2; exit 1; }
    CODE="$C1" PM="$PM" POLICY="$POLICY" "$PY" - <<'PY'
import os,json,hashlib,base64,datetime
salt=os.urandom(16)
h=hashlib.sha256(salt+os.environ["CODE"].encode("utf-8")).hexdigest()
pol={"require_approval":True,"pm":os.environ["PM"],
     "created_at":datetime.datetime.now().astimezone().isoformat(),
     "salt":base64.b64encode(salt).decode(),"hash":h}
open(os.environ["POLICY"],"w",encoding="utf-8").write(json.dumps(pol,indent=2))
PY
    echo "[lock] LOCKED for '$PM'. uninstall now needs --approval-code."
    echo "[lock] Tip: also add CODEOWNERS + branch protection on .harness/** for merge-time enforcement."
    ;;
  clear)
    [[ -f "$POLICY" ]] || { echo "[lock] already not locked."; exit 0; }
    if [[ -z "$CODE" ]]; then read -r -s -p "Approval code to clear the lock: " CODE; echo; fi
    OK="$(CODE="$CODE" POLICY="$POLICY" "$PY" - <<'PY'
import os,json,hashlib,base64
p=json.load(open(os.environ["POLICY"],encoding="utf-8"))
salt=base64.b64decode(p["salt"])
print("YES" if hashlib.sha256(salt+os.environ["CODE"].encode("utf-8")).hexdigest()==p["hash"] else "NO")
PY
)"
    [[ "$OK" == "YES" ]] || { echo "Approval code does not match. Lock NOT cleared." >&2; exit 1; }
    rm -f "$POLICY"; echo "[lock] cleared."
    ;;
  *) echo "unknown --action: $ACTION (set|clear|status)" >&2; exit 2;;
esac
