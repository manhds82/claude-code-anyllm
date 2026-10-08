#!/usr/bin/env python3
"""Compute the leverage KPIs defined in .harness/control/kpi.yaml (F5).

Reads human effort (F4), the frozen baseline (baseline-w0.json) and machine
telemetry (daily-*.jsonl), and reports Nen, MD/1M-token and the human-edit rate.

WHY THIS REFUSES TO PRINT NUMBERS
---------------------------------
A ratio computed over three of forty entries is not the project's Nen -- but it
looks exactly like it once someone puts it on a slide. So coverage is computed
first and printed first, and below kpi.yaml's min_coverage_percent the metric
prints INSUFFICIENT with no figure at all. That is the fail-closed rule applied
to measurement: a number that cannot be verified is withheld, not shown with a
caveat nobody carries forward.

Two more honesty rules, both from kpi.yaml:
  - Entries flagged matches_machine_duration (human_minutes within 2% of the
    session's machine clock, see F4) are reported SEPARATELY. A leverage ratio
    built on minutes that were read off the machine clock is circular.
  - The numerator is an ESTIMATE from baseline-w0.json, declared once and frozen.
    It is labelled as such in the output every time, not only in this docstring.

No third-party libraries: the YAML this needs is a flat subset, parsed below.

Usage:
  harness_kpi.py <root> [--json] [--since YYYY-MM-DD] [--until YYYY-MM-DD]
"""
import argparse
import datetime as _dt
import glob
import json
import os
import re
import sys

DEFAULT_HOURS_PER_MD = 8.0
DEFAULT_MIN_COVERAGE = 30.0


# ----------------------------------------------------------------- tiny YAML
def load_kpi_yaml(path):
    """Read only the scalars this tool needs.

    kpi.yaml is C2 data, but it is also mostly prose for humans. Rather than
    pull in PyYAML (this repo's suites run on the standard library only), read
    the two numbers that drive arithmetic and let the rest stay documentation.
    A missing file falls back to documented defaults instead of failing: the
    report is still honest, it just says where the constants came from.
    """
    out = {"hours_per_md": DEFAULT_HOURS_PER_MD,
           "min_coverage_percent": DEFAULT_MIN_COVERAGE,
           "source": "defaults (kpi.yaml not found)"}
    if not os.path.exists(path):
        return out
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            for line in fh:
                m = re.match(r"^\s*hours_per_md:\s*([0-9.]+)", line)
                if m:
                    out["hours_per_md"] = float(m.group(1))
                m = re.match(r"^\s*min_coverage_percent:\s*([0-9.]+)", line)
                if m:
                    out["min_coverage_percent"] = float(m.group(1))
        out["source"] = os.path.relpath(path)
    except (IOError, OSError):
        pass
    return out


# ------------------------------------------------------------------- loaders
def load_baseline(root):
    path = os.path.join(root, ".harness", "control", "baseline-w0.json")
    if not os.path.exists(path):
        return {}, "khong tim thay baseline-w0.json"
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except (IOError, OSError, ValueError) as e:
        return {}, "baseline-w0.json khong doc duoc: %s" % e
    refs = {}
    for r in data.get("references", []):
        rid = r.get("id")
        hrs = r.get("traditional_hours")
        if rid and isinstance(hrs, (int, float)):
            refs[rid] = {"hours": float(hrs), "frozen": bool(r.get("frozen")),
                         "description": r.get("description", "")}
    return refs, ""


def load_human(root, since, until):
    path = os.path.join(root, ".harness", "telemetry", "human-effort.jsonl")
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            d = r.get("date", "")
            if since and d < since:
                continue
            if until and d > until:
                continue
            rows.append(r)
    return rows


def tokens_for_dates(root, dates):
    """Total tokens from daily-*.jsonl for exactly the days effort was logged."""
    total = 0
    seen_any = False
    for d in sorted(dates):
        p = os.path.join(root, ".harness", "telemetry", "daily-%s.jsonl" % d)
        if not os.path.exists(p):
            continue
        try:
            with open(p, "r", encoding="utf-8-sig") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    t = rec.get("total_tokens")
                    if isinstance(t, (int, float)) and t > 0:
                        total += t
                        seen_any = True
        except (IOError, OSError):
            continue
    return (total if seen_any else None)


# ------------------------------------------------------------------- compute
def compute(root, since, until):
    cfg = load_kpi_yaml(os.path.join(root, ".harness", "control", "kpi.yaml"))
    refs, base_err = load_baseline(root)
    rows = load_human(root, since, until)

    total_entries = len(rows)
    human_minutes = sum(r.get("human_minutes", 0) for r in rows)
    human_edits = sum(r.get("human_edits", 0) for r in rows)
    suspect = [r for r in rows if r.get("matches_machine_duration")]
    unplanned = [r for r in rows if r.get("unplanned")]
    rework = [r for r in rows if r.get("rework")]

    eligible = [r for r in rows if r.get("baseline_ref") and r.get("baseline_ref") in refs]
    orphan_refs = sorted({r.get("baseline_ref") for r in rows
                          if r.get("baseline_ref") and r.get("baseline_ref") not in refs})

    covered_minutes = sum(r.get("human_minutes", 0) for r in eligible)
    coverage = (100.0 * covered_minutes / human_minutes) if human_minutes else 0.0

    baseline_hours = sum(refs[r["baseline_ref"]]["hours"] for r in eligible)
    covered_hours = covered_minutes / 60.0
    dates = {r.get("date") for r in eligible if r.get("date")}
    tokens = tokens_for_dates(root, dates) if dates else None

    res = {
        "window": {"since": since or "(dau)", "until": until or "(nay)"},
        "config": cfg,
        "baseline_error": base_err,
        "totals": {
            "entries": total_entries,
            "human_hours": round(human_minutes / 60.0, 2),
            "human_edits": human_edits,
            "entries_unplanned": len(unplanned),
            "entries_rework": len(rework),
            "entries_suspect": len(suspect),
        },
        "coverage": {
            "eligible_entries": len(eligible),
            "covered_hours": round(covered_hours, 2),
            "percent": round(coverage, 1),
            "min_required": cfg["min_coverage_percent"],
            "sufficient": coverage >= cfg["min_coverage_percent"],
            "orphan_refs": orphan_refs,
        },
        "metrics": {},
    }

    suff = res["coverage"]["sufficient"]

    # Nen
    if not suff or covered_hours <= 0:
        res["metrics"]["compression"] = {"value": None, "status": "INSUFFICIENT"}
    else:
        res["metrics"]["compression"] = {
            "value": round(baseline_hours / covered_hours, 2),
            "status": "OK",
            "numerator_hours": baseline_hours,
            "denominator_hours": round(covered_hours, 2),
        }

    # MD / 1M token
    if not suff or tokens is None or tokens <= 0:
        reason = "INSUFFICIENT" if not suff else "NO_TOKEN_DATA"
        res["metrics"]["md_per_million_tokens"] = {"value": None, "status": reason}
    else:
        md = baseline_hours / cfg["hours_per_md"]
        res["metrics"]["md_per_million_tokens"] = {
            "value": round(md / (tokens / 1e6), 2),
            "status": "OK",
            "md_delivered": round(md, 2),
            "tokens": tokens,
        }

    # Human edit rate — no coverage gate: it needs no baseline.
    if human_minutes <= 0:
        res["metrics"]["human_edit_rate"] = {"value": None, "status": "NO_DATA"}
    else:
        res["metrics"]["human_edit_rate"] = {
            "value": round(human_edits / (human_minutes / 60.0), 2),
            "status": "OK",
        }
    return res


# -------------------------------------------------------------------- report
def render(res):
    L = []
    t, c, m = res["totals"], res["coverage"], res["metrics"]
    L.append("=" * 66)
    L.append("KPI don bay  |  %s -> %s" % (res["window"]["since"], res["window"]["until"]))
    L.append("=" * 66)
    if res["baseline_error"]:
        L.append("  ! %s" % res["baseline_error"])
    L.append("")
    L.append("Cong suc nguoi da ghi")
    L.append("  entry            : %d" % t["entries"])
    L.append("  gio nguoi         : %.2f h" % t["human_hours"])
    L.append("  lan sua AI        : %d" % t["human_edits"])
    L.append("  ngoai ke hoach    : %d entry" % t["entries_unplanned"])
    L.append("  phai lam lai      : %d entry" % t["entries_rework"])
    if t["entries_suspect"]:
        L.append("  NGHI VAN          : %d entry co human_minutes ~= thoi gian may" % t["entries_suspect"])
        L.append("                      (xem F4: co the da doc tu dong ho thay vi dem)")
    L.append("")
    L.append("Do phu baseline (dieu kien de Nen co nghia)")
    L.append("  entry co baseline : %d" % c["eligible_entries"])
    L.append("  gio duoc phu      : %.2f h  = %.1f%% (toi thieu %.0f%%)"
             % (c["covered_hours"], c["percent"], c["min_required"]))
    if c["orphan_refs"]:
        L.append("  ! baseline_ref khong co trong baseline-w0.json: %s" % ", ".join(c["orphan_refs"]))
    L.append("")
    L.append("-" * 66)

    def line(label, key, unit, extra=""):
        d = m.get(key, {})
        if d.get("status") == "OK":
            L.append("  %-22s %10s %s%s" % (label, d["value"], unit, extra))
        elif d.get("status") == "INSUFFICIENT":
            L.append("  %-22s %10s  do phu %.1f%% < %.0f%% -- KHONG in so"
                     % (label, "--", c["percent"], c["min_required"]))
        elif d.get("status") == "NO_TOKEN_DATA":
            L.append("  %-22s %10s  khong co daily-*.jsonl cho cac ngay do" % (label, "--"))
        else:
            L.append("  %-22s %10s  chua co du lieu" % (label, "--"))

    cm = m.get("compression", {})
    extra = ""
    if cm.get("status") == "OK":
        extra = "   (%.0fh uoc / %.2fh that)" % (cm["numerator_hours"], cm["denominator_hours"])
    line("Nen", "compression", "x", extra)
    line("Hieu qua token", "md_per_million_tokens", "MD/1M-token")
    line("Nguoi sua AI", "human_edit_rate", "lan/h")
    L.append("-" * 66)
    L.append("")
    if cm.get("status") == "OK":
        L.append("Tu so cua Nen la UOC LUONG khai mot lan trong baseline-w0.json,")
        L.append("khong phai do duoc. Sua no sau khi da thay ket qua thi Nen chi con")
        L.append("do chinh lan sua do -- neu buoc phai sua, ghi ly do vao DEVBOOK.md.")
    else:
        L.append("Chua du du lieu de in Nen. Gan baseline_ref cho cac entry:")
        L.append("  log-human.ps1 -Minutes 95 -Edits 6 -BaselineRef <id trong baseline-w0.json>")
    L.append("")
    L.append("Nguon hang so: %s" % res["config"]["source"])
    return "\n".join(L)


def main(argv):
    p = argparse.ArgumentParser(description="Compute leverage KPIs (Nen, MD/1M-token).")
    p.add_argument("root", nargs="?", default=".")
    p.add_argument("--json", action="store_true", help="in JSON thay vi bang")
    p.add_argument("--since", default="", help="YYYY-MM-DD")
    p.add_argument("--until", default="", help="YYYY-MM-DD")
    args = p.parse_args(argv)

    root = os.path.abspath(args.root)
    res = compute(root, args.since, args.until)
    if args.json:
        sys.stdout.write(json.dumps(res, ensure_ascii=False, indent=2) + "\n")
    else:
        sys.stdout.write(render(res) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
