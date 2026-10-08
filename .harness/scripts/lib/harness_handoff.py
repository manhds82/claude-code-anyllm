#!/usr/bin/env python3
"""C15 "Handoff after every task" -- shared core of the Stop hook.

harness-handoff-check.ps1 / .sh are thin shells over this (C7), so both emit the
same decision. Reads the Claude Code Stop-hook JSON on stdin, and prints a
{"decision":"block","reason":...} once when files changed this session but the
project's Handoff.md was not touched. Otherwise prints nothing.

Honest scope (C10): a local, bypassable reminder -- defense-in-depth, not a
boundary. C14: it must not cry wolf, so every doubt resolves to "stay silent":
no config, not a git repo, unknown session start, nothing changed, any error.

stdlib only (hooks run with whatever python is on PATH).
"""
import fnmatch
import json
import os
import re
import subprocess
import sys
import time


# ---- config (casan-policies.yaml -> handoff:) -------------------------------

def _scalar(v):
    v = v.strip()
    if v[:1] in ('"', "'"):
        q = v[0]
        end = v.find(q, 1)
        return v[1:end] if end > 0 else v[1:]
    v = re.sub(r"\s+#.*$", "", v).strip()
    low = v.lower()
    if low in ("true", "false"):
        return low == "true"
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


DEFAULTS = {
    "enabled": True,
    "path": "Handoff.md",
    "remind_on_stop": True,
    "max_age_days": 14,
    "dated_glob": "docs/HANDOFF-*.md",
    "ignore_paths": [".harness/telemetry/", ".harness/ledger/",
                     ".harness/local/", ".harness/context/"],
}


def effective_config(root):
    """Defaults overlaid with the project's handoff: block. A missing block or
    file means DEFAULTS (a fleet update parks the new casan-policies.yaml as
    *.new, so 'missing = off' would mean C15 never runs). Only an explicit
    `enabled: false` disables it."""
    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in (read_config(root) or {}).items() if v is not None})
    return cfg


def read_config(root):
    """The `handoff:` block of casan-policies.yaml as a dict, or None.

    Line-scanned, not YAML-parsed: no PyYAML dependency in a hook. Supports the
    shapes the block uses -- scalars, inline lists, block lists.
    """
    path = os.path.join(root, ".harness", "control", "casan-policies.yaml")
    try:
        with open(path, encoding="utf-8-sig") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    cfg, key, inside = {}, None, False
    for raw in lines:
        if not inside:
            if re.match(r"^handoff\s*:\s*(#.*)?$", raw):
                inside = True
            continue
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw.startswith((" ", "\t")):
            break  # next top-level key
        s = raw.strip()
        if s.startswith("- "):
            if key is not None:
                if not isinstance(cfg.get(key), list):
                    cfg[key] = []
                cfg[key].append(_scalar(s[2:]))
            continue
        m = re.match(r"^([A-Za-z_][\w]*)\s*:\s*(.*)$", s)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if val == "" or val.startswith("#"):
            cfg[key] = None  # block list follows (or empty)
        elif val.startswith("["):
            inner = re.sub(r"\s+#.*$", "", val).strip()
            inner = inner[1:inner.rfind("]")] if "]" in inner else inner[1:]
            cfg[key] = [_scalar(x) for x in inner.split(",") if x.strip()]
        else:
            cfg[key] = _scalar(val)
    return cfg if inside else None


# ---- helpers ----------------------------------------------------------------

def _git(root, *args):
    p = subprocess.run(("git", "-C", root) + args, capture_output=True, timeout=20)
    if p.returncode != 0:
        return None
    return p.stdout


def _norm(p):
    p = p.replace("\\", "/")
    return p[2:] if p.startswith("./") else p


def session_start(root, transcript):
    """Epoch seconds the session began, or None. Order of trust:
    1) birth time of this session's transcript (exact, per session);
    2) mtime of the newest .harness/tmp/<id> dir that harness-session-start
       creates (shared by concurrent sessions, so second choice).
    """
    if transcript and os.path.isfile(transcript):
        try:
            st = os.stat(transcript)
            if os.name == "nt":
                return st.st_ctime  # creation time on Windows
            if hasattr(st, "st_birthtime"):
                return st.st_birthtime
        except OSError:
            pass
    tmp = os.path.join(root, ".harness", "tmp")
    best = None
    try:
        for n in os.listdir(tmp):
            d = os.path.join(tmp, n)
            if os.path.isdir(d):
                m = os.stat(d).st_mtime
                best = m if best is None or m > best else best
    except OSError:
        pass
    return best


def changed_files(root, cfg):
    """Project-relative paths (git status) that count as work, existing on disk."""
    top = _git(root, "rev-parse", "--show-toplevel")
    if top is None:
        return None
    top = top.decode("utf-8", "replace").strip()
    out = _git(root, "status", "--porcelain", "-z", "-uall")
    if out is None:
        return None
    parts = out.decode("utf-8", "replace").split("\0")
    paths, i = [], 0
    while i < len(parts):
        e = parts[i]
        i += 1
        if len(e) < 4:
            continue
        xy, p = e[:2], e[3:]
        if "R" in xy or "C" in xy:
            i += 1  # the following entry is the rename source
        paths.append(p)
    ignore = [_norm(x) for x in (cfg.get("ignore_paths") or [])]
    handoff = _norm(str(cfg.get("path") or "Handoff.md"))
    dated = _norm(str(cfg.get("dated_glob") or ""))
    res = []
    for p in paths:
        full = os.path.normpath(os.path.join(top, p))
        rel = os.path.relpath(full, root)
        if rel.startswith(".."):
            continue
        rel = rel.replace("\\", "/")
        if rel == handoff or (dated and fnmatch.fnmatch(rel, dated)):
            continue
        if any(rel.startswith(ig) if ig.endswith("/") else rel == ig for ig in ignore):
            continue
        if os.path.isfile(full):
            res.append((rel, os.path.getmtime(full)))
    return res


REASON = (
    "C15 - Handoff sau moi task / Handoff after every task: cap nhat {handoff} "
    "(NOW / NEXT / OPEN / AVOID, ghi ngay, so lieu do thuc te) cho cong viec trong phien nay "
    "truoc khi dung. Update {handoff} for the work done in this session. "
    "Neu co docs/HANDOFF-*.md da bi thay the: gop (chep cac muc OPEN/AVOID con song vao "
    "{handoff}) roi xoa file cu - git giu lich su; KHONG BAO GIO xoa docs/_parts. "
    "Changed this session ({n}): {paths}"
)


def decide(root, payload):
    if payload.get("stop_hook_active"):
        return None
    cfg = effective_config(root)
    if cfg.get("enabled") is False or cfg.get("remind_on_stop") is False:
        return None
    start = session_start(root, payload.get("transcript_path") or "")
    if start is None:
        return None
    changed = changed_files(root, cfg)
    if not changed:
        return None
    recent = sorted(rel for rel, m in changed if m >= start)
    if not recent:
        return None
    hpath = str(cfg.get("path") or "Handoff.md")
    hfull = os.path.join(root, hpath.replace("/", os.sep))
    exists = os.path.isfile(hfull)
    if exists and os.path.getmtime(hfull) >= start:
        return None
    shown = ", ".join(recent[:8]) + (" (+%d more)" % (len(recent) - 8) if len(recent) > 8 else "")
    reason = REASON.format(handoff=hpath, n=len(recent), paths=shown)
    if not exists:
        reason = ("%s does not exist yet - CREATE it (tao moi) with the skeleton "
                  "# Handoff / ## NOW / ## NEXT / ## OPEN / ## AVOID. " % hpath) + reason
    return {"decision": "block", "reason": reason}


def _log_error(root, msg):
    try:
        log = os.path.join(root, ".harness", "telemetry", "hook-errors.log")
        os.makedirs(os.path.dirname(log), exist_ok=True)
        line = json.dumps({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                           "hook": "handoff-check", "error": msg[:200]})
        with open(log, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def main(argv):
    root = os.path.abspath(argv[1]) if len(argv) > 1 else os.getcwd()
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", "replace")
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return 0
    except Exception:
        return 0  # malformed stdin: stay silent
    try:
        out = decide(root, payload)
        if out:
            sys.stdout.write(json.dumps(out) + "\n")  # ASCII-escaped: encoding-proof
            sys.stdout.flush()
    except Exception as e:
        _log_error(root, "%s: %s" % (type(e).__name__, e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
