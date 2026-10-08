#!/usr/bin/env bash
# Push local .harness telemetry to the Control Portal (bash parity of
# push-telemetry.ps1). For checkouts the Portal backend cannot read directly.
# Config: .harness/portal-sync.json {portal_url, project_id}; key via env
# HARNESS_PORTAL_INGEST_KEY or git-ignored .harness/portal-sync.key (C5).
# Idempotent: server-side dedupe makes re-pushing the same files safe.
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
CONFIG="$HARNESS_ROOT/.harness/portal-sync.json"

# Codex usage, collected HERE rather than only at Claude session end (B9b).
#
# Same reasoning as the self-healing resample below: capture usage even if the
# hook never fired. For Codex that is the normal case, not an edge case -- Codex
# has no hook at all, so its only trigger was a CLAUDE session ending in this
# same project. A project worked on with Codex only would have reported nothing
# forever, while the collector sat installed and looking fine.
#
# In the pusher, so every caller is covered at once: the session-end hook, the
# fleet driver on its timer (needing no Claude), and a manual push (B-13/B-14:
# repeated copies drift).
#
# BEFORE the config checks below, all of which exit 0 on an unconfigured
# project: collecting is local work worth doing either way, so the data is
# waiting the moment someone wires the project up rather than being lost.
# `|| true` because `set -e` is on and a collector must never fail the push.
if [ -f "$HARNESS_ROOT/.harness/scripts/bash/collect-codex.sh" ]; then
    HARNESS_ROOT="$HARNESS_ROOT" bash "$HARNESS_ROOT/.harness/scripts/bash/collect-codex.sh" >/dev/null 2>&1 || true
fi

if [ ! -f "$CONFIG" ]; then
    echo "[push-telemetry] No .harness/portal-sync.json -- push sync not configured, skipping."
    exit 0
fi

KEY="${HARNESS_PORTAL_INGEST_KEY:-}"
if [ -z "$KEY" ] && [ -f "$HARNESS_ROOT/.harness/portal-sync.key" ]; then
    KEY="$(tr -d '[:space:]' < "$HARNESS_ROOT/.harness/portal-sync.key")"
fi
# No early exit on an empty key: a machine holding a CHECKOUT credential
# (.harness/local/checkout.json, resolved in python -- a worktree uses its
# parent's) needs no shared key. python decides and says what is missing.

# --heartbeat: send only "this checkout is alive and what it looks like" (P1 1.3).
HEARTBEAT=0
if [ "${1:-}" = "--heartbeat" ]; then HEARTBEAT=1; fi

HARNESS_PUSH_HEARTBEAT="$HEARTBEAT" HARNESS_PUSH_KEY="$KEY" HARNESS_PUSH_ROOT="$HARNESS_ROOT" HARNESS_PUSH_CONFIG="$CONFIG" python3 - <<'PY' || true
import json, os, re, sys, time, glob, urllib.request, urllib.error
from datetime import datetime, timezone

root = os.environ["HARNESS_PUSH_ROOT"]
cfg = json.load(open(os.environ["HARNESS_PUSH_CONFIG"], encoding="utf-8-sig"))
url = cfg.get("portal_url", "").rstrip("/")
pid = cfg.get("project_id", "")
if not url or not pid:
    print("[push-telemetry] portal-sync.json missing portal_url/project_id", file=sys.stderr)
    sys.exit(0)
# The installer scaffolds this placeholder; left unfilled it fails as a DNS
# error, which reads as a network problem and sends whoever is looking at the
# wrong thing entirely. Say what is actually wrong (PS parity: push-telemetry.ps1).
if "YOUR-PORTAL-DOMAIN" in url:
    print("[push-telemetry] portal_url is still the installer placeholder (%s) -- "
          "fill in .harness/portal-sync.json" % url, file=sys.stderr)
    sys.exit(0)

# Checkout identity (Portal v2 P1 1.3). One shared lib computes what this folder
# can say about itself, so this script and push-telemetry.ps1 cannot drift on the
# payload. Best-effort: no lib = no facts and the push goes out as before.
facts = {}
_fm = None
try:
    import importlib.util as _ilu0
    _fp = os.path.join(root, ".harness", "scripts", "lib", "harness_checkout_facts.py")
    if os.path.isfile(_fp):
        _fs = _ilu0.spec_from_file_location("harness_checkout_facts", _fp)
        _fm = _ilu0.module_from_spec(_fs); _fs.loader.exec_module(_fm)
        facts = _fm.facts(root) or {}
except Exception:
    facts = {}
auth = facts.pop("auth", None) or {}
if auth.get("checkout_id") and auth.get("checkout_credential"):
    # Bound push: the credential names the checkout; the legacy key is not sent.
    auth_headers = {"X-Checkout-Id": auth["checkout_id"], "X-Checkout-Credential": auth["checkout_credential"]}
elif os.environ.get("HARNESS_PUSH_KEY"):
    auth_headers = {"X-Ingest-Key": os.environ["HARNESS_PUSH_KEY"]}
    # Legacy path (no checkout enrolled on this machine): at most one line a day per machine
    # via the shared stamp (C14), never per push. Names no key.
    try:
        _w = _fm.legacy_warning("push-telemetry") if _fm else ""
        if _w:
            print(_w, file=sys.stderr)
    except Exception:
        pass
else:
    print("[push-telemetry] No checkout credential (.harness/local/checkout.json) and no ingest key "
          "(env HARNESS_PORTAL_INGEST_KEY or .harness/portal-sync.key)", file=sys.stderr)
    sys.exit(0)
# The claims a push makes about its machine. The server COMPARES them with what it
# holds for the credential; it never uses them to pick the checkout.
claims = {k: v for k, v in facts.items() if k in (
    "checkout_id", "device_id", "path_hash", "receipt", "receipt_at_head", "disk_fingerprint",
    "git_remote", "git_branch", "git_head", "git_dirty", "worktree")}

if os.environ.get("HARNESS_PUSH_HEARTBEAT") == "1":
    if "X-Checkout-Credential" not in auth_headers:
        print("[push-telemetry] heartbeat needs a checkout credential (.harness/local/checkout.json) -- skipped.")
        sys.exit(0)
    _hb = urllib.request.Request(
        f"{url}/api/ingest/{pid}/heartbeat", data=json.dumps(claims).encode("utf-8"),
        headers={"Content-Type": "application/json; charset=utf-8", "User-Agent": "harness-push-telemetry/1.0",
                 **auth_headers}, method="POST")
    try:
        with urllib.request.urlopen(_hb, timeout=30) as _r:
            _h = json.loads(_r.read())
        print("[push-telemetry] %s" % (_h.get("note") if _h.get("quarantined") else "heartbeat OK"))
    except (urllib.error.URLError, OSError, ValueError) as e:
        print("[push-telemetry] Heartbeat failed: %s" % e, file=sys.stderr)
    sys.exit(0)

# Self-healing resample: rebuild agentops.log from this project's Claude Code
# transcripts (case-insensitive drive letter, recursive incl. subagents) so
# usage is captured even if the SessionEnd sampler never ran.
#
# Read-merge-write, NOT blind overwrite: agentops-sampler.sh (SubagentStop
# hook) already stamps active_account/active_member onto rows it writes live.
# This block only sees raw transcripts, which carry neither field, so a plain
# "w" rebuild from scratch would erase every stamp on every push -- and for a
# plain (non-delegating) main session, this resample is the ONLY writer, since
# the sampler is wired solely to SubagentStop. Fix: read whatever agentops.log
# already has, keyed the same way (session_id:agent_name); a transcript-derived
# row only replaces an existing one when it has STRICTLY MORE tokens (genuine
# "resumed, more happened" case), and only a replaced/new row gets re-stamped
# with the CURRENT pointer/env values -- coarser than a live per-turn stamp,
# but far better than silently blank. Anything the transcript scan doesn't
# touch at all (rotated out of the transcript window) survives untouched.
def _load_existing(fp):
    # Keyed identically to the transcript scan below so the merge lines up.
    # Unparseable lines are skipped, never allowed to crash the resample.
    d = {}
    try:
        with open(fp, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try: rec = json.loads(line)
                except Exception: continue
                sid = rec.get("session_id"); agent = rec.get("agent_name")
                if not sid or not agent: continue
                d[sid + ":" + agent] = rec
    except OSError:
        pass
    return d

def _active_account(home):
    # Same global per-machine pointer harness-switch-account writes; absent or
    # unreadable -> "" so an old client (no such file yet) sees the same blank
    # it always has.
    try:
        p = os.path.join(home, ".harness", "active-account.local.json")
        with open(p, encoding="utf-8-sig") as f:
            return str((json.load(f) or {}).get("active_account") or "")
    except Exception:
        return ""

def _resample():
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE") or os.path.expanduser("~")
    proot = os.path.join(home, ".claude", "projects")
    if not os.path.isdir(proot):
        return
    e = re.sub(r"[:\\/._]", "-", root).lower()
    dirs = [d for d in glob.glob(os.path.join(proot, "*")) if os.path.isdir(d)
            and (os.path.basename(d).lower() == e or os.path.basename(d).lower().startswith(e + "-"))]
    def samp(fp):
        tin = tout = tools = 0; model = ""; first = last = None; by = {}
        try:
            with open(fp, encoding="utf-8-sig") as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try: rec = json.loads(line)
                    except Exception: continue
                    ts = rec.get("timestamp")
                    if ts: first = first or ts; last = ts
                    if rec.get("type") != "assistant": continue
                    msg = rec.get("message") or {}
                    if not isinstance(msg, dict): continue
                    u = msg.get("usage"); mid = msg.get("id")
                    if u and mid: by[mid] = u
                    m = msg.get("model")
                    if m and m != "<synthetic>": model = m
                    for b in (msg.get("content") or []):
                        if isinstance(b, dict) and b.get("type") == "tool_use": tools += 1
        except OSError:
            return None
        for u in by.values():
            tin += int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0)
            tout += int(u.get("output_tokens") or 0)
        if tin == 0 and tout == 0 and not model: return None
        return {"tin": tin, "tout": tout, "tools": tools, "model": model or "unknown", "first": first, "last": last}
    entries = {}
    for d in dirs:
        for fp in glob.glob(os.path.join(d, "**", "*.jsonl"), recursive=True):
            sid = os.path.splitext(os.path.basename(fp))[0]
            r = samp(fp)
            if not r: continue
            agent = "subagent" if (os.sep + "subagents" + os.sep) in fp else "main"
            k = sid + ":" + agent
            prev = entries.get(k)
            if prev and (prev["tin"] + prev["tout"]) >= (r["tin"] + r["tout"]): continue
            r["sid"] = sid; r["agent"] = agent; entries[k] = r
    if not entries:
        return
    tel = os.path.join(root, ".harness", "telemetry"); os.makedirs(tel, exist_ok=True)
    log_path = os.path.join(tel, "agentops.log")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    active_account = _active_account(home)
    active_member = os.environ.get("HARNESS_USER") or ""
    # Union base: every row the current file already has, so anything the
    # transcript scan above has no key for is preserved untouched.
    merged = _load_existing(log_path)
    for r in entries.values():
        k = r["sid"] + ":" + r["agent"]
        old_rec = merged.get(k)
        new_tokens = r["tin"] + r["tout"]
        if old_rec is not None:
            old_tokens = int(old_rec.get("tokens_in") or 0) + int(old_rec.get("tokens_out") or 0)
            if old_tokens >= new_tokens:
                continue  # existing row (and its active_account/active_member) survives untouched
        cost = r["tin"] / 1e6 * 3.0 + r["tout"] / 1e6 * 15.0
        merged[k] = {
            "timestamp": now, "agent_name": r["agent"], "model": r["model"], "session_id": r["sid"],
            "status": "completed", "tokens_in": r["tin"], "tokens_out": r["tout"],
            "total_tokens": r["tin"] + r["tout"], "estimated_cost_usd": round(cost, 6),
            "latency_ms": 0, "tool_calls": r["tools"],
            "start_time": r["first"] or now, "end_time": r["last"] or now,
            "active_account": active_account, "active_member": active_member,
            # Stamped explicitly (B9a). This block reads CLAUDE CODE transcripts,
            # so the value is a fact about the source, not a default. The ingest
            # would infer the same from a missing field, but then the only rows
            # in the file without a stamp are the ones this resample rebuilt.
            "assistant": "claude-code",
        }
    with open(log_path, "w", encoding="utf-8") as out:
        for rec in merged.values():
            out.write(json.dumps(rec, separators=(",", ":")) + "\n")

try:
    _resample()
except Exception:
    pass

def read(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return f.read()
    except OSError:
        return ""

# --- Incremental send for the append-only logs (POSIX parity of push-telemetry.ps1)
# These files only grow, and the push used to send each one WHOLE every run. This
# repo's own chain.jsonl reached 24.8 MB against the endpoint's 10 MB per-field cap
# and another project's reached 3.0 MB -- and the failure did NOT surface as a clean
# 413. The body was cut off mid-write, so the client reported a network error
# ("connection aborted" / "write operation timed out"). Nobody reading that would
# suspect a size limit, which is why telemetry for the two largest projects had
# been failing silently.
#
# Sending only the tail is safe because every one of these ingests dedupes
# server-side -- chain.jsonl by entry_hash, tool-calls.log by line hash,
# security-events.jsonl by source_ref. An overlapping or even a full re-send can
# never double-count, so the cursor is an optimisation and losing it is harmless.
CURSOR_PATH = os.path.join(root, ".harness", "telemetry", ".push-cursor.json")
MAX_FIELD_BYTES = 4 * 1024 * 1024   # under the server's 10 MB, room for the envelope

try:
    _cursors = json.load(open(CURSOR_PATH, encoding="utf-8"))
    if not isinstance(_cursors, dict):
        _cursors = {}
except Exception:
    _cursors = {}          # unreadable cursor = send from 0; dedupe makes that safe
_cursors_new = {}

# S-3 — content-hash skip for the two payload parts that are SNAPSHOTS rather
# than append-only logs. chain.jsonl and friends grow, so a byte cursor works;
# the CASAN snapshot and the evidence bundles are re-sent WHOLE every push --
# ~2 MB of identical JSON every five minutes on a busy repo. That is the shape
# of cost that gets a sync switched off, and a sync nobody runs is the failure
# the evidence pipeline exists to prevent.
#
# Skipping on an unchanged hash alone would be a one-way door: if the Portal
# ever lost the snapshot, this client would never send it again. So the skip
# EXPIRES -- unchanged content is re-sent in full once a week, which makes the
# optimisation self-healing instead of something a human has to remember.
CONTENT_PATH = os.path.join(root, ".harness", "telemetry", ".push-content.json")
FULL_RESEND_AFTER_S = 7 * 86400
try:
    _content = json.load(open(CONTENT_PATH, encoding="utf-8"))
    if not isinstance(_content, dict):
        _content = {}
except Exception:
    _content = {}          # unreadable state = send everything; correctness never depends on it
_content_new = {}


def content_unchanged(key, payload):
    """True when this exact content was already accepted recently enough that
    re-sending would buy nothing. Records the new hash either way."""
    import hashlib
    h = hashlib.sha256(payload.encode("utf-8", "replace")).hexdigest()
    now = int(time.time())
    _content_new[key] = {"hash": h, "sent_at": now}
    prev = _content.get(key) or {}
    if prev.get("hash") != h:
        return False
    if now - int(prev.get("sent_at") or 0) >= FULL_RESEND_AFTER_S:
        return False
    # Keep the ORIGINAL sent_at so the weekly resend is measured from the last
    # actual send. Refreshing it on every skip would push the deadline forward
    # forever and quietly remove the self-healing property.
    _content_new[key] = {"hash": h, "sent_at": int(prev.get("sent_at") or now)}
    return True


def read_incremental(path, key):
    try:
        size = os.path.getsize(path)
    except OSError:
        return ""
    start = int(_cursors.get(key) or 0)
    # A file shorter than the cursor was rotated or truncated, so the cursor points
    # into a file that no longer exists. Start over rather than read a meaningless
    # offset.
    if start > size:
        start = 0
    take = size - start
    truncated = take > MAX_FIELD_BYTES
    if truncated:
        take = MAX_FIELD_BYTES
    if take <= 0:
        _cursors_new[key] = size
        return ""
    with open(path, "rb") as fh:
        fh.seek(start)
        raw = fh.read(take)
    text = raw.decode("utf-8", errors="replace")
    # Never hand the server a half-written final line: cut back to the last newline
    # and let the remainder go next run. A truncated JSON line would be dropped by
    # the reader anyway, and the cursor would have skipped past it -- losing that
    # entry permanently.
    nl = text.rfind("\n")
    if nl < 0:
        if truncated:
            print("[push-telemetry] %s: one line exceeds %dMB; skipped"
                  % (key, MAX_FIELD_BYTES // (1024 * 1024)))
        _cursors_new[key] = start
        return ""
    text = text[:nl + 1]
    _cursors_new[key] = start + len(text.encode("utf-8"))
    if start > 0 or truncated:
        msg = "[push-telemetry] %s: sending %.1fKB from offset %d of %d" % (
            key, len(text) / 1024.0, start, size)
        if truncated:
            msg += " (capped; remainder goes next run)"
        print(msg)
    return text


def _member_email():
    """Portal v2 P1 1.7: member_email lives in .harness/local/checkout.json (git-ignored); the
    shared reader falls back to the legacy portal-sync.json and says where the value came from
    (C13) -- a legacy or missing value is a warning, never a silent pass."""
    lib = os.path.join(root, ".harness", "scripts", "lib", "harness_local_state.py")
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("harness_local_state", lib)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        r = mod.read_member_email(root)
        if r.get("warning"):
            print("[push-telemetry] WARNING: " + r["warning"])
        return str(r.get("value") or "")
    except Exception:
        v = str(cfg.get("member_email") or "")
        if v:
            print("[push-telemetry] WARNING: member_email read from the legacy .harness/portal-sync.json "
                  "(harness_local_state.py unavailable)")
        return v


body = {
    "agentops": read(os.path.join(root, ".harness", "telemetry", "agentops.log")),
    "chain_jsonl": read_incremental(os.path.join(root, ".harness", "ledger", "chain.jsonl"), "chain.jsonl"),
    "security_events": read_incremental(os.path.join(root, ".harness", "telemetry", "security-events.jsonl"), "security-events.jsonl"),
    "tool_calls": read_incremental(os.path.join(root, ".harness", "telemetry", "tool-calls.log"), "tool-calls.log"),
    "test_reports": read_incremental(os.path.join(root, ".harness", "telemetry", "test-reports.jsonl"), "test-reports.jsonl"),
    # P-7: Agent Pack runs, incremental like the other append-only logs.
    "pipeline_runs": read_incremental(os.path.join(root, ".harness", "telemetry", "pipeline-runs.jsonl"), "pipeline-runs.jsonl"),
    # S-6: the SHAPE of the whole chain, not its contents. chain_jsonl above is
    # incremental, so the server only sees a delta and cannot tell whether the
    # file behind it was rebuilt. Filled in below (best-effort, never blocking).
    "ledger_anchor": "",
    "member_email": _member_email(),
    "buglist": read(os.path.join(root, "buglist.md")),
}

# S-1: the evidence-pipeline self-check, computed here and sent with the push.
# Without this the Portal knows a project's SCORE but not whether its pipeline is
# alive -- the state that only ever existed in a developer's terminal, which is
# how three projects ran for weeks with a dead pipeline whose only symptom was a
# score that would not move. Best-effort: doctor failing must never block the
# telemetry push it rides along with.
# S-6 ledger anchor — computed over the FULL chain here, because the chain in
# the payload is incremental and a delta cannot show that the file behind it was
# rebuilt. Best-effort: an anchor we cannot compute is a visible gap, which is
# the correct outcome; a fabricated one would defeat the mechanism.
try:
    import importlib.util as _ilu2
    _ap = os.path.join(root, ".harness", "scripts", "lib", "harness_ledger_anchor.py")
    if os.path.isfile(_ap):
        _spec = _ilu2.spec_from_file_location("harness_ledger_anchor", _ap)
        _mod = _ilu2.module_from_spec(_spec); _spec.loader.exec_module(_mod)
        _a = _mod.anchor(root)
        if _a:
            body["ledger_anchor"] = json.dumps(_a, separators=(",", ":"))
except Exception:
    pass

body["doctor"] = ""
try:
    import importlib.util as _ilu
    _dp = os.path.join(root, ".harness", "scripts", "lib", "harness_doctor.py")
    if os.path.isfile(_dp):
        _spec = _ilu.spec_from_file_location("harness_doctor", _dp)
        _mod = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_mod)
        body["doctor"] = json.dumps(_mod.as_json(root), ensure_ascii=False)
except Exception as _e:
    print("[push-telemetry] doctor snapshot skipped: %s" % _e)
# H3 — evidence bundles -> prompt_scores
import glob as _glob
bundles = {}
bdir = os.path.join(root, ".harness", "ledger", "bundles")
if os.path.isdir(bdir):
    for bf in _glob.glob(os.path.join(bdir, "*.json")):
        try:
            bundles[os.path.basename(bf)] = open(bf, encoding="utf-8-sig").read()
        except OSError:
            pass
# S-3: the bundle set rarely changes between pushes. Hashed as sorted
# name+content so a rename and an edit both register as a change.
if bundles:
    _bkey = "\n--\n".join("%s\n%s" % (k, bundles[k]) for k in sorted(bundles))
    if content_unchanged("bundles", _bkey):
        print("[push-telemetry] bundles unchanged since last send -- skipped (%d file(s))" % len(bundles))
        bundles = {}
body["bundles"] = bundles
# H1 — source<->doc traceability scan (this repo), via the bundle-installed lib
body["source_doc_map"] = ""
ds = os.path.join(root, ".harness", "scripts", "lib", "harness_docscan.py")
if os.path.isfile(ds):
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("harness_docscan", ds)
        mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        body["source_doc_map"] = json.dumps(mod.scan(root))
    except Exception:
        pass
# CASAN evidence snapshot — a push-based project has no server checkout, so
# harness_root_ref is empty and every machine-checked criterion reads not-met.
# Ship the raw files those checks read; scoring stays server-side, so this can
# only cost the project points, never inflate them.
body["casan_files"] = {}
body["casan_manifest"] = []
body["casan_skipped"] = []
snaplib = os.path.join(root, ".harness", "scripts", "lib", "harness_casan_snapshot.py")
if os.path.isfile(snaplib):
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("harness_casan_snapshot", snaplib)
        mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        snap = mod.snapshot(root)
        body["casan_files"] = snap.get("files") or {}
        body["casan_manifest"] = snap.get("manifest") or []
        # The third state. Without it the server cannot tell a control we
        # deliberately did not send from one the project does not have, and it
        # scores both as not-met — a false RED is as bad as a false GREEN.
        body["casan_skipped"] = snap.get("skipped") or []
        withheld = sum(1 for e in body["casan_skipped"] if e.get("withheld"))
        print("[push-telemetry] CASAN snapshot: %d files, %d manifest entries, %d skipped (%d withheld)" % (
            len(body["casan_files"]), len(body["casan_manifest"]),
            len(body["casan_skipped"]), withheld))
        # S-3: hash the WHOLE snapshot -- files, manifest AND skipped list.
        # Hashing only the files would let a change in the withheld set go
        # unsent, and withheld-vs-absent is the distinction that stops a
        # deliberate omission from scoring as a failure.
        _skey = json.dumps({"f": body["casan_files"], "m": body["casan_manifest"],
                            "s": body["casan_skipped"]}, sort_keys=True)
        if content_unchanged("casan_snapshot", _skey):
            print("[push-telemetry] CASAN snapshot unchanged since last send -- skipped")
            body["casan_files"] = {}
            body["casan_manifest"] = []
            body["casan_skipped"] = []
    except Exception:
        pass

if not any(body.values()):
    print("[push-telemetry] Nothing to push (no telemetry files yet).")
    sys.exit(0)

# Claims are metadata: added only once there is something to push, so they cannot
# turn "nothing new" into a push.
body.update(claims)
if claims.get("worktree"):
    # A worktree pushes into its parent checkout but its chain is its own; the
    # parent anchors the parent's chain.
    body["ledger_anchor"] = ""

req = urllib.request.Request(
    f"{url}/api/ingest/{pid}",
    data=json.dumps(body).encode("utf-8"),
    headers={
        "Content-Type": "application/json; charset=utf-8",
        **auth_headers,
        # Cloudflare's bot rules 403 the default Python-urllib UA; identify
        # ourselves as the harness client instead.
        "User-Agent": "harness-push-telemetry/1.0",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        r = json.loads(resp.read())
    if r.get("quarantined"):
        # Nothing was ingested: do NOT advance the cursors, or the lines in this
        # push would be skipped forever once the cause is fixed.
        print("[push-telemetry] QUARANTINED by the Portal -- %s" % r.get("note", ""), file=sys.stderr)
        sys.exit(0)
    for _w in r.get("warnings") or []:
        print("[push-telemetry] %s" % _w, file=sys.stderr)
    print("[push-telemetry] OK: actions=%s incidents=%s usage=%s tool_calls=%s" % (
        r.get("action_log_ingested", 0), r.get("security_incidents_ingested", 0),
        r.get("usage_events_ingested", 0), r.get("tool_calls_ingested", 0)))
    # Advance the cursors ONLY now. Committing them before the request would mean a
    # failed push permanently skipped those lines -- the ledger would develop a hole
    # no later run could fill, the opposite of what an append-only audit trail is
    # for. Re-sending after a failure costs nothing because every ingest dedupes.
    if _cursors_new:
        try:
            merged = dict(_cursors)
            merged.update(_cursors_new)
            os.makedirs(os.path.dirname(CURSOR_PATH), exist_ok=True)
            with open(CURSOR_PATH, "w", encoding="utf-8") as fh:
                json.dump(merged, fh)
        except OSError as e:
            # A cursor we failed to persist just means the next run re-sends. Never
            # turn a successful push into a failure over it.
            print("[push-telemetry] could not save push cursor: %s" % e)
    # S-3: same rule as the cursors -- persisted only AFTER the server accepted
    # the push. Recording a hash for content the server never received would
    # skip it on every later run until the weekly deadline, losing a snapshot
    # for a week over one failed request.
    if _content_new:
        try:
            cmerged = dict(_content)
            cmerged.update(_content_new)
            with open(CONTENT_PATH, "w", encoding="utf-8") as fh:
                json.dump(cmerged, fh)
        except OSError as e:
            print("[push-telemetry] could not save content state: %s" % e)
except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
    # Never fail the calling hook; the next push retries everything (dedupe).
    # Print the server's BODY, not just the status line: an HTTPError carries the
    # response, and a 422 names the offending field there. Without this a
    # rejected push looks like an empty, undiagnosable error (parity with the
    # PowerShell client, which reads it off the exception's response stream).
    detail = ""
    if isinstance(e, urllib.error.HTTPError):
        try:
            detail = e.read().decode("utf-8", "replace")[:800]
        except Exception:
            detail = ""
    if detail:
        print(f"[push-telemetry] Push failed: {e}\n  server said: {detail}", file=sys.stderr)
    else:
        print(f"[push-telemetry] Push failed: {e}", file=sys.stderr)
PY
exit 0
