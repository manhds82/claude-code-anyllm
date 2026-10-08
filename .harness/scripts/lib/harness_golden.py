#!/usr/bin/env python3
"""H3 golden-set regression runner.

Evaluates `.harness/eval/golden/golden-cases.jsonl` against the project's REAL
deny policy (`.harness/control/risk-policy.yaml` command_deny_patterns) — the
same regexes the PreToolUse guard uses. For each case it predicts deny/allow and
compares to the expected label. This turns the golden dataset from a declared
path into a real regression the eval gate (H3) requires.

Reporting: this runner does NOT append to test-reports.jsonl itself. It prints
the counts in the format `harness-eval` parses ("Passed : N"), so the eval
runner stays the single writer of the telemetry file — one report per run, one
consistent `triggered_by`/timestamp. Declare it in casan-policies.yaml under
`evaluation.suite_commands.golden`.

Usage:  python harness_golden.py <repo_root>
Exit:   0 when every case matches, 1 when any case fails (usable as a CI gate).
"""
import json
import os
import re
import sys


def _load_deny_patterns(root, path=None):
    """Naive YAML scrape of `pattern:` values under command_deny_patterns —
    dependency-free, matches how the guard reads its policy. `path` overrides
    the file (policy-ci reads the installer's risk-policy.yaml.new with it)."""
    p = path or os.path.join(root, ".harness", "control", "risk-policy.yaml")
    pats = []
    if not os.path.isfile(p):
        return pats
    in_block = False
    for raw in open(p, encoding="utf-8-sig"):
        s = raw.strip()
        if re.match(r"^command_deny_patterns\s*:", raw):
            in_block = True
            continue
        if in_block:
            m = re.search(r'pattern\s*:\s*"?(.+?)"?\s*$', s)
            if m:
                # YAML double-quoted scalars escape backslash as "\\"; decode
                # back to a single "\" so "\\s" becomes the real regex "\s".
                pats.append(m.group(1).replace("\\\\", "\\"))
            elif raw and not raw[0].isspace() and re.match(r"^\w+\s*:", raw):
                in_block = False  # a NON-indented key = next top-level section
    return pats


def _dataset_dir(root):
    """Read evaluation.golden_dataset_path from casan-policies (C2: the location
    is config, not code). Naive scrape so the runner stays dependency-free."""
    p = os.path.join(root, ".harness", "control", "casan-policies.yaml")
    if os.path.isfile(p):
        for raw in open(p, encoding="utf-8-sig"):
            m = re.match(r'^\s*golden_dataset_path\s*:\s*"?([^"#\r\n]+?)"?\s*(#.*)?$', raw)
            if m and m.group(1).strip():
                return m.group(1).strip()
    return ".harness/eval/golden/"


def _case_files(root):
    """EVERY *.jsonl under the declared dataset dir, sorted for determinism. A
    project keeps its own cases in its own file (e.g. my-project-cases.jsonl)
    next to the shipped baseline, so an update never has to touch them."""
    d = os.path.join(root, _dataset_dir(root).replace("/", os.sep))
    if not os.path.isdir(d):
        return []
    return sorted(
        os.path.join(d, n) for n in os.listdir(d)
        if n.lower().endswith(".jsonl") and n.lower() not in _NOT_GOLDEN
        and os.path.isfile(os.path.join(d, n))
    )


# Fixtures of OTHER guards that projects keep in the same dir. redteam-cases.jsonl
# holds prompt-injection cases for the injection guard; replaying it against the
# command deny patterns scores every injection prompt "allowed" -- a false red
# (C14). The 1.7 upgrade dropped this exclusion; 1.8.2 restores it.
_NOT_GOLDEN = frozenset({"redteam-cases.jsonl"})


def run(root):
    case_files = _case_files(root)
    if not case_files:
        return None
    pats = [p for p in _load_deny_patterns(root)]
    compiled = []
    for p in pats:
        try:
            compiled.append(re.compile(p))
        except re.error:
            continue  # a bad regex in policy never breaks the runner (fail-open)

    passed = failed = 0
    fails = []
    for cases_p in case_files:
        for line in open(cases_p, encoding="utf-8-sig"):
            line = line.strip()
            if not line:
                continue
            try:
                c = json.loads(line)
            except json.JSONDecodeError:
                continue
            inp = c.get("input", "")
            expect = c.get("expect", "")
            predicted = "deny" if any(rx.search(inp) for rx in compiled) else "allow"
            if predicted == expect:
                passed += 1
            else:
                failed += 1
                fails.append({"id": c.get("id"), "expect": expect, "got": predicted})

    return {"passed": passed, "failed": failed, "fails": fails}


if __name__ == "__main__":
    # Consuming projects run on Windows consoles whose codepage (cp932, cp1252,
    # ...) cannot encode an em-dash; one such glyph in a SKIP/WARN line raised
    # UnicodeEncodeError AFTER the counts printed, so harness-eval recorded a
    # clean run as failed (AllIn1Site, 2026-10-06). Same guard as harness_doctor.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    r = run(root)
    if r is None:
        # No dataset = nothing to assert. Say so plainly and do not claim a pass.
        print("golden: no cases file - skipped")
        sys.exit(0)
    # Counts in the shape harness-eval / harness-release parse.
    print("Passed : %d" % r["passed"])
    print("Failed : %d" % r["failed"])
    print("Skipped : 0")
    if r["fails"]:
        print("golden failures: " + json.dumps(r["fails"]))
    sys.exit(1 if r["failed"] else 0)
