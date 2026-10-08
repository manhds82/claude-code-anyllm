#!/usr/bin/env python3
"""Requirements traceability check (F7): which story has no test covering it?

WHAT WAS ALREADY HERE, AND WHAT WAS NOT
---------------------------------------
This system already threads a `traceability_id` (TRC-nnnn) through idempotency
keys, workflow stages and the PreCompact hook, and the judge rubric scores a
Traceability dimension. All of that answers "which run produced this output" --
operational traceability, a thread from an artefact back to an ID.

It does not answer the requirements question: given the stories in the spec,
which ones does nothing test? qa-gate scores the tests that EXIST, so a story no
test covers passes a green gate. The gate is not lying; it was never asked.

HOW IT WORKS
------------
1. Find the spec: contracts/project.yaml -> domain_refs.srs, else the
   spec_candidates / srs_candidates lists in casan-policies.yaml.
2. Extract story ids from the spec: US-01, REQ-3, FR-12, TRC-4821 ... any
   <LETTERS>-<digits> token that appears as a heading or in bold/backticks.
3. Scan the test tree for each id as a literal string -- in a test name, a
   docstring, a comment, a parametrize label. Anything counts: the claim being
   checked is "a human can trace this story to something that runs", not
   "the framework auto-derived a link".
4. Report PASS / GAP.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It does not assert that a test which MENTIONS US-07 actually verifies US-07.
Nothing here could check that, and pretending otherwise would manufacture
exactly the false assurance the harness exists to prevent. A story marked PASS
means "someone wrote the id next to a test", which is a floor, not a ceiling.
The output says so.

Usage:
  harness_rtm.py <root> [--spec PATH] [--tests DIR] [--json] [--fail-on-gap]
"""
import argparse
import json
import os
import re
import sys

ID_RE = re.compile(r"\b([A-Z]{2,5}-\d{1,5})\b")
TEST_EXT = (".py", ".ps1", ".sh", ".js", ".ts", ".tsx", ".java", ".cs", ".go", ".rb")
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build",
             ".harness", ".pytest_cache", ".benchmarks"}


def find_spec(root, explicit):
    if explicit:
        p = explicit if os.path.isabs(explicit) else os.path.join(root, explicit)
        return (p, "tham so --spec") if os.path.exists(p) else (None, "khong thay %s" % explicit)

    pj = os.path.join(root, "contracts", "project.yaml")
    if os.path.exists(pj):
        try:
            with open(pj, "r", encoding="utf-8-sig") as fh:
                block = False
                for line in fh:
                    if re.match(r"^\s*domain_refs:", line):
                        block = True
                        continue
                    if block:
                        m = re.match(r"^\s*srs:\s*\"?([^\"\n]+)\"?", line)
                        if m:
                            cand = m.group(1).strip()
                            if cand:
                                p = os.path.join(root, cand)
                                if os.path.exists(p):
                                    return p, "project.yaml#domain_refs.srs"
                                return None, ("domain_refs.srs tro toi %s nhung file khong ton tai "
                                              "-- day dung la bay 'installer ghi de domain_refs'" % cand)
                        if re.match(r"^\s*\S+:", line) and not re.match(r"^\s{4,}\S", line):
                            block = False
        except (IOError, OSError):
            pass

    # Exact names first: a project that named its spec canonically wins over any
    # pattern guess.
    for cand in ("docs/SPEC.md", "docs/SRS.md", "docs/spec.md", "SRS.md",
                 "docs/harness-spec.md"):
        p = os.path.join(root, cand)
        if os.path.exists(p):
            return p, "mac dinh (%s)" % cand

    # Then search. Measured need, not speculation: the first real repo this ran
    # against keeps its spec at docs/01-requirements/SRS-FLA-v1.0.html with the
    # stories beside it in STORIES-FLA.md -- a perfectly ordinary layout that the
    # exact-name list above misses entirely, and missing it reported "no spec"
    # on a project that has a good one.
    pats = ("srs", "stories", "requirement", "spec", "user-stor", "userstor")
    cands = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, "docs")):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.lower().endswith((".md", ".markdown")):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if any(x in rel.lower() for x in pats):
                cands.append(rel)
    if cands:
        # Deterministic across runs: shallowest path, then alphabetical.
        cands.sort(key=lambda r: (r.count("/"), r))
        return os.path.join(root, cands[0]), "tim thay trong docs/ (%s)" % cands[0]
    return None, "khong tim thay spec nao"


def extract_ids(spec_path, prefixes=None):
    """Story ids from headings, bold text and backticks -- places a spec names a
    requirement, rather than every id mentioned in passing prose."""
    ids = {}
    try:
        with open(spec_path, "r", encoding="utf-8-sig") as fh:
            for n, line in enumerate(fh, 1):
                stripped = line.strip()
                salient = (stripped.startswith("#") or stripped.startswith("|")
                           or "**" in stripped or "`" in stripped
                           or stripped.startswith("- ") or stripped.startswith("* "))
                if not salient:
                    continue
                for m in ID_RE.finditer(stripped):
                    sid = m.group(1)
                    # A real spec often carries several ID families at once:
                    # US-* stories, FR-* sub-requirements, NFR-*, TRC-*. Counting
                    # them all makes "41 stories" out of maybe 15, and every
                    # sub-requirement then reads as an uncovered story. --id-prefix
                    # lets the caller say which family IS the story.
                    if prefixes and not any(sid.startswith(x) for x in prefixes):
                        continue
                    if sid not in ids:
                        title = re.sub(r"^[#*\-|\s`]+", "", stripped)[:70]
                        ids[sid] = {"line": n, "title": title}
    except (IOError, OSError) as e:
        return {}, str(e)
    return ids, ""


def scan_tests(root, test_dirs):
    """Map id -> [files mentioning it]."""
    hits = {}
    for td in test_dirs:
        base = td if os.path.isabs(td) else os.path.join(root, td)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                if not fn.endswith(TEST_EXT):
                    continue
                p = os.path.join(dirpath, fn)
                try:
                    with open(p, "r", encoding="utf-8-sig", errors="replace") as fh:
                        content = fh.read()
                except (IOError, OSError):
                    continue
                for m in ID_RE.finditer(content):
                    hits.setdefault(m.group(1), set()).add(os.path.relpath(p, root))
    return {k: sorted(v) for k, v in hits.items()}


def default_test_dirs(root):
    found = [d for d in ("tests", "test", "spec", "__tests__") if os.path.isdir(os.path.join(root, d))]
    for sub in ("portal", "src", "app"):
        p = os.path.join(root, sub)
        if os.path.isdir(p):
            for dirpath, dirnames, _ in os.walk(p):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                for d in list(dirnames):
                    if d in ("tests", "test", "__tests__"):
                        found.append(os.path.relpath(os.path.join(dirpath, d), root))
    return sorted(set(found))


def run(root, spec_arg, test_dirs, prefixes=None):
    spec, how = find_spec(root, spec_arg)
    out = {"spec": spec and os.path.relpath(spec, root), "spec_found_via": how,
           "test_dirs": [], "stories": [], "summary": {}}
    if not spec:
        out["summary"] = {"status": "NO_SPEC", "message": how}
        return out

    ids, err = extract_ids(spec, prefixes)
    if err:
        out["summary"] = {"status": "SPEC_UNREADABLE", "message": err}
        return out

    dirs = test_dirs or default_test_dirs(root)
    out["test_dirs"] = dirs
    hits = scan_tests(root, dirs)

    covered = 0
    for sid in sorted(ids):
        files = hits.get(sid, [])
        if files:
            covered += 1
        out["stories"].append({"id": sid, "title": ids[sid]["title"],
                               "spec_line": ids[sid]["line"],
                               "status": "PASS" if files else "GAP",
                               "tests": files})
    total = len(ids)
    out["summary"] = {
        "status": "PASS" if (total and covered == total) else ("GAP" if total else "NO_IDS"),
        "total": total, "covered": covered, "gaps": total - covered,
        "percent": round(100.0 * covered / total, 1) if total else 0.0,
    }
    return out


def render(res):
    L = []
    s = res["summary"]
    L.append("=" * 66)
    L.append("RTM - truy vet yeu cau <-> test")
    L.append("=" * 66)
    L.append("  spec      : %s   (%s)" % (res["spec"] or "-", res["spec_found_via"]))
    L.append("  thu muc   : %s" % (", ".join(res["test_dirs"]) or "-"))
    L.append("")
    if s["status"] in ("NO_SPEC", "SPEC_UNREADABLE"):
        L.append("  ! %s" % s.get("message", ""))
        return "\n".join(L)
    if s["status"] == "NO_IDS":
        L.append("  ! Khong tim thay story id nao trong spec (mau: US-01, REQ-3, FR-12).")
        L.append("    Spec khong danh so thi khong truy vet duoc - do la ket qua, khong phai loi.")
        return "\n".join(L)

    gaps = [x for x in res["stories"] if x["status"] == "GAP"]
    L.append("  %d/%d story co test nhac toi  (%.1f%%)" % (s["covered"], s["total"], s["percent"]))
    L.append("")
    if gaps:
        L.append("  GAP - story khong test nao nhac toi:")
        for g in gaps:
            L.append("    %-10s dong %-5d %s" % (g["id"], g["spec_line"], g["title"]))
        L.append("")
        L.append("  Nhung story tren VAN qua qa-gate xanh: qa-gate cham tren test da co.")
        L.append("  Cong khong noi doi - no chi khong duoc hoi.")
    else:
        L.append("  Khong co GAP.")
    L.append("")
    L.append("  Luu y: PASS o day nghia la co ai do viet id canh mot test.")
    L.append("  No KHONG chung minh test do that su kiem dung story. Day la san, khong phai tran.")
    return "\n".join(L)


def main(argv):
    # Story titles come from the project's spec and may hold any script. This
    # machine's console is cp932; a Vietnamese title would crash the report on
    # write, which would look like a checker bug rather than a console one.
    # errors="replace" keeps the report readable instead of losing it entirely.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="RTM: story nao chua co test nao phu?")
    p.add_argument("root", nargs="?", default=".")
    p.add_argument("--spec", default="", help="duong dan spec; mac dinh lay tu project.yaml#domain_refs.srs")
    p.add_argument("--tests", action="append", default=[], help="thu muc test (lap lai duoc)")
    p.add_argument("--id-prefix", action="append", default=[],
                   help="chi tinh id bat dau bang tien to nay (vd US-). Lap lai duoc.")
    p.add_argument("--json", action="store_true")
    p.add_argument("--fail-on-gap", action="store_true", help="exit 1 khi co GAP (dung trong CI)")
    args = p.parse_args(argv)

    root = os.path.abspath(args.root)
    res = run(root, args.spec, args.tests, args.id_prefix)
    sys.stdout.write((json.dumps(res, ensure_ascii=False, indent=2) if args.json else render(res)) + "\n")
    if args.fail_on_gap and res["summary"].get("gaps"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
