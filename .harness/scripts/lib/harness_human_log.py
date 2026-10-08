#!/usr/bin/env python3
"""Record one block of HUMAN effort (F4).

Every one of the ~44 fields this system already records measures the MACHINE:
latency_ms, duration_s, tokens_in/out, estimated_cost_usd, tool_calls,
tests_passed. Not one records what the person spent. That makes the leverage
question unanswerable -- "is this faster than before" has no numerator, only a
cost -- and it is the gap F4 exists to close.

Appends one line per entry to .harness/telemetry/human-effort.jsonl.

WHAT THIS IS, EXACTLY
---------------------
A self-report by a person. Like pipeline-runs.jsonl it is a DECLARATION, not
proof, and it carries that limit in the data (`self_reported: true`) rather than
only in this docstring -- whoever reads a row in three months needs to know its
provenance without finding this file.

THE ONE RULE THAT MATTERS
-------------------------
`human_minutes` is minutes a person spent at the keyboard. It is NEVER derived
from session duration, from latency_ms, or from token count. Token burn is not
effort: building foundations burns tokens and ships little, and an agent can run
for forty minutes while the person is at lunch. A system that infers human hours
from machine time reports a number that feels like measurement and is not one.

Because that inference is tempting and invisible once written, this tool looks up
the machine time for the same session and, when the two land within 2% of each
other, marks the row `matches_machine_duration: true` and says so on screen. It
does NOT reject: the two can legitimately coincide on a short focused session.
It refuses to let the coincidence be silent.

WHAT IT REJECTS
---------------
An inconsistent record is rejected rather than written -- a wrong row on a
dashboard is permanent, and the point of the dashboard is that its rows can be
trusted:
  - minutes outside 1..1440 (zero is not an entry; >24h is a typo)
  - edits negative, or implausibly large
  - a date that does not parse, or is in the future

WHAT human_edits COUNTS
-----------------------
One increment each time you changed what the AI produced because it was wrong,
incomplete, or aimed at the wrong thing. Accepting output unchanged is not an
edit. Reformatting is not an edit. It measures YOUR judgement, not the AI's
prose -- which is why a long stretch of work with zero edits is worth a second
look rather than a pat on the back.

Usage (normally invoked by the PowerShell/bash wrappers):
  harness_human_log.py <root> --minutes 95 --edits 6 --task "F4 telemetry" \\
      --session-id abc123 --rework --note "bo mot vong estimate"
"""
import argparse
import datetime as _dt
import glob
import json
import os
import sys

SCHEMA_VERSION = "1.0.0"
MAX_MINUTES = 1440          # one day; beyond this it is a typo, not a marathon
MAX_EDITS = 1000
COINCIDENCE_TOLERANCE = 0.02


def _today():
    return _dt.date.today()


def machine_minutes_for_session(root, session_id, day):
    """Sum machine latency for one session from the daily telemetry file.

    Best-effort and deliberately narrow: reads only the one daily file for the
    given day. A missing file, a malformed line or an unreadable directory
    returns None -- this is a cross-check, and a cross-check that can fail the
    write it is checking would be worse than no cross-check.
    """
    if not session_id:
        return None
    path = os.path.join(root, ".harness", "telemetry", "daily-%s.jsonl" % day.isoformat())
    if not os.path.exists(path):
        return None
    total_ms = 0
    found = False
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("session_id") != session_id:
                    continue
                ms = rec.get("latency_ms")
                if isinstance(ms, (int, float)) and ms >= 0:
                    total_ms += ms
                    found = True
    except (IOError, OSError):
        return None
    if not found:
        return None
    return total_ms / 60000.0


def build_record(args):
    """Return (record, error). A non-empty error means: do not write."""
    if args.minutes is None:
        return None, "--minutes is required (minutes a person actually spent)"
    if args.minutes < 1 or args.minutes > MAX_MINUTES:
        return None, "minutes must be 1..%d, got %s" % (MAX_MINUTES, args.minutes)
    if args.edits is None:
        return None, "--edits is required (use 0 if you genuinely changed nothing)"
    if args.edits < 0 or args.edits > MAX_EDITS:
        return None, "edits must be 0..%d, got %s" % (MAX_EDITS, args.edits)

    if args.date:
        try:
            day = _dt.datetime.strptime(args.date, "%Y-%m-%d").date()
        except ValueError:
            return None, "date must be YYYY-MM-DD, got %r" % args.date
    else:
        day = _today()
    if day > _today():
        return None, "date is in the future: %s" % day.isoformat()

    rec = {
        "schema_version": SCHEMA_VERSION,
        "ts": _dt.datetime.now().astimezone().isoformat(),
        "date": day.isoformat(),
        "session_id": args.session_id or "",
        "task": (args.task or "").strip(),
        # F5: links this block of effort to a frozen pre-AI estimate in
        # baseline-w0.json. Optional on purpose -- forcing it would push people
        # to pick a ref that nearly fits, and a wrong numerator is worse than a
        # missing one. Entries without it still record effort; they are excluded
        # from Nen and the KPI report states what share that was.
        "baseline_ref": (args.baseline_ref or "").strip(),
        "human_minutes": int(args.minutes),
        "human_edits": int(args.edits),
        "rework": bool(args.rework),
        "unplanned": bool(args.unplanned),
        "note": (args.note or "").strip(),
        # Carried in the data, not only in a docstring.
        "self_reported": True,
    }
    return rec, ""


def annotate_machine_time(root, rec):
    """Attach machine time and flag a suspicious coincidence. Never raises."""
    try:
        day = _dt.datetime.strptime(rec["date"], "%Y-%m-%d").date()
        mm = machine_minutes_for_session(root, rec["session_id"], day)
    except Exception:
        mm = None
    if mm is None:
        rec["machine_minutes"] = None
        rec["matches_machine_duration"] = False
        return ""
    rec["machine_minutes"] = round(mm, 2)
    hm = float(rec["human_minutes"])
    if mm > 0 and abs(hm - mm) / mm <= COINCIDENCE_TOLERANCE:
        rec["matches_machine_duration"] = True
        return ("human_minutes (%s) is within %d%% of this session's machine time "
                "(%.1f). If it was read off the clock rather than counted, the row "
                "is not effort data. Marked matches_machine_duration=true."
                % (rec["human_minutes"], int(COINCIDENCE_TOLERANCE * 100), mm))
    rec["matches_machine_duration"] = False
    return ""


def append_record(root, rec):
    path = os.path.join(root, ".harness", "telemetry", "human-effort.jsonl")
    d = os.path.dirname(path)
    if not os.path.isdir(d):
        os.makedirs(d)
    line = json.dumps(rec, ensure_ascii=False, sort_keys=True)
    # No BOM: this file is read by non-Python tooling too, and a BOM on line 1
    # makes it invalid JSONL for jq and most readers (see AVOID/evidence-files).
    with open(path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(line + "\n")
    return path


def main(argv):
    p = argparse.ArgumentParser(
        description="Append one human-effort record. Minutes are counted by a person, never derived.")
    p.add_argument("root", nargs="?", default=".")
    p.add_argument("--minutes", type=int, help="minutes a person actually spent (1..1440)")
    p.add_argument("--edits", type=int, help="times you corrected/overrode the AI (0 is allowed, and interesting)")
    p.add_argument("--task", default="", help="short label, e.g. 'F4 telemetry'")
    p.add_argument("--session-id", default=os.environ.get("CLAUDE_SESSION_ID", ""))
    p.add_argument("--date", default="", help="YYYY-MM-DD; defaults to today")
    p.add_argument("--rework", action="store_true", help="an artefact had to be redone")
    p.add_argument("--unplanned", action="store_true",
                   help="work outside the plan (analysis, docs, meetings) — log it or the picture inflates one way")
    p.add_argument("--note", default="", help="one short line, optional")
    p.add_argument("--baseline-ref", default="",
                   help="id in .harness/control/baseline-w0.json — required for this entry to count toward Nen (F5)")
    args = p.parse_args(argv)

    root = os.path.abspath(args.root)

    rec, err = build_record(args)
    if err:
        sys.stderr.write("[human-log] REJECTED: %s\n" % err)
        return 2

    warn = annotate_machine_time(root, rec)
    path = append_record(root, rec)

    sys.stdout.write("[human-log] %s min - %s edit(s)%s%s -> %s\n" % (
        rec["human_minutes"], rec["human_edits"],
        " - rework" if rec["rework"] else "",
        " - unplanned" if rec["unplanned"] else "",
        os.path.relpath(path, root)))
    if warn:
        sys.stdout.write("[human-log] WARNING: %s\n" % warn)
    return 0


if __name__ == "__main__":
    # Consuming projects run on Windows consoles whose codepage (cp932, cp1252,
    # ...) cannot encode an em-dash; one such glyph in a SKIP/WARN line raised
    # UnicodeEncodeError AFTER the counts printed, so harness-eval recorded a
    # clean run as failed (AllIn1Site, 2026-10-06). Same guard as harness_doctor.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    sys.exit(main(sys.argv[1:]))
