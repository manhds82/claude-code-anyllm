#!/usr/bin/env python3
"""harness_checkout_facts -- what this checkout can say about itself (Portal v2 P1 1.3).

push-telemetry.ps1 / .sh call this once and merge the JSON into the push body, so the
two shells cannot drift apart on what a push claims.

Emitted (one JSON line, stdout):

  checkout_id, device_id, path_hash   who the push says it is. path_hash is the sha256
                                      of the checkout folder path (backslashes -> '/',
                                      no trailing '/'); the Portal compares it with the
                                      path the checkout was enrolled at, so a COPIED
                                      folder pushing with the original's credential is
                                      noticed.
  worktree                            true when this folder is a git worktree. A
                                      worktree pushes into its PARENT checkout: the
                                      credential and path_hash are the parent's, and the
                                      push must not carry the worktree's own ledger
                                      anchor (its chain is its own).
  receipt / receipt_at_head           the bundle version the receipt file claims, and the
                                      one committed at git HEAD.
  disk_fingerprint                    which release the files really match (the
                                      harness_fingerprint.py answer, trimmed).
  git_remote / git_branch / git_head / git_dirty
  auth                                {checkout_id, checkout_credential} for the request
                                      HEADERS only; absent when this machine holds none.

Credential: env HARNESS_CHECKOUT_ID + HARNESS_CHECKOUT_CREDENTIAL, else the git-ignored
file <root>/.harness/local/checkout.json {"checkout_id","device_id","checkout_credential"}
(C5: never committed, never printed by the callers). No credential -> no `auth`, and the
caller falls back to the legacy shared key.

Every probe is best-effort and independent: a failure leaves that field out, it never
fails the push. A missing value is a gap the Portal can see, not a guess (C13).
"""
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

LOCAL_REL = os.path.join(".harness", "local", "checkout.json")
RECEIPT_REL = ".harness/.bundle-manifest.json"
_CRED_IN_URL = re.compile(r"(://)[^/@\s]*@")


def norm_path(root: str) -> str:
    """THE one normalisation of a checkout folder path, used by every producer (this
    library, push-telemetry, enroll-checkout .ps1/.sh via `--path-hash`): realpath
    (resolves `..`, symlinks, and on Windows the casing the filesystem knows), then
    normcase on Windows ONLY (a case-insensitive filesystem: `e:/x` and `E:/X` are one
    folder; POSIX stays case-sensitive), separators -> '/', no trailing '/'.
    QA ir-20261001-p1bc #6. The definition changed here (it used abspath, case kept);
    nobody is enrolled yet, so no stored path_hash is invalidated."""
    p = os.path.realpath(root)
    if os.name == "nt":
        p = os.path.normcase(p)
    return p.replace("\\", "/").rstrip("/")


def path_hash(root: str) -> str:
    return hashlib.sha256(norm_path(root).encode("utf-8")).hexdigest()


def strip_credentials(url: str) -> str:
    """https://user:token@host/x -> https://host/x (C5)."""
    return _CRED_IN_URL.sub(r"\1", url or "")


def _git(root: str, *args: str) -> str:
    try:
        out = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True,
                             timeout=10, check=False)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def parent_of_worktree(root: str):
    """Parent checkout root when `root` is a linked git worktree, else None.
    A linked worktree's `.git` is a FILE: `gitdir: <main>/.git/worktrees/<name>`."""
    dotgit = os.path.join(root, ".git")
    if not os.path.isfile(dotgit):
        return None
    try:
        with open(dotgit, encoding="utf-8") as f:
            line = f.readline().strip()
    except OSError:
        return None
    if not line.startswith("gitdir:"):
        return None
    gitdir = line[len("gitdir:"):].strip()
    if not os.path.isabs(gitdir):
        gitdir = os.path.normpath(os.path.join(root, gitdir))
    norm = gitdir.replace("\\", "/")
    if "/worktrees/" not in norm:
        return None                       # a submodule, not a worktree
    main_git = os.path.dirname(os.path.dirname(os.path.normpath(gitdir)))
    return os.path.dirname(main_git)


def _load(name: str):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def decode_secret(stored: str) -> str:
    """Stored credential -> the credential. Versioned on-disk format written by
    enroll-checkout.ps1 / .sh:
      plain-v1:<value>   a 0600 file (non-Windows) -- NOT encrypted, only private
      dpapi-v1:<base64>  Windows DPAPI, CurrentUser scope
      <no prefix>        legacy plain text (pre-enroll-checkout files)
    A value that cannot be decoded (wrong user/machine, not Windows) yields "" --
    a gap the Portal can see, never a guess (C13)."""
    s = (stored or "").strip()
    if s.startswith("plain-v1:"):
        return s[len("plain-v1:"):]
    if s.startswith("dpapi-v1:"):
        if sys.platform != "win32":
            return ""
        try:
            import base64
            import ctypes
            from ctypes import wintypes

            class _Blob(ctypes.Structure):
                _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

            raw = base64.b64decode(s[len("dpapi-v1:"):])
            buf = ctypes.create_string_buffer(raw, len(raw))
            blob_in = _Blob(len(raw), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
            blob_out = _Blob()
            if not ctypes.windll.crypt32.CryptUnprotectData(
                    ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)):
                return ""
            try:
                return ctypes.string_at(blob_out.pbData, blob_out.cbData).decode("utf-8")
            finally:
                ctypes.windll.kernel32.LocalFree(blob_out.pbData)
        except Exception:  # noqa: BLE001 - unreadable = no credential, not a crash
            return ""
    return s


def read_credential(cred_root: str) -> dict:
    cid = os.environ.get("HARNESS_CHECKOUT_ID", "").strip()
    cred = os.environ.get("HARNESS_CHECKOUT_CREDENTIAL", "").strip()
    dev = ""
    try:
        with open(os.path.join(cred_root, LOCAL_REL), encoding="utf-8-sig") as f:
            d = json.load(f) or {}
        cid = cid or str(d.get("checkout_id") or "").strip()
        cred = cred or decode_secret(str(d.get("checkout_credential") or ""))
        dev = str(d.get("device_id") or "").strip()
    except (OSError, ValueError):
        pass
    return {"checkout_id": cid, "checkout_credential": cred, "device_id": dev}


def _receipt_at_head(root: str) -> str:
    raw = _git(root, "show", "HEAD:" + RECEIPT_REL)
    if not raw:
        return ""
    try:
        d = json.loads(raw.lstrip("﻿"))
        return str(d.get("version") or d.get("bundle_version") or "")
    except ValueError:
        return ""


def _fingerprint(root: str) -> dict:
    try:
        fp = _load("harness_fingerprint")
        if fp is None:
            return {}
        index = fp.default_index(root)
        if not index:
            return {"identified": False, "reason": "no release index"}
        r = fp.fingerprint(root, index)
        best = r.get("best") or {}
        return {"identified": bool(r.get("identified")), "range": best.get("range", ""),
                "matches": best.get("matches", 0), "denominator": best.get("denominator", 0),
                "ratio": best.get("ratio", 0.0), "receipt_agrees": r.get("receipt_agrees"),
                "unmatched": len(r.get("unmatched") or []), "files_checked": r.get("files_checked", 0),
                "warnings": list(r.get("warnings") or [])[:3]}
    except Exception as e:  # noqa: BLE001 - a probe must never fail the push
        return {"identified": False, "reason": type(e).__name__}


def facts(root: str) -> dict:
    root = os.path.abspath(root)
    parent = parent_of_worktree(root)
    ident_root = parent or root          # a worktree speaks as its parent checkout
    out = {"worktree": bool(parent), "path_hash": path_hash(ident_root)}
    cred = read_credential(ident_root)
    if cred["device_id"]:
        out["device_id"] = cred["device_id"]
    if cred["checkout_id"] and cred["checkout_credential"]:
        out["checkout_id"] = cred["checkout_id"]
        out["auth"] = {"checkout_id": cred["checkout_id"], "checkout_credential": cred["checkout_credential"]}
    try:
        rcpt = _load("harness_fingerprint")
        v, _ = rcpt.read_receipt(root) if rcpt else (None, "")
        if v:
            out["receipt"] = str(v)
    except Exception:  # noqa: BLE001
        pass
    head_receipt = _receipt_at_head(root)
    if head_receipt:
        out["receipt_at_head"] = head_receipt
    fp = _fingerprint(root)
    if fp:
        out["disk_fingerprint"] = fp
    remote = strip_credentials(_git(root, "remote", "get-url", "origin"))
    if remote:
        out["git_remote"] = remote
    branch = _git(root, "rev-parse", "--abbrev-ref", "HEAD")
    if branch:
        out["git_branch"] = branch
    head = _git(root, "rev-parse", "HEAD")
    if head:
        out["git_head"] = head
        out["git_dirty"] = bool(_git(root, "status", "--porcelain"))
    return out


# ---- request authentication for every client (Portal v2 P1 1.2b) ---------------------
#
# Precedence, one place for all five clients (push-telemetry, runtime guard, release,
# F2 ask, enroll tooling):
#   1. a checkout id + credential held locally  -> X-Checkout-Id + X-Checkout-Credential ONLY
#   2. otherwise the shared ingest key           -> X-Ingest-Key   (legacy; warns once a day)
#   3. neither                                   -> no headers; the caller skips/denies
# The server derives checkout and member from (1); a body "actor" is only a claim.
LEGACY_STAMP = "legacy-key-warn.stamp"
LEGACY_TTL = 24 * 3600
LEGACY_TEXT = ("[%s] no checkout credential on this machine -- using the shared ingest key "
               "(legacy path; enrol with tools/harness-bundle/enroll-checkout). Shown once a day.")
# A server 401/403 from the PDP (revoked / expired checkout, disabled person, closed legacy
# window). The clients stay fail-open (documented design, C10) but say so, once a day.
REJECTED_STAMP = "pdp-rejected-warn.stamp"
REJECTED_TEXT = ("[%s] PDP rejected this credential (revoked / disabled / legacy window closed) -- "
                 "server-side enforcement is NOT active for this machine. Shown once a day.")


def cred_root_for(root: str) -> str:
    """A linked worktree speaks as its parent checkout (same rule as facts())."""
    root = os.path.abspath(root)
    return parent_of_worktree(root) or root


def checkout_auth(root: str) -> dict:
    """{"checkout_id","checkout_credential"} when BOTH are held here, else {}."""
    c = read_credential(cred_root_for(root))
    if c["checkout_id"] and c["checkout_credential"]:
        return {"checkout_id": c["checkout_id"], "checkout_credential": c["checkout_credential"]}
    return {}


def auth_headers(root: str, legacy_key: str = ""):
    """-> (headers, source) with source in checkout | legacy-key | none."""
    a = checkout_auth(root)
    if a:
        return ({"X-Checkout-Id": a["checkout_id"],
                 "X-Checkout-Credential": a["checkout_credential"]}, "checkout")
    if legacy_key:
        return {"X-Ingest-Key": legacy_key}, "legacy-key"
    return {}, "none"


def _state_dir() -> str:
    d = os.environ.get("HARNESS_STATE_DIR", "").strip()
    if d:
        return d
    if os.name == "nt":
        return os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "harness")
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "harness")


def legacy_warning(who: str, now=None) -> str:
    """The one-line legacy-key warning, or "" when one was already shown in the last 24h on
    this machine (a stamp file, so it is per machine, not per tool call -- C14). Any error
    reading/writing the stamp yields "" : a warning channel that cannot throttle stays quiet."""
    return _throttled(LEGACY_STAMP, LEGACY_TEXT, who, now)


def rejected_warning(who: str, now=None) -> str:
    """The once-a-day "PDP rejected this credential" line (HTTP 401/403), or "". Same stamp
    directory and 24h TTL as legacy_warning, its own stamp file. Names no header value (C5)."""
    return _throttled(REJECTED_STAMP, REJECTED_TEXT, who, now)


def _throttled(stamp_name: str, text: str, who: str, now=None) -> str:
    import time
    try:
        d = _state_dir()
        stamp = os.path.join(d, stamp_name)
        t = time.time() if now is None else now
        try:
            if t - os.path.getmtime(stamp) < LEGACY_TTL:
                return ""
        except OSError:
            pass
        os.makedirs(d, exist_ok=True)
        with open(stamp, "w", encoding="utf-8") as f:
            f.write(str(int(t)) + "\n")
        return text % who
    except Exception:  # noqa: BLE001
        return ""


def main(argv) -> int:
    if len(argv) > 1 and argv[1] == "--path-hash":
        # `--path-hash <dir>`: the path_hash of that folder, one line (what enroll-checkout posts).
        sys.stdout.write(path_hash(argv[2] if len(argv) > 2 else ".") + "\n")
        return 0
    if len(argv) > 1 and argv[1] == "--auth":
        # `--auth <root>`: the credential for the request HEADERS only, as one JSON line
        # ({} when none).  Stdout is meant to be captured by the caller, never shown.
        try:
            sys.stdout.write(json.dumps(checkout_auth(argv[2] if len(argv) > 2 else "."),
                                        separators=(",", ":")) + "\n")
        except Exception:  # noqa: BLE001
            sys.stdout.write("{}\n")
        return 0
    if len(argv) > 1 and argv[1] == "--rejected-warning":
        w = rejected_warning(argv[2] if len(argv) > 2 else "harness")
        if w:
            sys.stdout.write(w + "\n")
        return 0
    if len(argv) > 1 and argv[1] == "--legacy-warning":
        # `--legacy-warning <who>`: prints the throttled one-line warning, or nothing.
        w = legacy_warning(argv[2] if len(argv) > 2 else "harness")
        if w:
            sys.stdout.write(w + "\n")
        return 0
    root = argv[1] if len(argv) > 1 else "."
    try:
        sys.stdout.write(json.dumps(facts(root), separators=(",", ":"), ensure_ascii=True) + "\n")
    except Exception:  # noqa: BLE001 - print nothing rather than a half-truth
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
