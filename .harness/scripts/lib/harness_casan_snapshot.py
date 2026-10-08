#!/usr/bin/env python3
"""CASAN evidence snapshot (client-side).

The Portal scores a project by reading its repo at harness_root_ref. A
push-based project has no server checkout — harness_root_ref is empty — so
every machine-checked criterion reads not-met and the whole evidence axis sits
at 0. Same gap harness_docscan.py closes for H1, same answer: the dev machine
is the only box that can see the files, so the dev machine ships them.

We ship FILES, never verdicts. Evaluation stays server-side, so a project can
never inflate its own score by editing what it pushes — the worst it can do is
withhold evidence, and withheld evidence costs it points.

Two sets, deliberately different in cost:
  files    — content of the handful of configs the checks actually parse.
  manifest — path + size + line count for the trees the checks only probe with
             exists(); no content, so a 200-file scripts/ tree costs ~10 KB,
             and a size-0 stub is still visibly a stub rather than a pass.

What is denied, and why the harness's own controls are not (C5): the deny list
is anchored on file shapes that ARE the credential — private keys and keystores
(*.key, *.pem, *.pfx, *.p12, *.jks), env files, bearer-token files, and the
conventional secrets.* stores. .harness/portal-sync.key is the live example: it
sits one directory above the configs we collect, so the globs are applied to
both sets, against basename AND full path, before any read.

The deny list deliberately does NOT match the bare words "key", "secret" or
"token" anywhere in a name. Those words are all over a governance harness
without a credential in sight: .harness/control/secret-patterns.json is a list
of REGEXES that find secrets, .harness/scripts/*/secret-scan.* is the SCANNER
that applies them, and .harness/eval/golden/secret-scan/*.yaml are its test
cases. Withholding those told the Portal that H4-2 — "is secret scanning
wired?" — was NOT MET on every push-based project, i.e. the privacy rule was
reporting the privacy control as missing. A pattern is not a password.

Usage:  python harness_casan_snapshot.py <repo_root>
Output: ONE JSON object on stdout, nothing else:
  {"files":    {"<relpath>": "<content>", ...},
   "manifest": [{"path": "<relpath>", "size": <bytes>, "lines": <n>}, ...],
   "skipped":  [{"path": "<relpath>", "reason": "<why>",
                 "withheld": <bool>, ...}, ...]}

"skipped" is the third state, and it is why the server can tell WITHHELD from
ABSENT instead of scoring both as not-met. Two fields, and they answer two
different questions — do not collapse them:

  withheld  — is the path in NEITHER files nor manifest? Computed from the
              finished payload, not asserted per branch, so it cannot drift
              from what we actually sent. withheld=true means the server knows
              nothing about this path: any check that probes it is UNMEASURED,
              never not-met. Today only secret_shaped and unreadable get here.
  reason    — why. A path can be listed with withheld=false, meaning we sent
              something about it but not everything:
                too_large / budget_exhausted — manifest entry stands, so
                  exists() is answerable, but the CONTENT is missing. A check
                  that PARSES this path is unmeasured too; a check that only
                  probes exists() stays measured. The server can tell the two
                  apart by looking for the path in casan_files.
                tail_only — the ledger window; content present, truncated.
                linecount_skipped — manifest entry present, "lines" is 0 as a
                  floor rather than a count.

Exit 0 always (best-effort; an empty snapshot is a valid, honest answer).
"""
import fnmatch
import glob
import json
import os
import sys

# Content set — what the server-side checks actually open and parse. Kept tiny
# on purpose: this is the expensive half of the payload.
_CONTENT_GLOBS = [
    ".harness/control/*.json",
    ".harness/control/*.yaml",
    ".harness/context/pipeline-context.yaml",
    ".claude/settings.json",
    "contracts/*.yaml",
]

# The ledger grows without bound; the chain check only verifies a window of
# recent entries, so shipping the whole file would cost megabytes for nothing.
_LEDGER_CHAIN = ".harness/ledger/chain.jsonl"
_LEDGER_TAIL_LINES = 500

# Manifest set — trees the checks only ask exists() about (a script, a golden
# dataset, an agent definition). Path + size + lines answers that question
# without shipping a byte of content.
#
# control/ and context/ overlap the content globs on purpose. A config that the
# content pass drops (too_large, budget_exhausted) still needs to answer
# exists(), and .harness/context/index.json can ONLY be answered here: it is the
# retrieval index H1-4 probes, it is ~570 KB in this repo — past _MAX_FILE_BYTES
# and two orders of magnitude bigger than every config combined — and the check
# never opens it. Manifest-only is the whole point of the manifest: pay 100
# bytes to answer a yes/no instead of 570 KB.
_MANIFEST_ROOTS = [
    ".harness/control",
    ".harness/context",
    ".harness/scripts",
    ".harness/eval",
    ".harness/ledger",
    ".claude",
    "contracts",
]

# Build output and caches are not evidence of anything; walking them just
# inflates the manifest.
_PRUNE_DIRS = {".git", "__pycache__", "node_modules", ".venv", "venv", "env",
               ".mypy_cache", ".pytest_cache", ".tox", "dist", "build",
               ".next", "coverage", ".turbo"}

# C5 — never ship a secret. Matched against both the basename and the full
# relative path, lowercased, before the file is opened. A file denied here is
# recorded in "skipped" with withheld=true, so the server reports the criteria
# that needed it as UNMEASURED rather than as failed.
#
# Every glob below names a shape that IS a credential, not a shape that merely
# talks about credentials — see the module docstring for what that distinction
# cost us. Substring globs are kept to words that have no innocent use in a
# filename (credential/password/passwd); everything else is anchored on an
# extension or a whole basename.
_DENY_GLOBS = [
    # Private keys and keystores — the file itself is the secret.
    "*.key", "*.pem", "*.pfx", "*.p12", "*.jks", "*.keystore",
    "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*",
    # Bearer material written to disk.
    "*.token", "*_token",
    # Words with no innocent filename use.
    "*credential*", "*password*", "*passwd*",
    # Env files — where DSNs and API keys actually live.
    ".env", ".env.*", "*.env",
    # The conventional secret stores, by whole basename. NOT "*secret*": that
    # matched secret-patterns.json, secret-scan.ps1/.sh and the secret-scan
    # golden cases, none of which contain a credential.
    "secrets.json", "secrets.yaml", "secrets.yml", "secrets.env", "*.secrets",
]

# Per-file cap for content. Every file in the content set is a few KB in
# practice; anything two orders of magnitude past that is not the config we
# meant to collect, so skip it whole and say so rather than ship half a YAML
# the server would then mis-parse.
_MAX_FILE_BYTES = 256 * 1024
# Whole-payload cap. The ingest endpoint rejects oversized fields outright, and
# a 413 kills the entire telemetry push, not just the snapshot.
_MAX_TOTAL_BYTES = 4 * 1024 * 1024
# Past this, counting lines means reading the file; report 0 and record the
# skip. 0 is the fail-safe direction — it can only cost the project points.
_MAX_LINECOUNT_BYTES = 64 * 1024 * 1024


def _rel(root, full):
    return os.path.relpath(full, root).replace(os.sep, "/")


def _denied(relpath):
    """True if the path is secret-shaped. Deny beats every other rule."""
    low = relpath.lower()
    base = low.rsplit("/", 1)[-1]
    return any(fnmatch.fnmatch(base, g) or fnmatch.fnmatch(low, g)
               for g in _DENY_GLOBS)


def _count_lines(path, size):
    """Line count without decoding. Returns (lines, counted)."""
    if size > _MAX_LINECOUNT_BYTES:
        return 0, False
    n = 0
    tail = b""
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                n += chunk.count(b"\n")
                tail = chunk[-1:]
    except OSError:
        return 0, False
    if size and tail != b"\n":
        n += 1  # a last line with no trailing newline is still a line
    return n, True


def _read_text(path):
    """Read with the same decoding the server uses (casan_criteria._read), so
    what we send is what it will parse. None on any read error."""
    try:
        with open(path, encoding="utf-8-sig", errors="ignore") as f:
            text = f.read()
    except OSError:
        return None
    # Postgres text columns reject U+0000; one stray NUL in a config would fail
    # the snapshot insert server-side, long after we could report it.
    return text.replace("\x00", "")


def _tail_lines(path, n):
    """Last n lines, read from the end so chain size never drives cost."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    window = 256 * 1024
    while True:
        offset = max(0, size - window)
        try:
            with open(path, "rb") as f:
                f.seek(offset)
                blob = f.read()
        except OSError:
            return None
        # Same NUL strip _read_text does, for the same reason: this string ends
        # up in the same Postgres text column, and a single U+0000 anywhere in
        # the 500-line window fails the whole snapshot insert server-side —
        # long after we could report it. The tail was missing this.
        lines = blob.decode("utf-8", errors="ignore").replace("\x00", "").splitlines()
        if offset > 0:
            lines = lines[1:]  # the window almost certainly split a line
        if len(lines) >= n or offset == 0 or window >= 8 * 1024 * 1024:
            lines = lines[-n:]
            return ("\n".join(lines) + "\n") if lines else ""
        window *= 4


def _content_paths(root):
    seen, out = set(), []
    for pat in _CONTENT_GLOBS:
        for full in sorted(glob.glob(os.path.join(root, pat.replace("/", os.sep)))):
            if os.path.isfile(full) and full not in seen:
                seen.add(full)
                out.append(full)
    return out


def snapshot(root):
    files, manifest = {}, []
    skipped, seen_skip = [], set()
    total = 0

    def skip(rel, reason, **extra):
        """Record one skip. "withheld" is NOT set here — it is derived from the
        finished payload below, so it can never claim we held a path back that
        another pass in fact sent. Deduped on (path, reason) because control/
        and context/ are walked by both passes and a denied file there would
        otherwise be reported twice."""
        k = (rel, reason)
        if k in seen_skip:
            return
        seen_skip.add(k)
        e = {"path": rel, "reason": reason}
        e.update(extra)
        skipped.append(e)

    # Configs first, ledger tail last: if the payload budget runs out, the
    # small parseable configs are worth more than the chain window.
    for full in _content_paths(root):
        rel = _rel(root, full)
        if _denied(rel):
            skip(rel, "secret_shaped")
            continue
        try:
            size = os.path.getsize(full)
        except OSError:
            skip(rel, "unreadable")
            continue
        if size > _MAX_FILE_BYTES:
            skip(rel, "too_large", size=size, limit=_MAX_FILE_BYTES)
            continue
        if total + size > _MAX_TOTAL_BYTES:
            skip(rel, "budget_exhausted", size=size, limit=_MAX_TOTAL_BYTES)
            continue
        text = _read_text(full)
        if text is None:
            skip(rel, "unreadable")
            continue
        files[rel] = text
        total += len(text.encode("utf-8", errors="ignore"))

    chain = os.path.join(root, _LEDGER_CHAIN.replace("/", os.sep))
    if os.path.isfile(chain) and not _denied(_LEDGER_CHAIN):
        tail = _tail_lines(chain, _LEDGER_TAIL_LINES)
        if tail is None:
            skip(_LEDGER_CHAIN, "unreadable")
        else:
            kept = tail.count("\n")
            tail_bytes = len(tail.encode("utf-8", errors="ignore"))
            if total + tail_bytes > _MAX_TOTAL_BYTES:
                skip(_LEDGER_CHAIN, "budget_exhausted",
                     size=tail_bytes, limit=_MAX_TOTAL_BYTES)
            else:
                files[_LEDGER_CHAIN] = tail
                total += tail_bytes
                # Always recorded, even when the whole chain fit: the manifest
                # carries the true line count, so a reader comparing the two
                # must be able to see this is a window, not the chain.
                skip(_LEDGER_CHAIN, "tail_only", lines_kept=kept)

    for rel_root in _MANIFEST_ROOTS:
        base = os.path.join(root, rel_root.replace("/", os.sep))
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in _PRUNE_DIRS)
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                rel = _rel(root, full)
                if _denied(rel):
                    skip(rel, "secret_shaped")
                    continue
                try:
                    size = os.path.getsize(full)
                except OSError:
                    skip(rel, "unreadable")
                    continue
                lines, counted = _count_lines(full, size)
                if not counted:
                    # The manifest entry still lands, so exists() is answered;
                    # only "lines" is a floor of 0.
                    skip(rel, "linecount_skipped", size=size)
                manifest.append({"path": rel, "size": size, "lines": lines})

    # The manifest passes may re-list a path the content pass already took;
    # dedupe on path so the server's {path: entry} map has one truth per file.
    dedup = {}
    for e in manifest:
        dedup.setdefault(e["path"], e)
    manifest = sorted(dedup.values(), key=lambda e: e["path"])

    # Derive "withheld" from what we ACTUALLY sent. Asserting it at each skip
    # site would be a guess: the content pass and the manifest passes overlap on
    # control/ and context/, so a path dropped by one is often still carried by
    # the other. A wrong true here is the exact lie this field exists to stop —
    # it would tell the server "we held this back" about a file it can see.
    for e in skipped:
        e["withheld"] = e["path"] not in files and e["path"] not in dedup
    skipped.sort(key=lambda e: (e["path"], e["reason"]))
    return {"files": files, "manifest": manifest, "skipped": skipped}


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    try:
        out = snapshot(root)
    except Exception:
        out = {"files": {}, "manifest": [], "skipped": []}
    # ensure_ascii stays on (the default): this JSON crosses a PowerShell pipe
    # on a cp932/cp437 console, where any non-ASCII byte — and casan-policies
    # .yaml is full of Vietnamese — comes back mangled or raises on write.
    sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
