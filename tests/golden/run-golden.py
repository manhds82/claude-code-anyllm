#!/usr/bin/env python3
"""Run golden fixtures: feed each case's changed-files to the impact resolver
and assert the output matches the expected suite selection.

Exit 0 = all golden cases pass; exit 1 = at least one mismatch (printed).
Deterministic and offline. Invoked by both test runners as one policy-ci check.
"""
import sys
import os
import json
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CASES = os.path.join(ROOT, "tests", "golden", "select-suites.cases.json")
RESOLVER = os.path.join(ROOT, "tests", "select-suites.py")
IMPACT_MAP = os.path.join(ROOT, "tests", "impact-map.json")


def main():
    with open(CASES, encoding="utf-8") as fh:
        cases = json.load(fh)["cases"]
    fails = []
    for c in cases:
        got = subprocess.run(
            [sys.executable, RESOLVER, IMPACT_MAP] + c["changed"],
            capture_output=True, text=True,
        ).stdout.strip()
        if got != c["expect"]:
            fails.append("%s -> got '%s' expect '%s'" % (c["changed"], got, c["expect"]))
    if fails:
        print("GOLDEN MISMATCH:\n  " + "\n  ".join(fails))
        return 1
    print("golden OK (%d cases)" % len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
