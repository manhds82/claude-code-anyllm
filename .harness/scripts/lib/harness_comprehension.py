#!/usr/bin/env python3
"""Comprehension gate (F6) — record and check a person's answers before release.

Config: .harness/control/comprehension-gate.json (C2 — questions and rules are
data, not literals in this file).

WHAT IT CHECKS, AND WHAT IT CANNOT
----------------------------------
It checks three things, all mechanical:
  - every configured question has an answer
  - each answer clears its min_chars
  - the ai_error answer is not one of the listed non-answers ("khong co", "n/a")

It cannot check that an answer is considered rather than plausible. Nothing
could. Claiming otherwise would manufacture the same false assurance the gate
exists to prevent, so the record carries `self_reported: true` like every other
declaration in this system, and the value is the forced pause plus the written
trail — not the prose.

The second question is the load-bearing one. On a high-risk change, being unable
to name a single thing the AI got wrong is evidence about the reviewer, not about
the AI.

Usage:
  harness_comprehension.py <root> --check                      # is the gate on, and for which tiers
  harness_comprehension.py <root> --tier high \\
      --restate "..." --ai-error "..." [--ref <change id>]     # record; exit 1 if it fails
"""
import argparse
import datetime as _dt
import json
import os
import sys

DEFAULT_CFG = ".harness/control/comprehension-gate.json"


def load_cfg(root):
    """Config from the target repo, else this toolkit's own copy.

    Measured need: a project onboarded from bundle 1.7.1 -- which is every
    project today, including one created this morning -- has no
    comprehension-gate.json, because the file postdates that bundle. Without a
    fallback the tool is unusable in exactly the projects it was built for,
    right up until a new bundle ships. harness_sensitivity.py already resolves
    this the same way; this makes the two consistent.
    """
    p = os.path.join(root, DEFAULT_CFG)
    if not os.path.exists(p):
        here = os.path.dirname(os.path.abspath(__file__))
        p = os.path.normpath(os.path.join(here, "..", "..", "control",
                                          "comprehension-gate.json"))
    if not os.path.exists(p):
        return None, "khong thay %s (ca ban cua toolkit)" % DEFAULT_CFG
    try:
        with open(p, "r", encoding="utf-8-sig") as fh:
            return json.load(fh), ""
    except (IOError, OSError, ValueError) as e:
        return None, "doc config that bai: %s" % e


def evaluate(cfg, answers):
    """Return (ok, failures). Mechanical checks only — see module docstring."""
    fails = []
    for q in cfg.get("questions", []):
        qid = q["id"]
        val = (answers.get(qid) or "").strip()
        if not val:
            fails.append("[%s] chua tra loi: %s" % (qid, q["prompt"]))
            continue
        if len(val) < int(q.get("min_chars", 1)):
            fails.append("[%s] qua ngan (%d < %d ky tu). %s"
                         % (qid, len(val), q["min_chars"], q.get("rule", "")))
            continue
        bad = [b.lower() for b in q.get("reject_non_answers", [])]
        if bad and val.lower().strip(" .!") in bad:
            fails.append("[%s] khong phai mot cau tra loi: %r. %s"
                         % (qid, val, q.get("rule", "")))
    return (len(fails) == 0), fails


def record(root, cfg, tier, answers, ref, passed, fails):
    rel = cfg.get("records_to") or ".harness/telemetry/comprehension.jsonl"
    path = os.path.join(root, rel)
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    rec = {
        "schema_version": "1.0.0",
        "ts": _dt.datetime.now().astimezone().isoformat(),
        "ref": ref or "",
        "tier": tier,
        "passed": bool(passed),
        "failures": fails,
        "answers": answers,
        "self_reported": True,
    }
    with open(path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
    return os.path.relpath(path, root)


def main(argv):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="Comprehension gate (F6).")
    p.add_argument("root", nargs="?", default=".")
    p.add_argument("--check", action="store_true", help="in trang thai cong roi thoat")
    p.add_argument("--tier", default="", help="risk tier cua thay doi (none/low/medium/high/critical)")
    p.add_argument("--restate", default="")
    p.add_argument("--ai-error", default="")
    p.add_argument("--ref", default="", help="ma thay doi / pipeline id, de doi chieu sau")
    args = p.parse_args(argv)

    root = os.path.abspath(args.root)
    cfg, err = load_cfg(root)
    if err:
        sys.stderr.write("[cong-hieu] %s\n" % err)
        return 2

    enabled = bool(cfg.get("enabled"))
    tiers = cfg.get("trigger_tiers", [])
    wired = cfg.get("enforced_at", "not_wired")

    if args.check:
        sys.stdout.write("[cong-hieu] enabled=%s  enforced_at=%s  tiers=%s\n"
                         % (enabled, wired, ",".join(tiers)))
        if wired == "not_wired":
            sys.stdout.write("[cong-hieu] CHUA WIRE: khong hook nao goi, khong stage nao phu thuoc.\n")
            sys.stdout.write("[cong-hieu] Wire cung luc voi quyet dinh B0 (approval-gate / domain-firewall).\n")
        return 0

    if not enabled:
        sys.stdout.write("[cong-hieu] cong dang TAT (enabled=false) -> bo qua.\n")
        return 0
    if args.tier and tiers and args.tier not in tiers:
        sys.stdout.write("[cong-hieu] tier '%s' khong nam trong %s -> bo qua.\n"
                         % (args.tier, ",".join(tiers)))
        return 0

    answers = {"restate": args.restate, "ai_error": args.ai_error}
    ok, fails = evaluate(cfg, answers)
    path = record(root, cfg, args.tier or "(khong ro)", answers, args.ref, ok, fails)

    if ok:
        sys.stdout.write("[cong-hieu] PASS -> ghi vao %s\n" % path)
        return 0
    sys.stdout.write("[cong-hieu] KHONG QUA -> ghi vao %s\n" % path)
    for f in fails:
        sys.stdout.write("[cong-hieu]   - %s\n" % f)
    sys.stdout.write("[cong-hieu] Khong qua o day khong phai loi he thong.\n")
    sys.stdout.write("[cong-hieu] No co nghia: thay doi nay chua nen release.\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
