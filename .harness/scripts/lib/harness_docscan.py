#!/usr/bin/env python3
"""H1 source<->doc traceability scanner (client-side).

The Portal's server-side scanner (portal core/docscan.py) needs the repo on
disk at harness_root_ref. Push-based projects have no server checkout, so the
dev machine runs THIS scanner over its own working tree and pushes the result.

Honesty (C10): we only emit a (source, doc) pair when BOTH paths actually exist
and we compare their real newest-file mtimes. We never fabricate a "missing"
row just to light up a metric — a pair we can't substantiate is simply not
emitted. The mapping table is, in order of preference:
  1. .harness/source-doc-map.yaml  — a DECLARED list of {source, doc} (best).
  2. Auto-detected pairs           — a small, conservative set: the project's
     primary source dir vs its top-level docs (README / docs/). This is a real
     staleness question ("is the doc older than the code?"), not a guess about
     which file documents which function.

Usage:  python harness_docscan.py <repo_root>
Output: JSON list to stdout: [{"source": "...", "doc": "...", "status": "..."}]
        status in {in_sync, stale}.  Exit 0 always (best-effort; empty list ok).
"""
import json
import os
import sys

# Dirs never worth walking for mtime (noise + huge).
_PRUNE = {".git", ".harness", "node_modules", "dist", "build", ".next", "out",
          "__pycache__", ".venv", "venv", "env", ".idea", ".vscode", "coverage",
          "target", ".mypy_cache", ".pytest_cache", "vendor", ".turbo"}
# Candidate primary source locations, most-specific first.
_SRC_CANDIDATES = ["src", "app", "lib", "backend", "server", "portal", "gateway", "contracts"]
# Candidate top-level docs.
_DOC_CANDIDATES = ["docs", "README.md", "README.rst", "README.txt", "README"]


def _newest_mtime(path):
    """Newest file mtime under path (file → its own mtime). None if absent."""
    if not os.path.exists(path):
        return None
    if os.path.isfile(path):
        try:
            return os.path.getmtime(path)
        except OSError:
            return None
    newest = None
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if d not in _PRUNE and not d.startswith(".")]
        for f in files:
            try:
                m = os.path.getmtime(os.path.join(root, f))
            except OSError:
                continue
            if newest is None or m > newest:
                newest = m
    return newest


def _status(root, source_rel, doc_rel):
    s = _newest_mtime(os.path.join(root, source_rel))
    d = _newest_mtime(os.path.join(root, doc_rel))
    if s is None or d is None:
        return None  # one side missing → do not emit (honest)
    return "stale" if s > d else "in_sync"


def _load_declared(root):
    """Parse .harness/source-doc-map.yaml WITHOUT a yaml dependency: accept a
    minimal `- source: X` / `  doc: Y` list. Returns [(source, doc), ...]."""
    p = os.path.join(root, ".harness", "source-doc-map.yaml")
    if not os.path.isfile(p):
        return []
    pairs, cur = [], {}
    try:
        for line in open(p, encoding="utf-8-sig"):
            line = line.rstrip()
            t = line.strip()
            if t.startswith("#") or not t:
                continue
            if t.startswith("- "):
                if cur.get("source") and cur.get("doc"):
                    pairs.append((cur["source"], cur["doc"]))
                cur = {}
                t = t[2:].strip()
            if ":" in t:
                k, _, v = t.partition(":")
                k, v = k.strip(), v.strip().strip('"').strip("'")
                if k in ("source", "doc") and v:
                    cur[k] = v
        if cur.get("source") and cur.get("doc"):
            pairs.append((cur["source"], cur["doc"]))
    except OSError:
        return []
    return pairs


def _auto_pairs(root):
    """Conservative auto-detected pairs: each existing primary source dir vs
    each existing top-level doc. Only real, on-disk pairs."""
    sources = [c for c in _SRC_CANDIDATES if os.path.isdir(os.path.join(root, c))]
    docs = [c for c in _DOC_CANDIDATES if os.path.exists(os.path.join(root, c))]
    if not sources:
        # no conventional source dir → treat repo root code vs docs
        sources = ["."]
    pairs = []
    for d in docs:
        # pair the doc with at most the two most-specific source dirs, to keep
        # the signal focused rather than emitting a combinatorial explosion.
        for s in sources[:2]:
            pairs.append((s, d))
    return pairs


def scan(root):
    seen, out = set(), []
    pairs = _load_declared(root) or _auto_pairs(root)
    for source_rel, doc_rel in pairs:
        key = (source_rel, doc_rel)
        if key in seen:
            continue
        seen.add(key)
        st = _status(root, source_rel, doc_rel)
        if st is None:
            continue
        out.append({"source": source_rel, "doc": doc_rel, "status": st})
    return out


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    try:
        print(json.dumps(scan(root), separators=(",", ":")))
    except Exception:
        print("[]")
