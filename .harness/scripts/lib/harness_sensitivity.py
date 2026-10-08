#!/usr/bin/env python3
"""Sensitivity matcher (F2) — what does this path do to an action's risk score?

Until this file existed, F2 was data with no executable reader: gatekeeper (an
LLM) was asked to apply sensitive-paths.json by hand. That works, but it cannot
be tested, cannot be measured across a repo, and cannot be wired into a hook if
B0 ever decides to. This gives the rules one implementation that all three can
share.

RULES (from .harness/control/sensitive-paths.json)
  - highest matching score_delta wins; deltas are NOT summed
  - exclude_globs beat globs: a path matching both does not escalate
  - the resulting tier is read off risk-registry.yaml thresholds

WHY EXCLUSIONS EXIST
--------------------
The first scan of a live 162-file repo escalated 10 paths, and 4 were wrong: a
test file (matched *policy*.py), an ADR discussing secret redaction (matched
*secret*), and two .env.example files. A rule that escalates a document ABOUT a
sensitive topic trains people to wave the gate through, and a gate waved through
by habit still costs a click while certifying nothing.

Usage:
  harness_sensitivity.py <root> --path src/db/migrations/003.sql
  harness_sensitivity.py <root> --scan            # whole repo, with escalation rate
  harness_sensitivity.py <root> --scan --json
  harness_sensitivity.py <root> --path <rel> --ask-portal --tool Write --hook-input-file F
      F2 approval path (P1 1.0): ask the Portal whether a reviewer approved THIS
      write. Prints one JSON line {decision, reason, approval_id}; any failure
      prints decision "unreachable". The guards treat anything but "allow" as DENY.
"""
import argparse
import hashlib
import json
import os
import posixpath
import re
import socket
import subprocess
import sys
import urllib.request

BASE_FILE_WRITE = 10          # risk-registry.yaml risk_scoring.base_scores
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist",
             "build", ".pytest_cache", ".benchmarks",
             # .claude holds git worktrees from past sessions -- stale copies of
             # the same repo. Counting them made a 0.9% escalation rate read as
             # 4.8%, which is the difference between "fine" and "near the 25%
             # warning line". They are not files anyone edits.
             ".claude"}


def _segment_to_re(seg):
    """One path segment: `*` and `?` never cross `/`, everything else is literal."""
    out, i = [], 0
    while i < len(seg):
        c = seg[i]
        if c == "*":
            while i + 1 < len(seg) and seg[i + 1] == "*":
                i += 1          # `a**b` inside a segment is just `*` (gitignore)
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    return "".join(out)


def glob_to_re(g):
    """Glob -> regex with gitignore/pathspec `**` semantics.

    A `**` SEGMENT spans any number of directories wherever it sits:
      `**/x`    x at any depth (including the root)
      `a/**`    everything below a, at any depth -- not `a` itself
      `a/**/b`  b directly in a or anywhere below it
    `*` and `?` stay inside one segment.

    The first version did `**/` -> any-dirs and then `*` -> `[^/]*`, so a
    TRAILING `/**` (no slash after it) became `[^/]*[^/]*`: one level only.
    `**/tests/**` then missed `Admin/api/tests/unit/test_x.py`, and every
    exclude_glob of that shape silently stopped working one directory down --
    the false escalations C14 warns about -- while include globs such as
    `**/auth/**` under-matched the same way.
    """
    parts = g.split("/")
    # `**/**` means the same as `**`; collapsing keeps the joins below simple.
    parts = [p for i, p in enumerate(parts) if not (p == "**" and i and parts[i - 1] == "**")]
    n, rx = len(parts), []
    for i, seg in enumerate(parts):
        if seg == "**":
            if n == 1:
                rx.append(".*")               # bare `**`: anything
            elif i == 0:
                rx.append("(?:.*/)?")         # leading `**/`: owns its slash
            elif i == n - 1:
                rx.append("/.+")              # trailing `/**`: anything below
            else:
                rx.append("/(?:.*/)?")        # middle `/**/`: owns both slashes
            continue
        if i and parts[i - 1] != "**":
            rx.append("/")
        rx.append(_segment_to_re(seg))
    # Case-INSENSITIVE on every platform (S1, 30-09). Case-sensitive patterns let
    # `.ENV`, `db/Migrations/` and `Credentials.json` through on Windows, where
    # they are the same files as the lower-case names the globs are written in.
    # Over-matching `Migrations/` on Linux costs one approval; under-matching a
    # real secret or migration costs the control.
    return re.compile("^" + "".join(rx) + "$", re.IGNORECASE)


def load_rules(root, override=""):
    """Rules from the target repo, else from this toolkit's own copy.

    The fallback is the point: the most useful moment to score a project is
    BEFORE the harness is installed there, when you are deciding whether the
    globs fit its shape at all. Requiring .harness/ to already exist would make
    the tool unavailable exactly then."""
    if override:
        p = override
    else:
        p = os.path.join(root, ".harness", "control", "sensitive-paths.json")
        if not os.path.exists(p):
            here = os.path.dirname(os.path.abspath(__file__))
            p = os.path.normpath(os.path.join(here, "..", "..", "control", "sensitive-paths.json"))
    if not os.path.exists(p):
        return None, None, "khong thay sensitive-paths.json (thu ca --rules)"
    try:
        with open(p, "r", encoding="utf-8-sig") as fh:
            cfg = json.load(fh)
    except (IOError, OSError, ValueError) as e:
        return None, None, "doc sensitive-paths.json that bai: %s" % e
    default = cfg.get("default_score_delta", 60)
    rules = []
    for r in cfg.get("rules", []):
        rules.append({
            "id": r["id"],
            "inc": [glob_to_re(g) for g in r.get("globs", [])],
            "exc": [glob_to_re(g) for g in r.get("exclude_globs", [])],
            "delta": r.get("score_delta", default),
            "reason": r.get("reason", ""),
            # Opt-in per rule (P1 1.0): absent means NOT approvable.
            "approvable": r.get("approvable") is True,
        })
    return cfg, rules, ""


def load_tiers(root):
    """Thresholds from risk-registry.yaml, so the tier name is never hardcoded."""
    p = os.path.join(root, ".harness", "control", "risk-registry.yaml")
    tiers = []
    if os.path.exists(p):
        try:
            with open(p, "r", encoding="utf-8-sig") as fh:
                txt = fh.read()
            for name, th in re.findall(r'level:\s*"(\w+)"\s*\n\s*threshold:\s*(\d+)', txt):
                tiers.append((int(th), name))
        except (IOError, OSError):
            pass
    if not tiers:
        tiers = [(0, "none"), (10, "low"), (40, "medium"), (70, "high"), (90, "critical")]
    tiers.sort()
    return tiers


def tier_of(score, tiers):
    out = tiers[0][1]
    for th, name in tiers:
        if score >= th:
            out = name
    return out


def normalize_rel(rel):
    """Collapse `.` and `..` segments (S10) so `tests/../auth/x.py` is scored as
    `auth/x.py`, not as a path under `tests/` that an exclude_glob waves through.
    A path that still starts with `..` after normalising stays as it is."""
    rel = rel.replace("\\", "/").replace(os.sep, "/")
    n = posixpath.normpath(rel)
    if n.startswith("./"):
        n = n[2:]
    return n


def match(rel, rules):
    """Return (delta, rule_id, reason). Highest delta wins; exclusions beat globs."""
    best = (0, None, "")
    rel = normalize_rel(rel)
    for r in rules:
        if not any(p.match(rel) for p in r["inc"]):
            continue
        if any(p.match(rel) for p in r["exc"]):
            continue
        if r["delta"] > best[0]:
            best = (r["delta"], r["id"], r["reason"])
    return best


def matching_rules(rel, rules):
    """Every rule that fires on `rel` (globs hit, exclusions did not)."""
    rel = normalize_rel(rel)
    return [r for r in rules
            if any(p.match(rel) for p in r["inc"]) and not any(p.match(rel) for p in r["exc"])]


def approvable(rel, rules, cfg):
    """May a blocked write to `rel` be approved through the Portal?

    Only when approval_path.enabled is true AND every rule that fires on the
    path is marked approvable. One non-approvable rule (secrets, say) keeps the
    path hard-blocked, so adding the approval path widens nothing by default."""
    ap = (cfg or {}).get("approval_path")
    if not (isinstance(ap, dict) and ap.get("enabled") is True):
        return False
    hits = matching_rules(rel, rules)
    return bool(hits) and all(r["approvable"] for r in hits)


_PATH_KEYS = ("file_path", "path", "notebook_path")


def content_fingerprint(tool_input):
    """sha256 of everything the tool would write EXCEPT where (the path is bound
    separately). Generic on purpose -- Write.content, Edit.old/new_string,
    MultiEdit.edits, NotebookEdit.new_source all land in it without per-tool
    code, so both guards (and the tests) agree on one definition. "" when the
    input carries no content, which makes the approval path-only."""
    if not isinstance(tool_input, dict):
        return ""
    body = {k: v for k, v in tool_input.items() if k not in _PATH_KEYS}
    if not body:
        return ""
    blob = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _sync_root(root):
    """portal-sync.json is gitignored, so a git WORKTREE only has it in the main
    checkout; ask git (the authority, C13) rather than guessing a path."""
    if os.path.isfile(os.path.join(root, ".harness", "portal-sync.json")):
        return root
    if os.path.isfile(os.path.join(root, ".git")):
        try:
            out = subprocess.run(["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                 capture_output=True, text=True, timeout=5)
            common = (out.stdout or "").strip().splitlines()
            if out.returncode == 0 and common:
                return os.path.dirname(common[0].strip())
        except (OSError, subprocess.SubprocessError):
            pass
    return root


def _checkout_facts():
    """The shared credential reader (harness_checkout_facts), loaded from this file's own
    folder; None when it is missing (then only the legacy key path is available)."""
    try:
        import importlib.util
        fp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness_checkout_facts.py")
        if not os.path.isfile(fp):
            return None
        spec = importlib.util.spec_from_file_location("harness_checkout_facts", fp)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:  # noqa: BLE001
        return None


def ask_portal(root, rel, rule, tool, tool_input):
    """POST the blocked write to the Portal. Returns {decision, reason, approval_id}.

    FAIL CLOSED: no config, no key, network error, non-JSON, or a decision that
    is not exactly one of allow/ask/deny all come back as decision "unreachable",
    which the guards treat as "stay denied". Over-asking is fine; under-asking is
    not. The server cannot see this repo's rules -- what it is sent (path, rule,
    content hash, identity) is a client claim, so this is defense-in-depth (C10)."""
    def out(decision, reason="", approval_id=""):
        return {"decision": decision, "reason": reason, "approval_id": approval_id}

    try:
        sync_root = _sync_root(root)
        with open(os.path.join(sync_root, ".harness", "portal-sync.json"), "r", encoding="utf-8-sig") as fh:
            cfg = json.load(fh)
        if not (cfg.get("pdp_enforce") is True and cfg.get("portal_url") and cfg.get("project_id")):
            return out("unreachable", "pdp_enforce is off or portal-sync.json is incomplete")
        # P1 1.2b: the checkout credential identifies this machine AND its member; the
        # server derives both from it, so a declared actor cannot borrow another person's
        # approval.  The shared key is the legacy fallback only (read lazily: no credential
        # means no extra file read on the credential path).
        facts = _checkout_facts()
        cred = facts.checkout_auth(root) if facts else {}
        key = ""
        if not cred:
            key = os.environ.get("HARNESS_PORTAL_INGEST_KEY", "")
            if not key:
                kf = os.path.join(sync_root, ".harness", "portal-sync.key")
                if os.path.isfile(kf):
                    with open(kf, "r", encoding="utf-8-sig") as fh:
                        key = fh.read().strip()
            if not key:
                return out("unreachable", "no checkout credential and no ingest key")
        body = {
            "tool": tool or "Write",
            "path": rel,
            "rule": rule or "",
            "content_sha256": content_fingerprint(tool_input),
            "actor": os.environ.get("HARNESS_USER") or os.environ.get("HARNESS_SESSION_ID", ""),
            "actor_host": os.environ.get("COMPUTERNAME") or socket.gethostname(),
            # A claim only: the server takes the checkout from the credential header.
            "checkout_id": cred.get("checkout_id") or os.environ.get("HARNESS_CHECKOUT_ID", ""),
        }
        if cred:
            auth = {"X-Checkout-Id": cred["checkout_id"], "X-Checkout-Credential": cred["checkout_credential"]}
        else:
            # No legacy warning here: the guards call this with stderr discarded, so it
            # would only burn the once-a-day stamp unseen. The guard itself warns.
            auth = {"X-Ingest-Key": key}
        url = cfg["portal_url"].rstrip("/") + "/api/pdp/" + str(cfg["project_id"]) + "/f2-write"
        req = urllib.request.Request(
            url, data=json.dumps(body).encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json; charset=utf-8",
                     "User-Agent": "harness-runtime-guard/1.0", **auth})
        with urllib.request.urlopen(req, timeout=8) as r:
            d = json.loads(r.read().decode("utf-8"))
        dec = d.get("decision") if isinstance(d, dict) else None
        if dec not in ("allow", "ask", "deny"):
            return out("unreachable", "unrecognised reply from the Portal")
        return out(dec, str(d.get("reason") or "")[:300], str(d.get("approval_id") or "")[:64])
    except Exception as e:  # noqa: BLE001 -- every failure is the same answer: stay denied
        return out("unreachable", "%s: %s" % (type(e).__name__, str(e)[:120]))


def _read_tool_input(args):
    """tool_input dict from --hook-input-file (the hook payload, or a bare
    tool_input) or --hook-input-stdin; None when neither is given or readable."""
    try:
        if args.hook_input_file:
            with open(args.hook_input_file, "r", encoding="utf-8-sig") as fh:
                d = json.load(fh)
        elif args.hook_input_stdin:
            d = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
        else:
            return None
    except (IOError, OSError, ValueError):
        return None
    if isinstance(d, dict):
        for k in ("tool_input", "input"):
            if isinstance(d.get(k), dict):
                return d[k]
    return d if isinstance(d, dict) else None


def scan(root, rules, tiers):
    hits, total = [], 0
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for fn in fns:
            rel = os.path.relpath(os.path.join(dp, fn), root)
            total += 1
            delta, rid, _ = match(rel, rules)
            if rid:
                score = BASE_FILE_WRITE + delta
                hits.append({"path": rel.replace(os.sep, "/"), "rule": rid,
                             "score": score, "tier": tier_of(score, tiers)})
    return hits, total


def main(argv):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="F2 sensitivity matcher.")
    p.add_argument("root", nargs="?", default=".")
    p.add_argument("--path", default="", help="mot duong dan de cham diem")
    p.add_argument("--scan", action="store_true", help="quet ca repo")
    p.add_argument("--json", action="store_true")
    p.add_argument("--rules", default="", help="duong dan sensitive-paths.json khac")
    p.add_argument("--ask-portal", action="store_true",
                   help="hoi Portal xem ban ghi nay da duoc duyet chua (can --path; chi rule approvable)")
    p.add_argument("--tool", default="Write")
    p.add_argument("--hook-input-file", default="", help="JSON cua hook (hoac tool_input) de bam noi dung")
    p.add_argument("--hook-input-stdin", action="store_true")
    args = p.parse_args(argv)

    root = os.path.abspath(args.root)
    cfg, rules, err = load_rules(root, args.rules)
    if err:
        sys.stderr.write("[sensitivity] %s\n" % err)
        return 2
    tiers = load_tiers(root)

    if args.ask_portal and args.path:
        delta, rid, reason = match(args.path, rules)
        if not (rid and approvable(args.path, rules, cfg)):
            res = {"decision": "skip", "reason": "path is not approvable under sensitive-paths.json", "approval_id": ""}
        else:
            res = ask_portal(root, args.path, rid, args.tool, _read_tool_input(args))
        sys.stdout.write(json.dumps(res, ensure_ascii=False) + "\n")
        return 0

    if args.path:
        delta, rid, reason = match(args.path, rules)
        score = BASE_FILE_WRITE + delta
        res = {"path": args.path, "rule": rid, "delta": delta, "score": score,
               "tier": tier_of(score, tiers), "reason": reason,
               "approvable": bool(rid) and approvable(args.path, rules, cfg)}
        if args.json:
            sys.stdout.write(json.dumps(res, ensure_ascii=False, indent=2) + "\n")
        elif rid:
            sys.stdout.write("[sensitivity] %s\n  rule  : %s (+%d)\n  diem  : %d -> tier %s\n  vi sao: %s\n"
                             % (args.path, rid, delta, score, res["tier"], reason))
        else:
            sys.stdout.write("[sensitivity] %s\n  khong rule nao khop -> diem %d (tier %s)\n"
                             % (args.path, score, res["tier"]))
        return 0

    if args.scan:
        hits, total = scan(root, rules, tiers)
        pct = (100.0 * len(hits) / total) if total else 0.0
        if args.json:
            sys.stdout.write(json.dumps({"total_files": total, "escalated": len(hits),
                                         "percent": round(pct, 1), "hits": hits},
                                        ensure_ascii=False, indent=2) + "\n")
            return 0
        by = {}
        for h in hits:
            by.setdefault(h["rule"], []).append(h)
        sys.stdout.write("File quet : %d\nLeo bac   : %d (%.1f%%)\n\n" % (total, len(hits), pct))
        for rid in sorted(by):
            items = by[rid]
            sys.stdout.write("  [%-13s] %3d file -> diem %d (tier %s)\n"
                             % (rid, len(items), items[0]["score"], items[0]["tier"]))
            for h in items[:3]:
                sys.stdout.write("        %s\n" % h["path"])
            if len(items) > 3:
                sys.stdout.write("        ... con %d\n" % (len(items) - 3))
        if pct > 25:
            sys.stdout.write("\n  ! %.1f%% vuot nguong 25%% ghi trong sensitive-paths.json:\n" % pct)
            sys.stdout.write("    glob dang qua rong. Bo bot glob, dung ha delta.\n")
        return 0

    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
