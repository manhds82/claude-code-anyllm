#!/usr/bin/env python3
"""harness_fingerprint -- which release of the bundle is this checkout REALLY at?

The install receipt (.harness/.bundle-manifest.json) is a CLAIM: it says what the
installer last wrote, not what is on disk. A project can claim 1.8.6 while its
files are 1.7.1 (a half-applied update, a restored backup, a hand edit). This
module answers from the files themselves (Portal v2 plan P1 1.8, C12/C13).

How:
  * every file of the project that sits at a path some release shipped is hashed
    NORMALISED -- leading UTF-8 BOM(s) stripped, CRLF -> LF -- the same
    line-ending normalisation pack.ps1 / pack.sh apply (since 1.8.2), plus the
    BOM strip, so a checkout rewritten by core.autocrlf or by a BOM repair does
    not look like a different release;
  * the hashes are compared with the release index
    (.harness/control/release-index.json, built from bundles/*/*.bundle.json by
    tools/harness-bundle/build-release-index.py);
  * for each release V: matches = files whose hash equals V's hash for that
    path; ratio = matches / |paths(V) U project files|, so a file V has that the
    project lacks, and a project file V never had, both lower it;
  * releases are ranked by matches, then ratio. Every release tied at the top is
    one answer, reported as a RANGE (`1.5.0..1.5.1`: the two are byte-identical).

Files at an indexed path that match NO release are reported as `unmatched`
(locally edited, or from a release newer than the index).

Read-only. Exit codes: 0 identified (and the receipt, if any, agrees); 1 identified
but the receipt claims a version outside the matching range; 2 could not identify
(no index / no bundle files) -- unproven, never green.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

INDEX_REL = os.path.join(".harness", "control", "release-index.json")
# The index DESCRIBES releases, so it cannot be part of one's identity: it is
# rebuilt after (or, since 1.8.7, shaped by) the pack, so the copy a release
# ships can only know the releases before it. Counting it made a correctly
# installed release fingerprint as the previous one, "modified" (QA-gate #2, C14).
INDEX_POSIX = ".harness/control/release-index.json"
RECEIPT_REL = os.path.join(".harness", ".bundle-manifest.json")
_BOM = b"\xef\xbb\xbf"


def normalise(data: bytes) -> bytes:
    """Strip leading UTF-8 BOM(s), then CRLF -> LF. Binary (NUL) keeps its bytes."""
    while data.startswith(_BOM):
        data = data[len(_BOM):]
    if b"\0" in data:
        return data
    return data.replace(b"\r\n", b"\n")


def normalised_sha256(data: bytes) -> str:
    return hashlib.sha256(normalise(data)).hexdigest()


def version_key(v: str):
    return tuple(int(p) if p.isdigit() else 0 for p in re.split(r"[.\-]", v))


# -- index ------------------------------------------------------------------

def load_index(path: str) -> dict:
    with open(path, "r", encoding="utf-8-sig") as f:
        idx = json.load(f)
    if not isinstance(idx, dict) or "versions" not in idx or "files" not in idx:
        raise ValueError("not a release index: %s" % path)
    return idx


def expand_index(idx: dict):
    """-> (ordered versions, {version: {path: sha}}, {path: {sha: set(versions)}})."""
    order = [v["version"] if isinstance(v, dict) else v for v in idx["versions"]]
    pos = {v: i for i, v in enumerate(order)}
    per_version = {v: {} for v in order}
    by_path = {}
    for path, entries in idx["files"].items():
        for ent in entries:
            sha = ent["sha256"]
            for rng in ent["versions"]:
                a, _, b = rng.partition("..")
                b = b or a
                for v in order[pos[a]:pos[b] + 1]:
                    per_version[v][path] = sha
                    by_path.setdefault(path, {}).setdefault(sha, set()).add(v)
    return order, per_version, by_path


def range_label(versions: list, order: list) -> str:
    """`a..b` for a contiguous run in release order, else a comma list."""
    if not versions:
        return ""
    pos = {v: i for i, v in enumerate(order)}
    vs = sorted(versions, key=lambda v: pos[v])
    runs, start, prev = [], vs[0], vs[0]
    for v in vs[1:]:
        if pos[v] == pos[prev] + 1:
            prev = v
            continue
        runs.append((start, prev))
        start = prev = v
    runs.append((start, prev))
    return ", ".join(a if a == b else "%s..%s" % (a, b) for a, b in runs)


# -- project ----------------------------------------------------------------

def read_receipt(root: str):
    """(claimed version | None, source note). The receipt is a claim, not evidence."""
    path = os.path.join(root, RECEIPT_REL)
    if not os.path.isfile(path):
        return None, "no install receipt at %s" % RECEIPT_REL.replace(os.sep, "/")
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        v = data.get("version") or data.get("bundle_version")
        return (str(v) if v else None), "install receipt"
    except Exception as e:  # noqa: BLE001 - report, never crash a diagnostic
        return None, "install receipt unreadable (%s)" % type(e).__name__


def _unsafe_rel(rel: str) -> bool:
    """An index path must be a plain relative path inside the root."""
    if not rel or os.path.isabs(rel) or rel.startswith(("/", "\\")):
        return True
    if re.match(r"^[A-Za-z]:", rel):
        return True
    return ".." in re.split(r"[\\/]", rel)


def hash_project(root: str, paths, skipped: list | None = None) -> dict:
    """Hash the project's files at the indexed paths. A path that is absolute,
    climbs with `..`, is a symlink, or resolves outside the root is NEVER read:
    it is appended to `skipped` (if given) instead."""
    out = {}
    real_root = os.path.realpath(root)
    for rel in paths:
        if _unsafe_rel(rel):
            if skipped is not None:
                skipped.append(rel)
            continue
        full = os.path.join(root, *rel.split("/"))
        if os.path.islink(full):
            if skipped is not None:
                skipped.append(rel)
            continue
        real = os.path.realpath(full)
        try:
            inside = os.path.commonpath([real_root, real]) == real_root
        except ValueError:
            inside = False
        if not inside:
            if skipped is not None:
                skipped.append(rel)
            continue
        if os.path.isfile(full):
            try:
                with open(full, "rb") as f:
                    out[rel] = normalised_sha256(f.read())
            except OSError:
                continue
    return out


def fingerprint(root: str, index_path: str) -> dict:
    idx = load_index(index_path)
    order, per_version, by_path = expand_index(idx)
    by_path.pop(INDEX_POSIX, None)
    for pv in per_version.values():
        pv.pop(INDEX_POSIX, None)
    skipped: list = []
    project = hash_project(root, by_path.keys(), skipped)
    claimed, claim_src = read_receipt(root)
    res = {
        "root": os.path.abspath(root),
        "index": {"path": os.path.abspath(index_path), "bundle": idx.get("bundle", ""),
                  "releases": len(order), "newest": order[-1] if order else ""},
        "files_checked": len(project),
        "claimed_version": claimed,
        "claimed_source": claim_src,
        "best": None,
        "candidates": [],
        "unmatched": [],
        "skipped_unsafe": sorted(skipped),
        "missing_from_best": [],
        "receipt_agrees": None,
        "identified": False,
        "warnings": [],
    }
    if skipped:
        res["warnings"].append("%d indexed path(s) skipped, not hashed (absolute, '..', symlink or "
                               "outside the root): %s" % (len(skipped), ", ".join(sorted(skipped)[:5])))
    if not order:
        res["warnings"].append("release index lists no releases")
        return res
    if not project:
        res["warnings"].append("no file of this project sits at a path any release shipped "
                               "-- not a bundle install, or the root is wrong")
        return res

    scores = {}
    pset = set(project)
    for v in order:
        pv = per_version[v]
        m = sum(1 for p, sha in project.items() if pv.get(p) == sha)
        denom = len(set(pv) | pset)
        scores[v] = (m, denom)

    def key(v):
        m, d = scores[v]
        return (m, m / d if d else 0.0)

    ranked = sorted(order, key=lambda v: (key(v), version_key(v)), reverse=True)
    best_key = key(ranked[0])
    tied = [v for v in order if key(v) == best_key]
    m, d = scores[ranked[0]]
    res["best"] = {"range": range_label(tied, order), "versions": tied, "matches": m,
                   "denominator": d, "ratio": round(m / d, 4) if d else 0.0,
                   "project_files": len(project)}
    res["candidates"] = [{"version": v, "matches": scores[v][0], "denominator": scores[v][1],
                          "ratio": round(scores[v][0] / scores[v][1], 4) if scores[v][1] else 0.0}
                         for v in ranked[:5]]
    res["unmatched"] = sorted(p for p, sha in project.items() if sha not in by_path[p])
    ref = per_version[tied[-1]]
    res["missing_from_best"] = sorted(p for p in ref if p not in project)
    res["identified"] = True
    if claimed is not None:
        res["receipt_agrees"] = claimed in tied
        if not res["receipt_agrees"]:
            res["warnings"].append("receipt claims %s but the files match %s" % (claimed, res["best"]["range"]))
    else:
        res["warnings"].append("no receipt version to compare with (%s)" % claim_src)
    if res["best"]["ratio"] < 0.5:
        res["warnings"].append("low match ratio (%.2f): the checkout is heavily modified or mixes releases"
                               % res["best"]["ratio"])
    return res


def default_index(root: str):
    """The lib's own sibling index first (newest knowledge, also for scanning other
    projects), else the project's. -> (path | None)."""
    here = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "control", "release-index.json"))
    for cand in (here, os.path.join(root, INDEX_REL)):
        if os.path.isfile(cand):
            return cand
    return None


def render(res: dict) -> str:
    L = ["harness fingerprint: %s" % res["root"],
         "  index: %s (%s, %s releases, newest %s)" % (res["index"]["path"], res["index"]["bundle"],
                                                       res["index"]["releases"], res["index"]["newest"]),
         "  files compared: %d" % res["files_checked"]]
    b = res["best"]
    if b:
        L.append("  best match: %s  (%d/%d files, ratio %.2f)" % (b["range"], b["matches"], b["denominator"], b["ratio"]))
        L.append("  receipt claims: %s  -> %s" % (res["claimed_version"] or "(none)",
                 {True: "agrees", False: "DISAGREES", None: "not comparable"}[res["receipt_agrees"]]))
        L.append("  runners-up: " + "; ".join("%s %d/%d" % (c["version"], c["matches"], c["denominator"])
                                              for c in res["candidates"][:5]))
    else:
        L.append("  UNPROVEN: could not identify a release")
    if res["unmatched"]:
        L.append("  matching NO release (%d): %s%s" % (len(res["unmatched"]), ", ".join(res["unmatched"][:10]),
                                                     " ..." if len(res["unmatched"]) > 10 else ""))
    if res["missing_from_best"]:
        L.append("  absent although the best release ships them (%d): %s%s" % (
            len(res["missing_from_best"]), ", ".join(res["missing_from_best"][:10]),
            " ..." if len(res["missing_from_best"]) > 10 else ""))
    for w in res["warnings"]:
        L.append("  WARN: " + w)
    return "\n".join(L)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Identify which bundle release a checkout really matches (read-only).")
    ap.add_argument("root", help="project root")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--index", default="", help="release index (default: this toolkit's, else <root>/.harness/control/)")
    a = ap.parse_args(argv)
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass
    root = os.path.abspath(a.root)
    if not os.path.isdir(root):
        print("not a directory: %s" % root, file=sys.stderr)
        return 2
    index = a.index or default_index(root)
    if not index or not os.path.isfile(index):
        print("UNPROVEN: no release index found (%s)" % (index or INDEX_REL), file=sys.stderr)
        return 2
    try:
        res = fingerprint(root, index)
    except Exception as e:  # noqa: BLE001
        print("UNPROVEN: cannot read the release index: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 2
    print(json.dumps(res, indent=2) if a.json else render(res))
    if not res["identified"]:
        return 2
    return 0 if res["receipt_agrees"] in (True, None) else 1


if __name__ == "__main__":
    sys.exit(main())
