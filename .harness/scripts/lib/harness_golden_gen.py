#!/usr/bin/env python3
"""harness golden-gen — draft domain golden cases from a project's own spec.

Eight of nine consuming projects reported the same thing: their golden dataset
held only the 12 generic security cases the bundle ships (deny rm -rf, ...) and
zero cases about what their software actually does, because writing domain cases
by hand is tedious enough that nobody starts. So H3 measured the same thing
everywhere and measured nothing about the product.

This reads the project's spec (SRS/spec/requirements markdown) and emits ONE
skeleton case per requirement it can identify, into a separate `*-draft.jsonl`
that a human completes.

What it will NOT do, deliberately: invent an `expect`. A generated expectation is
a guess wearing the costume of a test -- it would pass or fail for reasons no one
chose, and the first time it failed someone would "fix" the product to match a
machine's invention. Every emitted case carries `"expect": null` and
`"_todo": "fill in expected result"`, and the runner is expected to skip drafts.
Filling them in is the human's job; finding and framing them is this script's.

Usage:
  python harness_golden_gen.py <project-root> [--spec docs/SRS.md] [--out <path>]
  python harness_golden_gen.py . --dry-run      # print, write nothing
"""
import argparse
import json
import os
import re
import sys

# Spec files to try when --spec is not given, in order of specificity.
SPEC_CANDIDATES = [
    "docs/SRS.md", "docs/srs.md", "SRS.md",
    "docs/spec.md", "docs/specification.md", "spec.md",
    "docs/requirements.md", "requirements.md",
]

# A requirement heading looks like one of:
#   ### FR-12 Something the system does
#   ## 4.2 Login flow
#   - **FR-3**: the system must ...
# The ID is optional; a heading with an imperative is still a requirement.
RE_HEADING = re.compile(r"^(#{2,4})\s+(?:(FR|NFR|REQ|US)[-_ ]?(\d+[\.\d]*)\s*[:.\-–—]?\s*)?(.+?)\s*$")
RE_BULLET_ID = re.compile(r"^\s*[-*]\s+\*{0,2}(FR|NFR|REQ|US)[-_ ]?(\d+[\.\d]*)\*{0,2}\s*[:.\-–—]\s*(.+?)\s*$")

# Headings that are structure, not requirements. Skipping these is what keeps the
# draft file worth opening -- a skeleton per "Table of Contents" is noise.
SKIP_TITLES = {
    "table of contents", "contents", "overview", "introduction", "glossary",
    "references", "revision history", "changelog", "appendix", "index",
    "mục lục", "tổng quan", "giới thiệu", "thuật ngữ", "tài liệu tham khảo",
    "lịch sử thay đổi", "phụ lục",
}

# Weak signal, but a useful one: a requirement usually contains an obligation.
OBLIGATION = re.compile(
    r"\b(must|shall|should|cannot|must not|is required to|returns?|rejects?|"
    r"validates?|allows?|denies|prevents?|phải|không được|trả về|từ chối|cho phép)\b",
    re.IGNORECASE,
)


def find_spec(root, explicit):
    if explicit:
        p = os.path.join(root, explicit) if not os.path.isabs(explicit) else explicit
        return p if os.path.isfile(p) else None
    for rel in SPEC_CANDIDATES:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            return p
    return None


def slug(text, n=6):
    words = re.findall(r"[A-Za-z0-9]+", text.lower())
    return "-".join(words[:n]) or "case"


def extract(spec_text):
    """Yield (req_id, title, context_line) for each requirement-looking item."""
    seen = set()
    lines = spec_text.splitlines()
    for i, raw in enumerate(lines):
        line = raw.rstrip()
        rid = title = None

        m = RE_BULLET_ID.match(line)
        if m:
            rid, title = "%s-%s" % (m.group(1).upper(), m.group(2)), m.group(3)
        else:
            m = RE_HEADING.match(line)
            if m:
                kind, num, text = m.group(2), m.group(3), m.group(4)
                title = text
                rid = ("%s-%s" % (kind.upper(), num)) if kind and num else None

        if not title:
            continue
        clean = re.sub(r"[*`#]", "", title).strip()
        if not clean or clean.lower() in SKIP_TITLES or len(clean) < 6:
            continue

        # Body: the first following non-empty, non-heading line gives the case
        # some grounding so the human filling in `expect` has the requirement in
        # front of them instead of just a title.
        body = ""
        for nxt in lines[i + 1:i + 6]:
            s = nxt.strip()
            if not s or s.startswith("#"):
                continue
            body = re.sub(r"[*`]", "", s)[:300]
            break

        # Keep it if it has an explicit ID, or reads like an obligation.
        if not rid and not OBLIGATION.search(clean + " " + body):
            continue

        key = (rid or "", clean.lower())
        if key in seen:
            continue
        seen.add(key)
        yield rid, clean, body


def build_case(idx, rid, title, body, spec_rel):
    return {
        "id": "d-%s-%s" % (str(idx).zfill(3), slug(title)),
        "layer": "H3",
        "kind": "domain",
        "status": "draft",
        "requirement_id": rid or "",
        "requirement": title,
        "context": body,
        "spec_ref": spec_rel,
        "input": None,
        # Never guessed. See the module docstring: a fabricated expectation is a
        # test that passes or fails for a reason nobody chose.
        "expect": None,
        "_todo": "fill in `input` and `expect`, then set status to \"ready\"",
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="Draft domain golden cases from a project's spec")
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--spec", default=None, help="path to the spec (default: auto-detect)")
    ap.add_argument("--out", default=None, help="output jsonl (default: .harness/eval/golden/<name>-draft.jsonl)")
    ap.add_argument("--dry-run", action="store_true", help="print to stdout, write nothing")
    a = ap.parse_args(argv)

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    root = os.path.abspath(a.root)
    spec = find_spec(root, a.spec)
    if not spec:
        print("no spec found (looked for %s). Pass --spec <path>." % ", ".join(SPEC_CANDIDATES))
        return 2

    spec_rel = os.path.relpath(spec, root).replace("\\", "/")
    with open(spec, encoding="utf-8-sig") as f:
        text = f.read()

    cases = [build_case(i + 1, rid, title, body, spec_rel)
             for i, (rid, title, body) in enumerate(extract(text))]

    if not cases:
        print("read %s but found no requirement-shaped headings or bullets." % spec_rel)
        print("Nothing written -- an empty draft file would just look like a broken run.")
        return 1

    out = a.out or os.path.join(root, ".harness", "eval", "golden",
                                "%s-draft.jsonl" % os.path.basename(root).lower())
    payload = "\n".join(json.dumps(c, ensure_ascii=False) for c in cases) + "\n"

    if a.dry_run:
        print(payload, end="")
        print("-- dry run: %d draft case(s) from %s, nothing written" % (len(cases), spec_rel))
        return 0

    os.makedirs(os.path.dirname(out), exist_ok=True)
    # Never clobber: drafts a human has started filling in are the expensive part.
    if os.path.exists(out):
        print("refusing to overwrite existing %s" % os.path.relpath(out, root))
        print("Delete it, or pass --out <other path>, if you really want to regenerate.")
        return 1
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(payload)

    print("wrote %d DRAFT case(s) -> %s" % (len(cases), os.path.relpath(out, root).replace("\\", "/")))
    print("Source: %s" % spec_rel)
    print("")
    print("These are skeletons, not tests. Each has expect=null and will not")
    print("assert anything until a human fills in `input`/`expect` and flips")
    print("status to \"ready\". That is on purpose -- a generated expectation is a")
    print("guess, and a guess that fails gets 'fixed' in the product.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
