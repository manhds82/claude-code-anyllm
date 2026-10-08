#!/usr/bin/env bash
# Harness Bundle uninstaller (POSIX parity of uninstall.ps1). Removes exactly the
# files the bundle installed (reads the manifest); keeps files edited since
# install (or backs them up with --force); honors a PM lock; audits every attempt.
#
# HONESTY (C10): a local deterrent + audit trail, NOT an OS lock. Real
# enforcement = CODEOWNERS + branch protection on .harness/** .claude/**.
#
#   ./uninstall.sh --target <project> [--bundle <x.bundle.json>] [--approval-code <c>] [--purge] [--force]
set -euo pipefail

TARGET=""; BUNDLE=""; CODE=""; PURGE=0; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2;;
    --bundle) BUNDLE="$2"; shift 2;;
    --approval-code) CODE="$2"; shift 2;;
    --purge) PURGE=1; shift;;
    --force) FORCE=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$TARGET" && -d "$TARGET" ]] || { echo "--target <existing project dir> required" >&2; exit 2; }

# Resolve what to remove: --bundle (b64) > install receipt (sha256) > sibling.
RECEIPT="$TARGET/.harness/.bundle-manifest.json"
if [[ -n "$BUNDLE" ]]; then
  SRC_MODE="bundle"; SRC="$BUNDLE"
elif [[ -f "$RECEIPT" ]]; then
  SRC_MODE="receipt"; SRC="$RECEIPT"
else
  SRC="$(ls -1t "$(dirname "$0")"/*.bundle.json 2>/dev/null | head -1 || true)"; SRC_MODE="bundle"
fi
[[ -n "${SRC:-}" && -f "$SRC" ]] || { echo "no --bundle, no install receipt (.harness/.bundle-manifest.json), no sibling *.bundle.json" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[[ -n "$PY" ]] || { echo "python3 required" >&2; exit 3; }

LEAF="$(basename "$TARGET")"
POLICY="$TARGET/.harness/uninstall-policy.json"

# --- Gate: PM lock OR interactive confirm ---
if [[ -f "$POLICY" ]]; then
  # Delegate approval check to python (salted SHA-256). Prints OK/DENY.
  VERDICT="$("$PY" - "$POLICY" "$CODE" <<'PY'
import json, hashlib, base64, sys
pol = json.load(open(sys.argv[1], encoding="utf-8"))
code = sys.argv[2]
if not pol.get("require_approval"):
    print("OK"); sys.exit(0)
if not code:
    print("DENY:no-code:%s" % pol.get("pm","")); sys.exit(0)
salt = base64.b64decode(pol["salt"])
h = hashlib.sha256(salt + code.encode("utf-8")).hexdigest()
print("OK" if h == pol["hash"] else "DENY:bad-code:%s" % pol.get("pm","")); sys.exit(0)
PY
)"
  if [[ "$VERDICT" != OK* ]]; then
    echo "[uninstall] REFUSED — PM lock (${VERDICT#DENY:})." >&2
    echo "{\"type\":\"bundle_uninstall\",\"event\":\"denied\",\"target\":\"$TARGET\",\"detail\":\"$VERDICT\"}" \
      >> "$TARGET/harness-uninstall-$(date +%Y%m%d-%H%M%S).log"
    exit 1
  fi
  echo "[uninstall] PM approval OK."
elif [[ "$FORCE" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    echo "No PM lock and no TTY. Re-run with --force (or in an interactive shell to confirm)." >&2; exit 1
  fi
  read -r -p "Type the project folder name '$LEAF' to confirm uninstall: " ans
  [[ "$ans" == "$LEAF" ]] || { echo "Confirmation failed. Aborted."; exit 1; }
fi

# --- Remove exactly the installed files (keep/back up user-modified) ---
"$PY" - "$SRC" "$SRC_MODE" "$TARGET" "$FORCE" "$PURGE" <<'PY'
import json, base64, hashlib, os, shutil, sys, datetime
src, mode, target, force, purge = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]=="1", sys.argv[5]=="1"
d = json.load(open(src, encoding="utf-8"))
removed = kept = absent = 0
backup = os.path.join(target, ".harness-uninstall-backup")
for f in d["files"]:
    dest = os.path.join(target, *f["path"].split("/"))
    if not os.path.exists(dest): absent += 1; continue
    cur = hashlib.sha256(open(dest, "rb").read()).hexdigest()
    orig = f["sha256"] if mode == "receipt" else hashlib.sha256(base64.b64decode(f["b64"])).hexdigest()
    if cur == orig:
        os.remove(dest); removed += 1
    elif force:
        bkp = os.path.join(backup, *f["path"].split("/"))
        os.makedirs(os.path.dirname(bkp), exist_ok=True); shutil.copy2(dest, bkp)
        os.remove(dest); removed += 1
    else:
        print("  [KEPT] %s (modified since install; --force to back up + remove)" % f["path"]); kept += 1
if purge:
    for rt in (".harness/ledger", ".harness/telemetry"):
        p = os.path.join(target, *rt.split("/"))
        if os.path.isdir(p): shutil.rmtree(p); print("  [PURGE] %s" % rt)
for gone in ("uninstall-policy.json", ".bundle-manifest.json"):
    p = os.path.join(target, ".harness", gone)
    if os.path.exists(p): os.remove(p)
for d2 in ("contracts", ".claude", ".harness"):
    p = os.path.join(target, d2)
    if os.path.isdir(p) and not any(fn for _,_,fs in os.walk(p) for fn in fs):
        shutil.rmtree(p)
rec = os.path.join(target, "harness-uninstall-%s.log" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
open(rec, "a", encoding="utf-8").write(
    '{"type":"bundle_uninstall","event":"completed","bundle":"%s","removed":%d,"kept":%d,"purge":%s}\n'
    % (d["name"], removed, kept, str(purge).lower()))
print("[uninstall] done: %d removed, %d kept (modified), %d already absent." % (removed, kept, absent))
if kept: print("[uninstall] %d modified file(s) left; --force to remove (backed up to .harness-uninstall-backup)." % kept)
print("[uninstall] audit receipt: %s" % rec)
PY
