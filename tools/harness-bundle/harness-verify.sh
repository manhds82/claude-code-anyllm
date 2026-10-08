#!/usr/bin/env bash
# Harness "doctor" (POSIX parity of harness-verify.ps1). Verifies a project has
# the governance bundle applied correctly: reads .harness/.bundle-manifest.json,
# checks every file present + hash-matches, checks .claude/settings.json uses the
# current hook schema and its guard script exists.
# Exit 0 = healthy; 1 = problems. "modified" files are reported, not fatal.
#
#   ./harness-verify.sh --target <project>   # default: current dir
set -euo pipefail

TARGET="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -d "$TARGET" ]] || { echo "target not found: $TARGET" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[[ -n "$PY" ]] || { echo "python3 required" >&2; exit 3; }

"$PY" - "$TARGET" <<'PY'
import json, hashlib, os, re, sys
target = os.path.abspath(sys.argv[1])
print("== Harness verify: %s" % target)

receipt = os.path.join(target, ".harness", ".bundle-manifest.json")
if not os.path.exists(receipt):
    print("  [X] NOT INSTALLED -- no receipt (.harness/.bundle-manifest.json).")
    print("      Install first: install.sh --bundle <x.bundle.json> --target %s" % target)
    sys.exit(1)
r = json.load(open(receipt, encoding="utf-8-sig"))
print("  bundle: %s v%s  installed_at=%s" % (r["name"], r["version"], r.get("installed_at")))

def sha(b): return hashlib.sha256(b).hexdigest()

def norm_eol(b):
    """BOM and CRLF stripped: a core.autocrlf checkout or a Windows editor changes
    these and nothing else, and that is not drift. install.* does the same."""
    if b[:3] == b"\xef\xbb\xbf": b = b[3:]
    return b.replace(b"\r\n", b"\n")

def eol_hashes(b):
    """Raw, LF with the BOM kept, LF with it stripped: the receipt hashes the
    shipped bytes (LF, BOM on most .ps1), so a BOM'd .ps1 checked out as CRLF
    matches only the middle form (B-77)."""
    return {sha(b), sha(b.replace(b"\r\n", b"\n")), sha(norm_eol(b))}

ok = 0; missing = []; modified = []; unverifiable = []
by_state = {"conflict": [], "skipped": [], "kept": []}
for f in r["files"]:
    # Receipts older than per-file states carry none: every file was claimed installed.
    st = f.get("state") or "installed"
    if st in by_state:
        # Not drift of an installed file: the last install deliberately did not
        # put the shipped bytes here. Say what it is.
        by_state[st].append(f["path"]); continue
    dest = os.path.join(target, *f["path"].split("/"))
    if not os.path.exists(dest): missing.append(f["path"]); continue
    want = {h for h in (f.get("sha256"), f.get("installed_sha256")) if h and h != "unknown"}
    if not want: unverifiable.append(f["path"]); continue
    data = open(dest, "rb").read()
    if want & eol_hashes(data): ok += 1
    else: modified.append(f["path"])
print("  files: %d OK / %d modified / %d missing  (of %d)" % (ok, len(modified), len(missing), len(r["files"])))
if r.get("status") == "partial":
    print("  receipt status: PARTIAL -- the last install did not apply every file")
for m in missing: print("     [MISSING] %s" % m)
for m in modified: print("     [modified] %s" % m)
for m in by_state["conflict"]: print("     [conflict] %s" % m)
for m in by_state["skipped"]: print("     [skipped] %s" % m)
for m in by_state["kept"]: print("     [kept] %s" % m)
if unverifiable: print("  %d file(s) carry no hash to compare (empty file or unknown): %s" % (len(unverifiable), ", ".join(unverifiable)))

hooks_wired = False; hook_msg = ""
sp = os.path.join(target, ".claude", "settings.json")
if not os.path.exists(sp):
    hook_msg = "no .claude/settings.json"
else:
    s = json.load(open(sp, encoding="utf-8"))
    pre = s.get("hooks", {}).get("PreToolUse")
    if pre is None:
        hook_msg = "no PreToolUse hook"
    elif isinstance(pre, str):
        hook_msg = "OLD bare-path format -> hooks will NOT fire (re-install settings.json)"
    else:
        cmd = pre[0]["hooks"][0]
        arg = [a for a in cmd.get("args", []) if not a.startswith("-")]
        rel = re.sub(r"^(\./)+", "", (arg[-1] if arg else "").replace("${CLAUDE_PROJECT_DIR}", "."))   # a PREFIX, not lstrip("./"), which eats the dot of ".harness"
        script = os.path.join(target, *rel.split("/"))
        exists = os.path.exists(script)
        hooks_wired = exists
        hook_msg = "array schema OK; interpreter='%s'; guard script %s" % (
            cmd.get("command"), "found" if exists else "MISSING: " + rel)
print("  hooks: %s%s" % ("[OK] " if hooks_wired else "[!] ", hook_msg))

pol = os.path.join(target, ".harness", "uninstall-policy.json")
if os.path.exists(pol):
    p = json.load(open(pol, encoding="utf-8")); print("  uninstall lock: LOCKED (pm='%s')" % p.get("pm"))
else:
    print("  uninstall lock: none")

unresolved = by_state["conflict"] + by_state["skipped"]
healthy = (not missing) and hooks_wired and not unresolved
if healthy:
    extra = (" (with %d locally-modified file(s) -- fine if intentional)" % len(modified)) if modified else ""
    if by_state["kept"]:
        extra += " (%d kept: yours, not overwritten)" % len(by_state["kept"])
    print("== RESULT: APPLIED OK" + extra); sys.exit(0)
print("== RESULT: NOT FULLY APPLIED")
if unresolved: print("   -> %d file(s) the last install did NOT apply (conflict/skipped): resolve the .new copy by hand, or re-run install.sh --force for skipped ones" % len(unresolved))
if missing: print("   -> %d file(s) missing: re-run install.sh" % len(missing))
if not hooks_wired: print("   -> hooks not wired: rm .claude/settings.json then re-run install (or install.sh --force)")
sys.exit(1)
PY
