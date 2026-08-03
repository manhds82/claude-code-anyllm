#!/usr/bin/env python3
"""Resolve which test suites to run from changed files + impact-map.json.

Usage:  python select-suites.py <impact-map.json> <changed-file> [<changed-file> ...]
Prints exactly one line:  "ALL" | "NONE" | "policy-ci" | "red-team" | "policy-ci red-team"

Safety: any core-glob match, any unknown file, or any error -> "ALL".
Empty / no changed files -> "NONE". The QA gate always runs the full suite,
so this is only a dev-time speed-up, never the last line of defence.
"""
import sys
import json
import fnmatch


def main():
    if len(sys.argv) < 3:
        print("ALL")
        return
    mapfile = sys.argv[1]
    changed = [c.replace("\\", "/").strip() for c in sys.argv[2:] if c.strip()]
    if not changed:
        print("NONE")
        return
    try:
        with open(mapfile, encoding="utf-8") as fh:
            m = json.load(fh)
    except Exception:
        print("ALL")
        return
    core = m.get("core_globs", [])
    rules = m.get("rules", [])
    suites = set()
    for f in changed:
        if any(fnmatch.fnmatch(f, g) for g in core):
            print("ALL")
            return
        matched = False
        for r in rules:
            if any(fnmatch.fnmatch(f, w) for w in r.get("when", [])):
                suites.update(r.get("suites", []))
                matched = True
                break
        if not matched:
            print("ALL")  # unknown file -> be safe, run everything
            return
    if not suites:
        print("NONE")
        return
    print(" ".join(s for s in ("policy-ci", "red-team") if s in suites))


if __name__ == "__main__":
    main()
