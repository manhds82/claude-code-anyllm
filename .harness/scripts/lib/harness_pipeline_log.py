#!/usr/bin/env python3
"""Record one Agent Pack pipeline run (P-7).

The Agent Pack shipped to eleven projects and there has been no way to answer
"is anyone running it, and does it work" -- the skill prints a report to a
terminal and the report is gone. This appends one line per run to
.harness/telemetry/pipeline-runs.jsonl, which push-telemetry ships to the Portal.

WHAT THIS IS, EXACTLY
---------------------
A self-report by the agent that ran the loop. It is a DECLARATION, not proof.
Nothing here re-derives the findings or re-runs the tests, so a run record can
say "3 confirmed, 3 fixed, APPROVED" whether or not that happened. That limit is
carried in the data (`self_reported: true`) and stated on the screen, because a
number whose provenance is invisible gets read as measurement -- the failure C12
exists to stop.

Two things ARE checked here, because they are cheap and they catch the honest
mistakes rather than the dishonest ones:

  - the counts have to be internally consistent (you cannot fix more findings
    than were confirmed, or confirm more than were found)
  - the verdict has to be one of the values the qa-gate skill can emit

An inconsistent record is REJECTED rather than written. A malformed run record
that lands in the log becomes a permanently wrong row on a dashboard, and the
whole point of the dashboard is that its rows are trustworthy.

Usage (normally invoked by the PowerShell/bash wrappers):
  harness_pipeline_log.py <root> --skill impact-review --pipeline-id p-123 \\
      --verdict APPROVED --found 7 --confirmed 3 --dropped 4 --fixed 3 \\
      --retries 1 --files 12 --tests-passed 81 --tests-failed 0 \\
      --duration-s 240 --base HEAD~1 --head HEAD --force-full false
"""
import argparse
import json
import os
import sys
import time

VERDICTS = ("APPROVED", "CHANGES_REQUIRED", "REJECTED", "ESCALATED", "ABORTED")

# Skills that run a bounded agent loop and therefore have a run worth recording.
# A free-form value is still accepted (a project may add its own); it is simply
# not one this toolkit knows how to interpret.
KNOWN_SKILLS = ("impact-review", "run-affected-tests", "qa-gate", "verify-implementation",
                "implement-change", "analyze-requirements", "verify-request", "evidence-bundle")


def build(args):
    """Validated record, or (None, reason)."""
    if args.verdict not in VERDICTS:
        return None, "verdict %r is not one of %s" % (args.verdict, ", ".join(VERDICTS))

    found, confirmed, dropped = args.found, args.confirmed, args.dropped
    fixed, retries = args.fixed, args.retries

    for name, n in (("found", found), ("confirmed", confirmed), ("dropped", dropped),
                    ("fixed", fixed), ("retries", retries)):
        if n < 0:
            return None, "%s cannot be negative (%d)" % (name, n)

    # Adversarial verification splits findings into confirmed and dropped, so
    # the two must account for the whole set. A record where they do not means
    # something was miscounted, and a miscounted row is worse on a dashboard
    # than a missing one.
    if confirmed + dropped > found:
        return None, ("confirmed(%d) + dropped(%d) exceeds found(%d) -- adversarial "
                      "verification partitions the findings, it cannot invent them"
                      % (confirmed, dropped, found))
    if fixed > confirmed:
        return None, ("fixed(%d) exceeds confirmed(%d) -- the fixer only touches CONFIRMED "
                      "findings; anything else is editing working code on a refuted claim"
                      % (fixed, confirmed))

    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "skill": args.skill,
        "pipeline_id": args.pipeline_id,
        "verdict": args.verdict,
        "found": found,
        "confirmed": confirmed,
        "dropped": dropped,
        "fixed": fixed,
        "retries": retries,
        "files_in_impact": args.files,
        "force_full": bool(args.force_full and args.force_full.lower() in ("1", "true", "yes")),
        "tests_passed": args.tests_passed,
        "tests_failed": args.tests_failed,
        "duration_s": args.duration_s,
        "base": args.base,
        "head": args.head,
        # Carried in the data, not only in a docstring: whoever reads this row
        # three months from now needs to know it was self-reported without
        # having to find this file.
        "self_reported": True,
    }, ""


def main(argv):
    p = argparse.ArgumentParser(description="Append one Agent Pack pipeline run record.")
    p.add_argument("root")
    p.add_argument("--skill", required=True)
    p.add_argument("--pipeline-id", default="")
    p.add_argument("--verdict", required=True)
    p.add_argument("--found", type=int, default=0)
    p.add_argument("--confirmed", type=int, default=0)
    p.add_argument("--dropped", type=int, default=0)
    p.add_argument("--fixed", type=int, default=0)
    p.add_argument("--retries", type=int, default=0)
    p.add_argument("--files", type=int, default=0)
    p.add_argument("--force-full", default="false")
    p.add_argument("--tests-passed", type=int, default=0)
    p.add_argument("--tests-failed", type=int, default=0)
    p.add_argument("--duration-s", type=int, default=0)
    p.add_argument("--base", default="")
    p.add_argument("--head", default="")
    args = p.parse_args(argv[1:])

    rec, why = build(args)
    if rec is None:
        sys.stderr.write("[pipeline-log] REJECTED: %s\n" % why)
        return 2

    tel = os.path.join(args.root, ".harness", "telemetry")
    os.makedirs(tel, exist_ok=True)
    path = os.path.join(tel, "pipeline-runs.jsonl")
    # Explicit newline="" + utf-8 (no BOM). Add-Content -Encoding utf8 once wrote
    # a BOM into a JSONL here and the first line stopped parsing for everyone
    # downstream; that class of bug is not repeated.
    with open(path, "a", encoding="utf-8", newline="") as f:
        f.write(json.dumps(rec, separators=(",", ":"), ensure_ascii=False) + "\n")
    sys.stdout.write("[pipeline-log] %s %s -> %s\n" % (rec["skill"], rec["verdict"], path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
