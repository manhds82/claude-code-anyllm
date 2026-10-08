#!/usr/bin/env python3
"""H1 Context Harness — local retrieval index + query (RAG-lite / semantic cache).

Builds a searchable index over the project's context sources (docs, spec/SRS,
CLAUDE.md, contracts) so a sub-agent can RETRIEVE the few relevant chunks for a
question instead of re-reading whole files — the H1 goal, one level past the
pointer store.

Honest about the method (C10):
  * Default backend = BM25 lexical retrieval — pure-python, offline, no heavy
    deps. Real ranked retrieval, not neural.
  * Pluggable neural backend — if env HARNESS_EMBED_CMD is set (a command that
    reads text on stdin and prints a JSON float vector), chunks + query are
    embedded and ranked by cosine. That is true semantic RAG when you plug a
    model; we never pretend BM25 is neural.

Usage:
  python3 harness_rag.py index  [--root DIR]
  python3 harness_rag.py query  "your question"  [--root DIR] [--k 5]

Index lives at .harness/context/index.json (gitignored like the pointer store).
Sources / chunking / top_k come from casan-policies context.retrieval (C2).
"""
from __future__ import annotations

import glob
import json
import math
import os
import re
import subprocess
import sys

TOKEN_RE = re.compile(r"[A-Za-z0-9_]{2,}")
DEFAULT_SOURCES = ["docs/**/*.md", "*.md", "contracts/**/*.yaml", "contracts/**/*.yml", "CLAUDE.md"]
DEFAULT_CHUNK_LINES = 40
DEFAULT_TOP_K = 5
MAX_CHUNKS = 3000
MAX_CHUNK_CHARS = 2000


def _load_policy(root: str) -> dict:
    p = os.path.join(root, ".harness", "control", "casan-policies.yaml")
    if os.path.isfile(p):
        try:
            import yaml  # optional; only if available

            return (yaml.safe_load(open(p, encoding="utf-8-sig")) or {})
        except Exception:
            pass
    return {}


def _retrieval_cfg(root: str) -> dict:
    ctx = (_load_policy(root).get("context") or {})
    r = ctx.get("retrieval") or {}
    return {
        "sources": r.get("sources") or DEFAULT_SOURCES,
        "chunk_lines": int(r.get("chunk_lines", DEFAULT_CHUNK_LINES)),
        "top_k": int(r.get("top_k", DEFAULT_TOP_K)),
        "embed_cmd_env": r.get("embed_cmd_env", "HARNESS_EMBED_CMD"),
    }


def _tokens(text: str) -> list[str]:
    return [t.lower() for t in TOKEN_RE.findall(text)]


def _embed(cmd: str, text: str):
    try:
        p = subprocess.run(cmd, shell=True, input=text.encode("utf-8"), capture_output=True, timeout=30)
        v = json.loads(p.stdout.decode("utf-8", "ignore"))
        return [float(x) for x in v] if isinstance(v, list) else None
    except Exception:
        return None


def _iter_files(root: str, sources: list[str]):
    seen = set()
    for pat in sources:
        for fp in glob.glob(os.path.join(root, pat), recursive=True):
            if not os.path.isfile(fp):
                continue
            if any(seg in fp.replace("\\", "/") for seg in ("/node_modules/", "/.git/", "/dist/", "/build/", "/.harness/")):
                continue
            rp = os.path.relpath(fp, root).replace("\\", "/")
            if rp not in seen:
                seen.add(rp)
                yield fp, rp


def build_index(root: str) -> dict:
    cfg = _retrieval_cfg(root)
    embed_cmd = os.environ.get(cfg["embed_cmd_env"], "")
    chunks = []
    for fp, rp in _iter_files(root, cfg["sources"]):
        try:
            lines = open(fp, encoding="utf-8-sig", errors="ignore").read().splitlines()
        except OSError:
            continue
        step = max(1, cfg["chunk_lines"])
        for i in range(0, len(lines), step):
            text = "\n".join(lines[i : i + step]).strip()
            if len(text) < 20:
                continue
            chunks.append({"path": rp, "start_line": i + 1, "text": text[:MAX_CHUNK_CHARS]})
            if len(chunks) >= MAX_CHUNKS:
                break
        if len(chunks) >= MAX_CHUNKS:
            break

    # BM25 corpus stats
    df: dict[str, int] = {}
    total_len = 0
    for c in chunks:
        toks = _tokens(c["text"])
        total_len += len(toks)
        for t in set(toks):
            df[t] = df.get(t, 0) + 1
    avgdl = (total_len / len(chunks)) if chunks else 0.0

    backend = "bm25"
    if embed_cmd:
        backend = "embed"
        for c in chunks:
            c["vec"] = _embed(embed_cmd, c["text"])

    index = {
        "built_at": os.environ.get("HARNESS_NOW", ""),
        "backend": backend,
        "n": len(chunks),
        "avgdl": avgdl,
        "df": df,
        "chunks": chunks,
    }
    out = os.path.join(root, ".harness", "context", "index.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(index, open(out, "w", encoding="utf-8"), ensure_ascii=False)
    return index


def _cosine(a, b) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def query_index(root: str, q: str, k: int | None = None) -> list[dict]:
    out = os.path.join(root, ".harness", "context", "index.json")
    if not os.path.isfile(out):
        return []
    idx = json.load(open(out, encoding="utf-8"))
    cfg = _retrieval_cfg(root)
    k = k or cfg["top_k"]
    chunks = idx["chunks"]
    scores = []

    if idx.get("backend") == "embed":
        embed_cmd = os.environ.get(cfg["embed_cmd_env"], "")
        qv = _embed(embed_cmd, q) if embed_cmd else None
        if qv:
            for c in chunks:
                scores.append((_cosine(qv, c.get("vec")), c))
    if not scores:  # BM25 (default, or embed fallback)
        n = idx["n"] or 1
        avgdl = idx["avgdl"] or 1.0
        df = idx["df"]
        qtoks = set(_tokens(q))
        k1, b = 1.5, 0.75
        for c in chunks:
            toks = _tokens(c["text"])
            dl = len(toks) or 1
            tf: dict[str, int] = {}
            for t in toks:
                tf[t] = tf.get(t, 0) + 1
            s = 0.0
            for t in qtoks:
                if t not in tf:
                    continue
                idf = math.log(1 + (n - df.get(t, 0) + 0.5) / (df.get(t, 0) + 0.5))
                s += idf * (tf[t] * (k1 + 1)) / (tf[t] + k1 * (1 - b + b * dl / avgdl))
            if s > 0:
                scores.append((s, c))

    scores.sort(key=lambda x: x[0], reverse=True)
    return [
        {"path": c["path"], "start_line": c["start_line"], "score": round(sc, 3),
         "snippet": c["text"][:240].replace("\n", " ")}
        for sc, c in scores[:k]
    ]


def main(argv: list[str]) -> int:
    # Snippets carry arbitrary text (Vietnamese, em-dashes); never crash on a
    # legacy console codepage (e.g. Windows cp932). Force UTF-8, replace on fail.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if len(argv) < 2:
        print("usage: harness_rag.py [index|query] ...", file=sys.stderr)
        return 2
    action = argv[1]
    root = os.environ.get("HARNESS_ROOT", "")
    q = ""
    k = None
    rest = argv[2:]
    i = 0
    while i < len(rest):
        if rest[i] == "--root":
            root = rest[i + 1]; i += 2
        elif rest[i] == "--k":
            k = int(rest[i + 1]); i += 2
        else:
            q = rest[i]; i += 1
    if not root:
        root = os.getcwd()

    if action == "index":
        idx = build_index(root)
        print(f"[rag] indexed {idx['n']} chunks (backend={idx['backend']}) -> .harness/context/index.json")
        return 0
    if action == "query":
        if not q:
            print("usage: harness_rag.py query \"question\" [--k N]", file=sys.stderr)
            return 2
        hits = query_index(root, q, k)
        if not hits:
            print("[rag] no index yet (run: harness_rag.py index) or no match")
            return 0
        for h in hits:
            print(f"{h['path']}:{h['start_line']}  (score {h['score']})\n    {h['snippet']}")
        return 0
    print(f"[rag] unknown action: {action}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
