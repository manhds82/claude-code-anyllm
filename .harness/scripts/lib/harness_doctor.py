#!/usr/bin/env python3
"""harness doctor — local self-check for a project's evidence pipeline.

Answers, without querying the Portal DB, the question four consuming projects had
no way to answer except by watching their score fall: *why is my evidence not
being recorded?* Prints an OK / WARN / FAIL line per check and a one-line verdict.

Read-only. Exit code is always 0 by default (it is a diagnostic, not a gate);
pass --strict to exit 1 when any FAIL is present, for use in CI.

--ci (B-78): on a fresh CI runner the ledger chain, the telemetry and the H1
pointer store do not exist BY DESIGN -- machine-state-paths.yaml declares them
machine-local, never committed -- so the checks that read them FAILed on every
run and the template's `--strict` made harness-gate red forever. With --ci, a
check whose evidence lives only under a machine_local path from that YAML is
reported as INFO "not checkable on a CI runner" (unproven, never OK -- C12);
everything else, bundle integrity included, is graded exactly as on a
workstation. The skip list is read from the YAML (C2); without it nothing is
skipped. Explicit flag only: GITHUB_ACTIONS is not read to switch it on, since
the toolkit's own CI runs doctor tests that expect the workstation grading.

Shared core so the PowerShell and bash wrappers emit identical output (C7): the
two harness-doctor.* scripts are thin shells that call this.
"""
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OK, WARN, FAIL, INFO = "OK", "WARN", "FAIL", "INFO"


def _age(path):
    """Human age of a file's mtime, or None if absent."""
    try:
        dt = time.time() - os.path.getmtime(path)
    except OSError:
        return None
    if dt < 90:
        return "%ds" % int(dt)
    if dt < 5400:
        return "%dm" % int(dt / 60)
    if dt < 129600:
        return "%dh" % int(dt / 3600)
    return "%dd" % int(dt / 86400)


def _last_line(path):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            back = min(size, 4096)
            f.seek(size - back)
            tail = f.read().decode("utf-8", "replace").strip().splitlines()
            return tail[-1] if tail else ""
    except OSError:
        return ""


def _read(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return f.read()
    except OSError:
        return ""


def _git(root, *args):
    """Run a git command, returning stdout or "" — never raising."""
    try:
        out = subprocess.run(("git", "-C", root) + args, capture_output=True,
                             text=True, timeout=20)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def _ci_last_run(root):
    """-> (state, detail). state ∈ pass | fail | none | unknown.

    Asks `gh` for the most recent workflow run. Four outcomes, kept apart
    because three of them get confused constantly:

      pass     a run completed successfully — the gate is proven to work
      fail     runs happen and the latest FAILED — proven, and bad
      none     gh reached the repo and there are no runs — never fired
      unknown  gh is missing, logged out, or pointed at an account that cannot
               see this repo

    `none` and `unknown` are the pair that matters. A wrong active account
    answers "nothing found" in the same words a genuinely idle repo does, and
    reading that as "no CI configured" is how a red or absent gate passes for a
    quiet one. This happened during development: the gh account flipped and
    every query came back 404 while the repo was fine.

    Never raises and never blocks: a 6-second cap, and any failure degrades to
    `unknown` with the reason attached (C13 — carry where the value came from).
    """
    gh = shutil.which("gh")
    if not gh:
        return "unknown", "gh is not installed"
    try:
        p = subprocess.run(
            [gh, "run", "list", "--limit", "1",
             "--json", "conclusion,status,name,createdAt,headBranch"],
            cwd=root, capture_output=True, text=True, timeout=6,
        )
    except Exception as e:
        return "unknown", "gh call failed (%s)" % e
    if p.returncode != 0:
        err = (p.stderr or "").strip().splitlines()
        msg = err[-1] if err else "exit %d" % p.returncode
        # Name the most common cause rather than echoing a bare 404: the fix is
        # `gh auth switch`, and a reader who is not told that goes looking at CI.
        if "404" in msg or "Could not resolve" in msg or "not found" in msg.lower():
            msg += " — often the wrong `gh` account is active for this repo (gh auth status)"
        return "unknown", msg
    try:
        runs = json.loads(p.stdout or "[]")
    except ValueError:
        return "unknown", "gh returned output that is not JSON"
    if not runs:
        return "none", "no workflow runs"
    r = runs[0]
    when = (r.get("createdAt") or "")[:16]
    who = "%s on %s" % (r.get("name") or "?", r.get("headBranch") or "?")
    if r.get("status") != "completed":
        return "unknown", "latest run (%s, %s) is still %s" % (who, when, r.get("status"))
    if r.get("conclusion") == "success":
        return "pass", "latest run %s succeeded (%s)" % (who, when)
    return "fail", "latest run %s concluded '%s' (%s)" % (who, r.get("conclusion"), when)


def _default_branch(root):
    """(branch, source) -- the repo's default branch and HOW it was established.

    Returns ("", "none") when it cannot be established honestly.

    Mirrors install.ps1's Get-DefaultBranch, and for the same reason:
    refs/remotes/*/HEAD is a LOCAL CACHE written at clone time and can be stale
    (one repo's pointed at a feature branch while its real default was main).
    Ask the server first; reject any namespaced name as a feature branch; and
    return "" rather than guess -- a wrong default here would report a healthy
    gate as dead, and that false alarm costs more than the missing check.

    C13 is why the SOURCE comes back with the value. An inferred value that
    travels without its provenance cannot be second-guessed downstream: the
    caller sees `main` and has no way to know whether the server said so or
    whether a three-year-old local cache did. The four sources below are ordered
    by trustworthiness, and callers are expected to treat the cached and guessed
    ones as weaker evidence rather than as facts.
    """
    def plausible(b):
        return b and "/" not in b and b != "HEAD"

    remotes = [r for r in _git(root, "remote").splitlines() if r.strip()]

    # 1. The server itself. The only source that cannot be stale.
    for r in remotes:
        m = re.search(r"ref:\s+refs/heads/(\S+)\s+HEAD",
                      _git(root, "ls-remote", "--symref", r, "HEAD"))
        if m and plausible(m.group(1)):
            return m.group(1), "remote"

    # 2. The local cache of (1), written at clone time and never refreshed.
    for r in remotes:
        ref = _git(root, "symbolic-ref", "--quiet", "refs/remotes/%s/HEAD" % r)
        b = ref.replace("refs/remotes/%s/" % r, "")
        if plausible(b):
            return b, "cache"

    # 3. A conventional name that merely EXISTS on a remote. Weak: a repo can
    #    have both main and master with the wrong one first in this list.
    for cand in ("main", "master", "develop", "trunk"):
        for r in remotes:
            if _git(root, "rev-parse", "--verify", "--quiet",
                    "refs/remotes/%s/%s" % (r, cand)):
                return cand, "convention"

    # 4. Whatever this working copy happens to be sitting on. This is not
    #    evidence of anything -- it is the state of one developer's checkout --
    #    and it is exactly the source that produced a dead gate once already.
    b = _git(root, "rev-parse", "--abbrev-ref", "HEAD")
    if plausible(b):
        return b, "checkout"
    return "", "none"


def _ledger_links(chain):
    """Walk chain.jsonl and check each entry's prev_hash against the entry above.

    Streams the file: this repo's chain is tens of MB, with pre-b730629 lines of
    ~2 MB each. Returns one (status, "ledger", detail) tuple.
    """
    n = 0
    first = None
    above = None           # entry_hash of the line directly above
    seen = set()
    breaks = {"fork": 0, "missing parent": 0, "genesis mid-file": 0, "unreadable link": 0}
    first_bad = None
    with open(chain, encoding="utf-8-sig") as f:
        for raw in f:
            if not raw.strip():
                continue
            n += 1
            try:
                e = json.loads(raw)
                h, p = e.get("entry_hash"), e.get("prev_hash")
            except ValueError:
                e, h, p = {}, None, None
            # Pre-b730629 entries can carry a list (or other non-string) here --
            # SynthGora's chain does. Such a link is unreadable, not a crash: a
            # TypeError here surfaced as "chain.jsonl unreadable", hiding the counts.
            if not isinstance(h, str):
                h = None
            if not isinstance(p, str):
                p = None if p is None else ""
            if n == 1:
                first = e
            elif p != above or p is None:
                if p == "GENESIS":
                    kind = "genesis mid-file"
                elif p in (None, "", "UNREADABLE"):
                    kind = "unreadable link"
                elif p in seen:
                    kind = "fork"          # links to an older entry: concurrent append
                else:
                    kind = "missing parent"
                breaks[kind] += 1
                if first_bad is None:
                    first_bad = n
            if h:
                seen.add(h)
            above = h

    if n == 0:
        return FAIL, "ledger", "chain.jsonl is empty — no genesis."
    bad = sum(breaks.values())
    if bad:
        parts = ", ".join("%d %s(s)" % (c, k) for k, c in breaks.items() if c)
        return (FAIL, "ledger",
                "%d entries, %d broken link(s): %s (first at line %d). The chain cannot "
                "prove it is unaltered while these stand. Forks come from appends that "
                "raced each other; once appends are locked, close this segment with "
                "`evidence-ledger seal` -- never edit the file." % (n, bad, parts, first_bad))
    if (first or {}).get("prev_hash") != "GENESIS":
        return WARN, "ledger", "%d entries but first is not GENESIS — chain cannot prove it is intact from the start." % n
    if n <= 1:
        return WARN, "ledger", "genesis only (1 entry) — no side-effect has been recorded yet."
    seg = first.get("prev_segment")
    return (OK, "ledger", "%d entries, every link intact from genesis%s, last write %s ago."
            % (n, " (segment continues from %s)" % seg if seg else "", _age(chain)))


def _c15_handoff(root):
    """C15: is the project's Handoff.md kept current? WARN at worst, never FAIL.

    Settings come from casan-policies.yaml `handoff:` with the hook's defaults
    when the section is absent (only `enabled: false` turns it off). C12/C14:
    when git history cannot be read the answer is `unknown`, never OK.
    """
    label = "handoff (C15)"
    try:
        import harness_handoff as HH
    except Exception as e:
        yield INFO, label, "unknown: cannot load harness_handoff (%s)" % e
        return
    cfg = HH.effective_config(root)
    if cfg.get("enabled") is False:
        yield INFO, label, "disabled in casan-policies.yaml (handoff.enabled: false)."
        return
    rel = str(cfg.get("path") or "Handoff.md").replace("\\", "/")
    try:
        max_age = int(cfg.get("max_age_days") or 14)
    except (TypeError, ValueError):
        max_age = 14
    if not os.path.isfile(os.path.join(root, rel.replace("/", os.sep))):
        yield WARN, label, ("%s is missing -- the next assistant starts with no NOW/NEXT/OPEN/AVOID. "
                            "Create it (C15)." % rel)
        return
    head = _git(root, "log", "-1", "--format=%ct")
    last = _git(root, "log", "-1", "--format=%ct", "--", rel)
    if not head.isdigit():
        yield INFO, label, "unknown: git history unreadable (no HEAD commit) -- freshness of %s not checked." % rel
        return
    if not last.isdigit():
        yield WARN, label, "%s exists but has never been committed -- its freshness cannot be shown." % rel
        return
    lag = (int(head) - int(last)) / 86400.0
    if lag > max_age:
        yield WARN, label, ("%s last committed %.0f day(s) before HEAD (limit %d) -- the work since is "
                            "not handed off (C15)." % (rel, lag, max_age))
    else:
        yield OK, label, "%s committed within %d day(s) of HEAD (%.0f)." % (rel, max_age, lag)


def _machine_local_matcher(root):
    """-> (callable(rel) -> bool, None) from machine-state-paths.yaml, or (None, why)."""
    try:
        import harness_local_state as hls
    except Exception as e:  # noqa: BLE001
        return None, "harness_local_state.py unavailable (%s)" % type(e).__name__
    spec, err = hls.load_spec(root)
    if not spec:
        return None, "%s %s" % (hls.SPEC_REL, err or "empty")
    pats = [hls._glob_to_re(e["path"]) for e in (spec.get("machine_local") or [])
            if isinstance(e, dict) and e.get("path")]
    if not pats:
        return None, "%s lists no machine_local path" % hls.SPEC_REL
    return (lambda rel: any(p.match(rel) for p in pats)), None


def _ci_preamble(root):
    """-> (local_only(rel) -> bool, [lines to yield]) for --ci mode."""
    match, why = _machine_local_matcher(root)
    lines = []
    if match is None:
        # C13: no authoritative list -> skip nothing rather than guess one.
        lines.append((WARN, "ci mode", (
            "--ci asked, but the machine-local path list could not be read (%s), so NOTHING is "
            "skipped: the workstation-only checks below are graded as on a workstation." % why)))
        return (lambda rel: False), lines
    env = [k for k in ("GITHUB_ACTIONS", "CI") if (os.environ.get(k) or "").lower() == "true"]
    if env:
        lines.append((INFO, "ci mode", (
            "--ci on a CI runner (%s=true): checks whose evidence lives only under a machine_local "
            "path of .harness/control/machine-state-paths.yaml are reported as not checkable here; "
            "bundle integrity and every repo-level check are graded as usual." % env[0])))
    else:
        # Not a refusal -- a local dry run of the CI job is legitimate -- but a
        # workstation that passes --ci hides its own ledger/context, so say so.
        lines.append((WARN, "ci mode", (
            "--ci given but neither GITHUB_ACTIONS nor CI is 'true': this looks like a workstation, "
            "and --ci has just skipped its ledger, telemetry and context checks. Run without --ci "
            "here.")))
    return match, lines


def _not_here(label, rel):
    return INFO, label, (
        "not checkable on a CI runner: %s is machine-local (machine-state-paths.yaml), never "
        "committed, so a fresh checkout cannot hold it. Unproven here, not passing -- run "
        "harness doctor on a workstation for this line." % rel)


def run(root, ci=False):
    """Yield (status, label, detail) tuples."""
    H = os.path.join(root, ".harness")
    tel = os.path.join(H, "telemetry")
    local_only = lambda rel: False  # noqa: E731
    if ci:
        local_only, lines = _ci_preamble(root)
        for line in lines:
            yield line

    # 1) Ledger — genesis present, and every entry links to the one above it?
    #
    # This used to stop at "first line is GENESIS and the file has lines", and
    # printed OK over a chain in which 974 of 8,953 entries linked to an OLDER
    # entry than their predecessor (concurrent appends, measured 2026-09-29). A
    # tamper-evident log whose health check cannot see a broken link is the C14
    # defect itself: one real rewrite hides among hundreds of harmless forks, and
    # the green line says there is nothing to look for. Links only, not content
    # hashes -- PowerShell and bash serialise entries differently, so recomputing
    # a hash here would disagree with one writer or the other; `evidence-ledger
    # verify` does that per shell.
    chain = os.path.join(H, "ledger", "chain.jsonl")
    if local_only(".harness/ledger/chain.jsonl"):
        yield _not_here("ledger", ".harness/ledger/chain.jsonl")
    elif not os.path.exists(chain):
        yield FAIL, "ledger", "chain.jsonl missing — no genesis. Run a session (session-start writes it) or `evidence-ledger init`."
    else:
        try:
            yield _ledger_links(chain)
        except Exception as e:
            yield FAIL, "ledger", "chain.jsonl unreadable: %s" % e

    # 1b) Appends that never made it into the chain (U1).
    #
    # This is a FAIL of its own, not a line in the general "hook errors" WARN,
    # and the distinction is the whole point. Every other hook error means a
    # diagnostic misfired. This one means a SIDE-EFFECT HAPPENED AND NOTHING
    # RECORDED IT — C9's one-line-per-side-effect guarantee was broken for that
    # action. The chain stays internally consistent afterwards, because the next
    # entry links to the last one that succeeded, so `verify` is green and the
    # gap leaves no hole to find. This file is the only place the loss is
    # visible; grading it WARN would put the one unrecoverable failure in the
    # same bucket as a noisy log line.
    fails = os.path.join(H, "ledger", "append-failures.jsonl")
    if os.path.exists(fails):
        try:
            rows = [json.loads(l) for l in open(fails, encoding="utf-8-sig") if l.strip()]
        except Exception as e:
            rows = []
            yield FAIL, "ledger append", "append-failures.jsonl exists but cannot be read (%s) — treat as lost appends until proven otherwise." % e
        if rows:
            last = rows[-1]
            stages = {}
            for r in rows:
                s = r.get("stage") or "?"
                stages[s] = stages.get(s, 0) + 1
            where = ", ".join("%s×%d" % (k, v) for k, v in sorted(stages.items(), key=lambda kv: -kv[1]))
            yield FAIL, "ledger append", (
                "%d side-effect(s) happened with NO ledger entry (%s). Most recent: tool=%s :: %s. "
                "The chain still verifies — a missing entry leaves no hole — so this file is the only "
                "record that they are gone. Investigate the cause, then move the file aside once "
                "handled; deleting it to clear the FAIL discards the only evidence of the gap."
                % (len(rows), where, last.get("tool") or "?", (last.get("reason") or "")[:120])
            )
    # Absent file = nothing lost. Deliberately silent: a line saying "no lost
    # appends" on every healthy run is noise, and this check must stay something
    # people react to.

    # The last-resort path, used when even append-failures.jsonl could not be
    # written. Kept separate because it means BOTH the record and its fallback
    # failed, which points at the disk or permissions rather than at memory.
    _hook_err = os.path.join(tel, "hook-errors.log")
    if os.path.exists(_hook_err):
        try:
            lost = [l for l in open(_hook_err, encoding="utf-8-sig", errors="replace")
                    if "LEDGER-APPEND-LOST" in l]
        except Exception:
            lost = []
        if lost:
            yield FAIL, "ledger append (fallback)", (
                "%d append(s) failed AND could not be recorded in append-failures.jsonl — see "
                "LEDGER-APPEND-LOST in hook-errors.log. Both the record and its fallback failed, "
                "which usually means the disk or the permissions, not memory." % len(lost)
            )

    # 2) Telemetry files — present and fresh?
    for name, label in [("tool-calls.log", "audit (tool-calls)"),
                        ("agentops.log", "token/cost (agentops)"),
                        ("test-reports.jsonl", "test reports")]:
        p = os.path.join(tel, name)
        a = _age(p)
        if local_only(".harness/telemetry/" + name):
            yield _not_here(label, ".harness/telemetry/" + name)
        elif a is None:
            yield WARN, label, "%s absent — no evidence of this kind has been produced." % name
        else:
            yield OK, label, "%s, last write %s ago." % (name, a)

    # 3) hook-errors.log — the W1 escape hatch. Entries here explain a dead pipeline.
    #
    # C14: this log is the only thing standing between "the pipeline died" and
    # "nobody noticed", so a false entry in it is a P0 defect, not untidiness.
    # Before v1.6.2 it logged every SUCCESSFUL ledger append as a failure --
    # `& script.ps1` leaves $LASTEXITCODE unset, evidence-ledger exited its
    # switch via `break`, and `$null -ne 0` is TRUE -- producing ~250 fake
    # errors in one repo. A log that cries wolf on every success trains everyone
    # to skip it, which costs exactly the one moment it was built for. So known
    # false-positive signatures are counted SEPARATELY and reported as damage to
    # the log rather than folded in with real errors.
    KNOWN_FALSE_POSITIVES = [
        # "exited" followed by two spaces: the exit code interpolated to empty.
        # A genuine failure has a number there, so this cannot match a real one.
        ("ledger append exited  for", "pre-1.6.2 bug logged SUCCESSFUL ledger appends as failures"),
    ]
    hook_err = os.path.join(tel, "hook-errors.log")
    if os.path.exists(hook_err):
        errs = [l for l in open(hook_err, encoding="utf-8-sig") if l.strip()]
        fake, real = [], []
        for line in errs:
            if any(sig in line for sig, _ in KNOWN_FALSE_POSITIVES):
                fake.append(line)
            else:
                real.append(line)
        if fake:
            why = next(w for sig, w in KNOWN_FALSE_POSITIVES if sig in fake[0])
            yield FAIL, "log integrity (C14)", (
                "%d of %d lines in hook-errors.log are KNOWN FALSE POSITIVES (%s). "
                "A diagnostic log that reports success as failure gets ignored, and it "
                "is the only warning of a dead pipeline. Prune with "
                "tools/harness-bundle/fix-fleet-evidence.ps1 (it keeps genuine errors)."
                % (len(fake), len(errs), why))
        else:
            yield OK, "log integrity (C14)", "no known false-positive signature in hook-errors.log."
        if real:
            last = real[-1]
            try:
                j = json.loads(last)
                last = "%s: %s" % (j.get("hook", "?"), j.get("error", "")[:80])
            except Exception:
                last = last[:90]
            yield WARN, "hook errors", "%d genuine error(s) recorded — most recent: %s" % (len(real), last)
        else:
            yield OK, "hook errors", "none recorded."
    else:
        yield OK, "log integrity (C14)", "no hook-errors.log yet."
        yield OK, "hook errors", "none recorded."

    # 4) pipeline-context — exists, and tech_stack not the poison value "unknown"?
    ctx = os.path.join(H, "context", "pipeline-context.yaml")
    txt = _read(ctx)
    if local_only(".harness/context/pipeline-context.yaml"):
        yield _not_here("context (H1)", ".harness/context/pipeline-context.yaml")
    elif not txt:
        yield FAIL, "context (H1)", "pipeline-context.yaml missing — H1 criteria read it. session-start builds it."
    else:
        # Line-scan rather than a YAML dep: doctor must run with stdlib only.
        m = re.search(r'tech_stack:\s*\[?\s*"?unknown"?\s*\]?', txt)
        has_srs = bool(re.search(r'srs_path:\s*\S', txt))
        if m:
            yield FAIL, "context (H1)", "tech_stack is [\"unknown\"] — this fails H1-4 permanently and silently. Fill it in."
        elif not has_srs:
            yield WARN, "context (H1)", "present but srs_path not set — H1 partial."
        else:
            yield OK, "context (H1)", "present, tech_stack set, srs_path set."

    # 5) casan-policies — the file most scoring criteria read.
    pol = os.path.join(H, "control", "casan-policies.yaml")
    if not _read(pol):
        yield FAIL, "policies", "casan-policies.yaml missing — H3/H5/H6/H7 criteria read it."
    else:
        yield OK, "policies", "casan-policies.yaml present."

    # 5b) C15 handoff freshness.
    for item in _c15_handoff(root):
        yield item

    # 6) Hook wiring — is anything actually invoking the harness on tool use?
    settings = _read(os.path.join(root, ".claude", "settings.json"))
    if not settings:
        yield WARN, "hook wiring", ".claude/settings.json not found — hooks may not be wired for Claude Code."
    else:
        wired = [h for h in ("PostToolUse", "SessionStart", "SessionEnd") if h in settings]
        if "PostToolUse" in wired:
            yield OK, "hook wiring", "settings.json wires %s." % ", ".join(wired)
        else:
            yield FAIL, "hook wiring", "settings.json has no PostToolUse hook — audit/ledger never fire."

    # 7) Portal push freshness — did telemetry actually leave the machine?
    #
    # The cursor is written by push-telemetry.* running INSIDE this project. It
    # is not the only way telemetry reaches the Portal: a central sync can post
    # each project's files directly, and that pusher writes nothing here.
    #
    # The first version of this check said "no push cursor -- telemetry may
    # never have been pushed", which was FALSE for ten of eleven projects: they
    # are pushed every fifteen minutes by exactly such a sync. Ten false alarms
    # from one line, in the diagnostic whose whole job is to be believed.
    #
    # So the absent-cursor case says what is actually knowable from here, and
    # says it as INFO -- "cannot verify from this machine" is the C12-compliant
    # answer, and it is not a warning about the project.
    cur = os.path.join(tel, ".push-cursor.json")
    sync_cfg = os.path.join(H, "portal-sync.json")
    a = _age(cur)
    if a is not None:
        yield OK, "portal push", "last local push %s ago (cursor present)." % a
    elif not os.path.exists(sync_cfg):
        yield INFO, "portal push", "portal-sync.json absent — this project is not wired to a Portal, so there is nothing to push."
    else:
        yield INFO, "portal push", (
            "Portal sync is configured but no LOCAL push cursor exists. That is expected when a "
            "central sync posts this project's telemetry instead of push-telemetry running here — "
            "that pusher leaves no trace in this directory, so whether a push happened cannot be "
            "verified from this machine. Check the project's Fleet Health row in the Portal.")

    # 8) CI gates — do they exist, and would they ever FIRE?
    #
    # A workflow whose trigger names a branch this repo does not use installs
    # cleanly, sits in .github/, and never runs. Three such gates were created
    # three different ways in one session, each looking perfectly healthy: a
    # hardcoded `main` in a `master` repo, a repair script that read only
    # refs/remotes/ORIGIN/HEAD, and an installer that took the checked-out
    # feature branch. None produced an error anywhere. A dead gate is worse than
    # an absent one -- absence is visible, death reads as coverage -- so this
    # check exists to make that specific failure loud.
    # Which workflows are HARNESS gates? Identified by what they RUN, not by
    # what they are called. The old list was two hardcoded filenames --
    # tests.yml and harness-gate.yml, the two the installer happens to write --
    # so this repo's own policy-ci.yml, eight jobs running the harness suites,
    # was reported as "no harness workflows installed". A check that only
    # recognises its own installer's output tells every hand-written gate it
    # does not exist, which is the cry-wolf failure C14 names.
    wf = os.path.join(root, ".github", "workflows")
    # Two signals, either one counts. The installer's own filenames stay
    # recognised so nothing that used to be seen stops being seen; content
    # matching is what finds a gate somebody wrote themselves. Recognising only
    # the first is what made this repo's policy-ci.yml -- eight jobs running the
    # harness suites -- report as "no harness workflows installed".
    HARNESS_FILENAMES = ("tests.yml", "harness-gate.yml")
    HARNESS_MARKERS = ("harness_policy_check", "harness_doctor", "harness_redteam",
                       "harness-eval", "harness_golden", "tests/doctor", "tests/policy",
                       ".harness/scripts")
    harness_wf = []
    if os.path.isdir(wf):
        for f in sorted(os.listdir(wf)):
            if not f.endswith((".yml", ".yaml")):
                continue
            if f in HARNESS_FILENAMES:
                harness_wf.append(f)
                continue
            try:
                with open(os.path.join(wf, f), encoding="utf-8-sig", errors="replace") as fh:
                    body = fh.read()
            except OSError:
                continue
            if any(m in body for m in HARNESS_MARKERS):
                harness_wf.append(f)
    if not harness_wf:
        yield INFO, "ci gates", (
            "no workflow in .github/workflows runs a harness suite (looked for %s in every "
            ".yml/.yaml, not just the installer's own filenames). Run the installer with "
            "-WithCiGates to add one." % ", ".join(HARNESS_MARKERS[:3]))
    else:
        # Does the workflow even PARSE?
        #
        # The branch check below asks whether a valid workflow would fire on the
        # right branch. It cannot see the case one project actually hit: the
        # YAML was malformed (a block-scalar line indented level with its `run:`
        # key), so GitHub Actions never ran the workflow at all. Nothing was
        # red, because nothing ran. The file sits there looking like a gate.
        #
        # stdlib has no YAML parser, so this is a structural check, not a full
        # one: it verifies the keys a workflow must have are present at column
        # zero and that no line under a `run:` block scalar is indented less
        # than the block. That is exactly the shape that broke, and a check that
        # catches the observed failure beats a perfect one that does not exist.
        broken = []
        for f in harness_wf:
            txt = _read(os.path.join(wf, f))
            if not txt:
                continue
            lines = txt.split("\n")
            if not re.search(r"^on:\s*$|^on:\s*\S", txt, re.M) or not re.search(r"^jobs:\s*$", txt, re.M):
                broken.append("%s: missing a top-level `on:` or `jobs:` key" % f)
                continue
            for i, line in enumerate(lines):
                # `- run: |` is as common as `run: |`, and matching only the
                # second missed the very shape this check exists for.
                m = re.match(r"^(\s*(?:-\s+)?)run:\s*\|", line)
                if not m:
                    continue
                # The column where `run:` itself starts, not the leading
                # whitespace: under `- run: |` the key sits two columns right of
                # the dash, and continuation lines must clear THAT.
                key_col = len(m.group(1))
                for j in range(i + 1, len(lines)):
                    nxt = lines[j]
                    if not nxt.strip():
                        continue
                    if len(nxt) - len(nxt.lstrip()) <= key_col:
                        # A sibling key, the next list item or a comment ends the
                        # block legitimately (a less-indented line closes a block
                        # scalar; this repo's policy-ci.yml has a comment between
                        # jobs and runs green). Anything else at or left of the
                        # key is the malformed case.
                        if (not re.match(r"^\s*[-\w]+:", nxt) and not nxt.lstrip().startswith("- ")
                                and not nxt.lstrip().startswith("#")):
                            broken.append("%s line %d: a block-scalar line is indented level with its `run:` — "
                                          "GitHub rejects the file and the workflow never runs" % (f, j + 1))
                        break
        if broken:
            yield FAIL, "ci workflow syntax", (
                "workflow file(s) will not parse, so GitHub never runs them and nothing ever turns "
                "red: %s" % "; ".join(broken[:3]))
        else:
            yield OK, "ci workflow syntax", "%s parse as workflows." % ", ".join(harness_wf)

        default, source = _default_branch(root)
        dead, live = [], []
        for f in harness_wf:
            trigs = set(re.findall(r"^\s*branches:\s*\[([^\]]+)\]",
                                   _read(os.path.join(wf, f)), re.M))
            names = {b.strip().strip('"\'') for t in trigs for b in t.split(",")}
            if not names:
                continue
            if default and default not in names:
                dead.append("%s -> [%s]" % (f, ", ".join(sorted(names))))
            else:
                live.append(f)
        # C13: the verdict carries the provenance of the value it rests on.
        # `main (per the remote)` and `main (per a local cache)` are different
        # claims, and only the reader can decide whether the weaker one is good
        # enough -- which they cannot do if the check hides where it looked.
        WHENCE = {
            "remote": "asked the remote",
            "cache": "LOCAL CACHE refs/remotes/*/HEAD, written at clone time and never refreshed",
            "convention": "guessed from a conventional branch name that exists on a remote",
            "checkout": "taken from this working copy's current branch -- not evidence of the repo's default",
        }
        whence = WHENCE.get(source, source)
        if dead:
            yield FAIL, "ci gates", (
                "workflow triggers do not include this repo's default branch '%s' (%s): %s. "
                "These are installed but will NEVER run." % (default, whence, "; ".join(dead)))
        elif not default:
            yield WARN, "ci gates", "%s present, but the default branch could not be resolved to verify the trigger." % ", ".join(harness_wf)
        elif source in ("convention", "checkout"):
            # Matching a branch we only GUESSED proves nothing. Reporting OK here
            # would be the dead-gate bug wearing a green badge for a fourth time.
            yield WARN, "ci gates", (
                "%s trigger on '%s', which matches -- but that branch was %s, so the match "
                "is unverified. Run `git remote set-head <remote> -a` (or fetch) and re-run."
                % (", ".join(live), default, whence))
        else:
            yield OK, "ci gates", "%s present, triggering on '%s' (%s)." % (
                ", ".join(live), default, whence)

    # 9) C12 — does each gate have evidence it actually RAN?
    #
    # Every other check here asks whether a gate is *installed and would fire*.
    # That is not the same question, and the gap between them is where this
    # project has been burned repeatedly: three dead CI gates in one session,
    # each installed correctly, each silent, each reading as coverage. A gate
    # with no execution trace must be reported as UNPROVEN, never as passing --
    # "we have no evidence it ran" and "it ran and passed" are opposite claims.
    #
    # Deliberately does not invent evidence it cannot see. CI runs happen on a
    # server; nothing on this machine can prove one fired, so that gate is
    # reported as locally unverifiable rather than quietly assumed good. Saying
    # "I cannot check this from here" is the C12-compliant answer; saying OK
    # would be the exact failure the rule exists to stop.
    proven, unproven = [], []
    # --ci: the workstation gates prove themselves only through the ledger and
    # test-reports.jsonl, both machine-local; and the CI gate's proof is the very
    # run doing this check. Nothing here can be proven OR disproven -- say so.
    gate_proof_here = not (local_only(".harness/ledger/chain.jsonl")
                           and local_only(".harness/telemetry/test-reports.jsonl"))

    # Hooks prove themselves by what they write: a ledger longer than genesis
    # means the PostToolUse hook ran and the guard let a call through.
    chain_lines = 0
    if os.path.exists(chain):
        try:
            chain_lines = sum(1 for l in open(chain, encoding="utf-8-sig") if l.strip())
        except OSError:
            chain_lines = 0
    if chain_lines > 1:
        proven.append("hooks+guard (%d ledger entries)" % chain_lines)
    else:
        unproven.append("hooks+guard (ledger has no side-effect entry — the hook may never have fired)")

    # Eval suites prove themselves through their own reports.
    reports = os.path.join(tel, "test-reports.jsonl")
    suites_seen = set()
    if os.path.exists(reports):
        try:
            for line in open(reports, encoding="utf-8-sig"):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                # The writer emits `suite_name`; `suite` is accepted because an
                # older writer used it and a report we cannot name reads as a
                # suite that never ran -- i.e. this check would report a healthy
                # project's gates as unproven. Verified against the real file
                # rather than assumed: the first version of this check looked
                # only for `suite`, matched nothing, and confidently declared
                # three green suites unproven.
                suites_seen.add(rec.get("suite_name") or rec.get("suite") or "")
        except OSError:
            pass
    for suite in ("policy-ci", "red-team", "golden"):
        if suite in suites_seen:
            proven.append("eval:%s" % suite)
        else:
            unproven.append("eval:%s (no report ever written)" % suite)

    # Not under --ci: on a runner the "last run" is this run itself (or the red one
    # it is meant to replace), so asking GitHub would grade the gate by its own past.
    if harness_wf and gate_proof_here:
        # U7: ASK, instead of declaring it unknowable.
        #
        # This used to append "a local check cannot see whether a run ever
        # happened". True of the filesystem, false of the machine: `gh` is
        # authenticated here and the answer is one call away. And the answer
        # mattered — the first time this was actually asked, CI had been RED for
        # over a day across six consecutive runs, while doctor reported the
        # comfortable "cannot verify from here". Unproven and failing look the
        # same from a distance, which is precisely why C12 forbids resting there
        # when the fact is obtainable.
        state, detail = _ci_last_run(root)
        if state == "pass":
            proven.append("ci (%s)" % detail)
        elif state == "fail":
            # Not merely unproven — proven BAD. Its own FAIL, because burying a
            # red build inside a C12 summary is how it stayed red for a day.
            yield FAIL, "ci runs", (
                "the CI gate is installed, fires, and is FAILING: %s. A red gate protects nothing, "
                "and it reads identically to an unproven one on any screen that only tracks "
                "'evidence present'." % detail)
            unproven.append("ci (installed and running, but failing — see the 'ci runs' line)")
        elif state == "none":
            unproven.append("ci (%s installed; gh reached the repo and it has NO runs at all — "
                            "the workflow has never fired)" % ", ".join(harness_wf))
        else:
            # "unknown": gh missing, not logged in, or pointed at an account that
            # cannot see this repo. Kept apart from "no runs" on purpose -- the
            # wrong active account answers "nothing here" in a voice that sounds
            # exactly like a healthy-but-idle repo. Hit live while building this:
            # the account flipped mid-session and every query returned 404.
            unproven.append("ci (%s installed; could not ask GitHub: %s)"
                            % (", ".join(harness_wf), detail))

    if not gate_proof_here:
        yield INFO, "gate proof (C12)", (
            "not checkable on a CI runner: gate evidence is the ledger and test-reports.jsonl, both "
            "machine-local (machine-state-paths.yaml). This CI run is itself the CI gate's trace; "
            "the workstation gates are proven by harness doctor on a workstation.")
    elif not unproven:
        yield OK, "gate proof (C12)", "every gate has left execution evidence: %s." % "; ".join(proven)
    elif not proven:
        yield FAIL, "gate proof (C12)", (
            "NO gate has left any execution evidence. Nothing here is protecting "
            "anything yet: %s" % "; ".join(unproven))
    else:
        yield WARN, "gate proof (C12)", (
            "proven: %s || UNPROVEN (absence of evidence, not evidence of "
            "health): %s" % ("; ".join(proven), "; ".join(unproven)))

    # 10) C3 — is every side-effect-capable tool registered?
    #
    # Deny-by-default only means anything if the registry says which tools have
    # side effects. An entry missing side_effect/risk_level is not a neutral
    # gap: the guard has nothing to match on, so the tool passes.
    reg = os.path.join(H, "control", "tool-registry.json")
    reg_txt = _read(reg)
    if not reg_txt:
        yield WARN, "tool registry (C3)", "tool-registry.json missing — nothing declares which tools have side effects."
    else:
        try:
            tools = (json.loads(reg_txt) or {}).get("tools") or {}
        except ValueError as e:
            tools = None
            yield FAIL, "tool registry (C3)", "tool-registry.json does not parse: %s" % e
        if tools is not None:
            if not tools:
                yield WARN, "tool registry (C3)", "tool-registry.json has no entries."
            else:
                bad = [k for k, v in tools.items()
                       if not isinstance(v, dict) or ("side_effect" not in v and "risk_level" not in v)]
                if bad:
                    yield FAIL, "tool registry (C3)", (
                        "%d of %d entries declare neither side_effect nor risk_level, so the guard has "
                        "nothing to match on and those tools pass unchecked: %s%s"
                        % (len(bad), len(tools), ", ".join(sorted(bad)[:5]),
                           " …" if len(bad) > 5 else ""))
                else:
                    yield OK, "tool registry (C3)", "%d tools registered, all declaring side_effect/risk_level." % len(tools)

    # 11) C7 — do the hooks behave the same on both shells?
    #
    # Deliberately NOT "every .ps1 has a .sh". Parity is BEHAVIOURAL: this repo
    # has seven PowerShell scripts with no twin, and most are right to have none
    # -- lib-security-log.ps1 exists because PowerShell needs a shared helper,
    # while the bash guard writes the same events inline. A file-for-file check
    # would raise seven false alarms, which is the cry-wolf failure C14 names.
    #
    # What actually breaks a Linux machine is a hook wired on one side and not
    # the other, so that is what is compared.
    def _hook_scripts(path):
        txt = _read(path)
        if not txt:
            return None
        # Basenames without extension: the two files name .ps1 and .sh copies of
        # the same script, and the stem is what makes them comparable.
        return {os.path.splitext(os.path.basename(m))[0]
                for m in re.findall(r'[\w.-]+\.(?:ps1|sh)', txt)}

    win = _hook_scripts(os.path.join(root, ".claude", "settings.json"))
    posix = _hook_scripts(os.path.join(root, ".claude", "settings.posix.json"))
    if win is None or posix is None:
        yield INFO, "shell parity (C7)", "one of settings.json / settings.posix.json is absent — cannot compare hook wiring."
    else:
        win_only = sorted(win - posix)
        posix_only = sorted(posix - win)
        if win_only or posix_only:
            parts = []
            if win_only:
                parts.append("wired on Windows only: " + ", ".join(win_only))
            if posix_only:
                parts.append("wired on POSIX only: " + ", ".join(posix_only))
            yield FAIL, "shell parity (C7)", (
                "hook wiring differs between shells, so this project is governed differently "
                "depending on the machine — %s" % "; ".join(parts))
        else:
            yield OK, "shell parity (C7)", "%d hook scripts wired identically on both shells." % len(win)

    # 13) R-4 — does every logged bug have a golden case guarding it?
    #
    # A bug that is fixed and then forgotten comes back. The golden set is the
    # only mechanism here that would notice, and eight of nine project reviews
    # said the same thing: it holds ~12 generic cases and nothing project-
    # specific. A generator can scaffold a case; only a check makes anyone fill
    # it in.
    #
    # A golden case claims a bug by naming it: {"id": ..., "bug": "B-04", ...}.
    #
    # Severity is read from config, NOT hardcoded to FAIL. A brand-new check
    # that turns every existing project red on day one is the cry-wolf failure
    # C14 names -- and it would land in the same week C12 started depending on
    # people actually reading this output.
    pol_txt = _read(pol)
    m = re.search(r'^\s*buglist_path\s*:\s*"?([^"#\r\n]+?)"?\s*(#.*)?$', pol_txt, re.M)
    buglist = os.path.join(root, (m.group(1).strip() if m else "buglist.md"))
    strict = bool(re.search(r'^\s*require_golden_per_bug\s*:\s*true\s*(#.*)?$', pol_txt, re.M))

    bug_ids = []
    if os.path.exists(buglist):
        # Ids come from the status table's anchor links, which is the one place
        # every entry appears exactly once. Scanning the whole document would
        # also match every cross-reference in a bug's own prose and inflate the
        # denominator -- a coverage number that drifts with how chatty the
        # write-ups are is worse than none.
        seen = set()
        for bid in re.findall(r'\[(B-\d+)\]\(#', _read(buglist)):
            if bid not in seen:
                seen.add(bid)
                bug_ids.append(bid)

    # 12) Is the bug log actually being kept?
    #
    # The constitution requires logging every bug found or introduced. Nothing
    # checked whether that happens, and a fleet scan showed why it matters: of
    # 194 bugs logged across twelve projects, ONE project held 143 of them and
    # seven projects held exactly one each. A project that has run for weeks and
    # logged one bug is not a clean project, it is an unkept log -- and every
    # screen reading that corpus silently treats the two as the same thing.
    #
    # Reported as UNPROVEN, never as a violation. A project genuinely can be
    # quiet, and from here the two are indistinguishable; saying "you broke the
    # rule" on that evidence would be the false alarm C14 forbids. The check
    # states both numbers and lets a human weigh them.
    #
    # The threshold is what "has clearly been used" means. 200 recorded
    # side-effects is roughly a week of ordinary work, low enough that a
    # genuinely new project never trips it.
    BUSY_LEDGER_ENTRIES = 200
    if bug_ids is not None and os.path.exists(buglist):
        if chain_lines >= BUSY_LEDGER_ENTRIES and len(bug_ids) <= 1:
            yield WARN, "bug log kept", (
                "%d side-effects recorded but only %d bug(s) logged in %s. Either this project "
                "is unusually clean or the logging rule is not being followed — from here those "
                "look identical, so this is unproven, not a violation. Whoever knows the project "
                "can settle it in a second."
                % (chain_lines, len(bug_ids), os.path.relpath(buglist, root)))
        else:
            yield OK, "bug log kept", "%d bug(s) logged against %d recorded side-effects." % (
                len(bug_ids), chain_lines)

    covered = set()
    gdir = os.path.join(root, ".harness", "eval", "golden")
    gm = re.search(r'^\s*golden_dataset_path\s*:\s*"?([^"#\r\n]+?)"?\s*(#.*)?$', pol_txt, re.M)
    if gm:
        gdir = os.path.join(root, gm.group(1).strip().replace("/", os.sep))
    if os.path.isdir(gdir):
        for fn in sorted(os.listdir(gdir)):
            if not fn.endswith(".jsonl"):
                continue
            try:
                for line in open(os.path.join(gdir, fn), encoding="utf-8-sig"):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        b = json.loads(line).get("bug")
                    except ValueError:
                        continue
                    if b:
                        covered.add(str(b).strip())
            except OSError:
                continue

    # Bugs the project has declared un-expressible as a golden case, with a
    # reason. Without this, the only way to clear the check on a parser or
    # encoding bug is to invent a case that tests nothing -- which is worse than
    # an uncovered bug, because it also lies.
    exempt = set()
    ex = re.search(r'^\s*golden_exempt_bugs\s*:\s*$(.*?)(?=^\s{0,2}\S|\Z)', pol_txt, re.M | re.S)
    if ex:
        exempt = set(re.findall(r'^\s+(B-\d+)\s*:', ex.group(1), re.M))

    # A high-water mark: only bugs from this number on are REQUIRED to carry a
    # case or an exemption.
    #
    # Without it the rule was retroactive, and a fleet scan showed what that
    # means in practice: every one of eleven projects at 0%, one of them owing
    # 106 entries for bugs closed months before the rule existed. A demand
    # nobody can meet is not a standard, it is a permanent warning people learn
    # to scroll past -- and the only escape it left, declaring the whole backlog
    # exempt, manufactures a list nobody will ever read.
    #
    # Keyed on the bug NUMBER rather than a date: numbers are already in the
    # anchors, monotonic per project, and need no date parsing across twelve
    # differently-formatted tables.
    def _num(bid):
        try:
            return int(bid.split("-", 1)[1])
        except (IndexError, ValueError):
            return 0

    fm = re.search(r'^\s*golden_required_from_bug\s*:\s*"?(B-\d+)"?\s*(#.*)?$', pol_txt, re.M)
    from_num = _num(fm.group(1)) if fm else None

    if not bug_ids:
        yield INFO, "golden coverage (R-4)", (
            "no bug log found at %s — nothing to guard yet." % os.path.relpath(buglist, root))
    elif from_num is None:
        # Not configured: report the backlog as a fact and name the one line
        # that turns the rule on, rather than demanding the whole history.
        nxt = max(_num(b) for b in bug_ids) + 1
        yield INFO, "golden coverage (R-4)", (
            "%d bug(s) logged, and no starting point set, so nothing is required yet. R-4 applies "
            "from the bug you nominate onward — add `evaluation.golden_required_from_bug: \"B-%02d\"` "
            "to casan-policies.yaml and every bug from there needs a golden case or a stated "
            "exemption. The %d already closed stay backlog; demanding cases for them retroactively "
            "is how a rule becomes a warning people scroll past."
            % (len(bug_ids), nxt, len(bug_ids)))
        bug_ids = None   # reported; the per-bug block below must not run too
    else:
        backlog = [b for b in bug_ids if _num(b) < from_num]
        bug_ids = [b for b in bug_ids if _num(b) >= from_num]
        if not bug_ids:
            yield OK, "golden coverage (R-4)", (
                "no bug logged since B-%02d; %d earlier bug(s) are backlog and not required."
                % (from_num, len(backlog)))
            bug_ids = None  # nothing further to report
    if bug_ids:
        missing = [b for b in bug_ids if b not in covered and b not in exempt]
        accounted = len(bug_ids) - len(missing)
        pct = int(accounted / len(bug_ids) * 100)
        # Exemptions are counted apart from real cases. Folding them together
        # would let a project reach "100%" by declaring everything exempt, and
        # the number would still read as coverage.
        tail = ("%d golden case(s), %d declared un-expressible. doctor checks that an "
                "exemption EXISTS — it cannot check the reason is true or that the "
                "regression test it names is real."
                % (len(covered & set(bug_ids)), len(exempt & set(bug_ids))))
        if not missing:
            yield OK, "golden coverage (R-4)", "all %d logged bugs accounted for: %s" % (len(bug_ids), tail)
        else:
            detail = ("%d of %d logged bugs accounted for (%d%%). Neither a golden case nor an "
                      "exemption: %s%s. A fixed bug with no case is a bug nothing will notice "
                      "coming back. || %s"
                      % (accounted, len(bug_ids), pct,
                         ", ".join(missing[:5]), " …" if len(missing) > 5 else "", tail))
            if strict:
                yield FAIL, "golden coverage (R-4)", detail + " (evaluation.require_golden_per_bug is true)"
            else:
                yield WARN, "golden coverage (R-4)", detail

    # 13) Agent Pack readiness (v1.6.0) — is the project's test runner configured?
    ac = os.path.join(H, "control", "agent-config.yaml")
    ac_txt = _read(ac)
    if not ac_txt:
        yield INFO, "agent pack", "agent-config.yaml not set — impact-review/run-affected-tests will fall back to full suite."
    elif "pick the line for your stack" in ac_txt:
        # The installer scaffolds this file from the shipped sample when it
        # cannot detect the stack, and the sample's ACTIVE lines are the Node
        # example with every other stack commented out below them. Reporting
        # that as "configured" is the C12 failure in miniature: the Agent Pack
        # would run, `enable-ci-gates` would generate a workflow from
        # full_suite_cmd, and a project that never touched the file would get a
        # gate that exists, runs the wrong command, and reads as coverage.
        yield WARN, "agent pack", (
            "agent-config.yaml is still the shipped SAMPLE — its active commands are the Node/Vitest "
            "example. Pick the lines for this project's stack and delete the rest, or the Agent Pack "
            "and any CI generated from it will run the wrong suite while reporting success.")
    else:
        yield OK, "agent pack", "agent-config.yaml present (review->fix->test runner configured)."

    # N) Bundle drift — do the files on disk still match the install receipt?
    #
    # The receipt records what the installer WROTE. Nothing has ever checked
    # that it is still what is THERE, and in this fleet .harness/ is committed
    # into each project's own git, so git is a competing source of truth: a
    # checkout, reset or pull silently restores an older copy of any bundled
    # file while the receipt keeps claiming the new version.
    #
    # Found live on 2026-08-17: two projects were running an old
    # harness_doctor.py that predates --json, so the Portal had received no
    # doctor report from one for 21 hours and from the other for 2.4 days --
    # and nothing anywhere said so. The updater had reported success, because
    # it HAD written the files; git overwrote them afterwards.
    #
    # Hashing only the scripts/lib + scripts/* trees on purpose: control/ and
    # eval/ hold files a project is SUPPOSED to edit (its own policies, its own
    # golden cases -- see the bundle's `preserve` list), so drift there is
    # normal and flagging it would be the cry-wolf failure C14 forbids.
    # The repo that AUTHORS the bundle is the one place drift is not a finding.
    # Its .harness/scripts/ IS the source: every edit there is the work, and its
    # receipt is whatever version was last installed INTO it -- 12 releases stale
    # on this repo, because update-all-projects deliberately skips the toolkit.
    # Comparing authored files against that receipt reported 11 drifted scripts
    # as a FAIL, which is the check firing hardest exactly where it knows least.
    # Detected by bundles/*/bundle.yaml, the same signal policy-ci already uses
    # to decide a repo is the packer rather than a consumer.
    is_bundle_source = bool(glob.glob(os.path.join(root, "bundles", "*", "bundle.yaml")))

    receipt_path = os.path.join(H, ".bundle-manifest.json")
    if is_bundle_source:
        src_ver = ""
        for by in sorted(glob.glob(os.path.join(root, "bundles", "*", "bundle.yaml"))):
            try:
                with open(by, encoding="utf-8-sig", errors="replace") as fh:
                    for line in fh:
                        m = re.match(r'^version:\s*"?([0-9][^"\s]*)"?', line)
                        if m:
                            src_ver = m.group(1)
                            break
            except OSError:
                pass
            if src_ver:
                break
        yield INFO, "bundle integrity", (
            "this repo AUTHORS the bundle (bundles/*/bundle.yaml present%s), so .harness/scripts/ "
            "is the source rather than an installed copy and differing from the receipt is the "
            "work, not drift. The check runs where it means something: the consuming projects."
            % (", source at v%s" % src_ver if src_ver else ""))
    elif not os.path.exists(receipt_path):
        # U2: "no receipt" is TWO different states and this used to report both
        # as the harmless one.
        #
        #   never installed        -> INFO. Nothing is wrong.
        #   installed, receipt gone -> FAIL. The updater can no longer tell what
        #                              version this project runs, so every fleet
        #                              report counts it as missing while the
        #                              project itself looks fine from inside.
        #
        # Measured: 24hHotnewsAI lost its receipt AND its portal-sync.json after
        # a commit that stopped tracking .harness. Telemetry stopped flowing —
        # push-telemetry prints "push sync not configured, skipping" and exits 0
        # — and nothing anywhere said so. It was the fleet's largest project.
        #
        # Told apart by files only the installer writes. A directory tree alone
        # is not enough: .harness/telemetry/ gets created by the push client on
        # a project that was never installed.
        installed_markers = [
            os.path.join(H, "scripts", "powershell", "harness-runtime-guard.ps1"),
            os.path.join(H, "scripts", "bash", "harness-runtime-guard.sh"),
            os.path.join(H, "control", "casan-policies.yaml"),
            os.path.join(H, "schemas", "casan-policies.schema.json"),
        ]
        present = [p for p in installed_markers if os.path.exists(p)]
        if present:
            yield FAIL, "bundle integrity", (
                "%d bundle-installed file(s) are here but .bundle-manifest.json is GONE — this "
                "project WAS installed and lost its receipt, which is not the same as never having "
                "been installed. Every fleet scan now counts it as missing while it looks healthy "
                "from inside. Reinstall the bundle to restore the receipt, and check whether the "
                "same event took .harness/portal-sync.json with it." % len(present)
            )
        else:
            yield INFO, "bundle integrity", "no .bundle-manifest.json — this project was not installed from a bundle."

        # Same loss, different file, and the one with teeth: without
        # portal-sync.json the push client skips and exits 0, so telemetry stops
        # LEGITIMATELY. A leftover key is proof the project was wired once.
        if os.path.exists(os.path.join(H, "portal-sync.key")) and \
           not os.path.exists(os.path.join(H, "portal-sync.json")):
            yield FAIL, "portal sync config", (
                "portal-sync.key is here but portal-sync.json is GONE — this project was wired to "
                "the Portal and lost its config. push-telemetry prints 'push sync not configured, "
                "skipping' and exits 0, so telemetry stops with no error anywhere and the Portal "
                "shows the project as if nobody works on it."
            )
    else:
        try:
            receipt = json.loads(_read(receipt_path) or "{}")
            recorded = receipt.get("files") or []
            version = receipt.get("version") or "?"

            def _eol_hashes(data):
                # A core.autocrlf checkout, or the managed .gitattributes block's
                # `*.ps1 text eol=crlf`, changes line endings; a Windows editor may
                # add a BOM. Neither is drift (install.* and harness-verify.* compare
                # the same way). The receipt hashes the SHIPPED bytes -- LF, and for
                # most .ps1 WITH a UTF-8 BOM (policy-ci requires one) -- so the LF
                # form must be tried with the BOM kept as well as stripped. Before
                # 1.8.11 only the stripped form was tried: a BOM'd .ps1 checked out
                # as CRLF matched neither, and a fresh clone of AllIn1Site reported
                # 40 of 92 scripts drifted (B-77).
                lf = data.replace(b"\r\n", b"\n")
                forms = [data, lf, lf[3:] if lf[:3] == b"\xef\xbb\xbf" else lf]
                return {hashlib.sha256(f).hexdigest() for f in forms}

            # Per-file states (receipts from install 0.6 on). A file the last install
            # KEPT (project-owned, or hand-edited while the bundle did not change it)
            # or left in CONFLICT, or SKIPPED, is not "an installed file that
            # drifted": the receipt says it was never put there. Report it as what it
            # is. A receipt without states is read as before -- every file installed.
            by_state = {"conflict": [], "skipped": [], "kept": []}
            # Only entries the receipt carries a hash for can be compared; an
            # older receipt shape simply yields nothing to check, and says so
            # rather than passing silently.
            checked = drifted = unverifiable = 0
            examples = []
            for entry in recorded:
                if not isinstance(entry, dict):
                    continue
                rel = entry.get("path") or ""
                state = entry.get("state") or "installed"
                if rel and state in by_state:
                    by_state[state].append(rel.replace("\\", "/"))
                    continue
                # installed_sha256 is what the installer actually wrote (it can
                # differ from sha256 for a file the installer templated); it is
                # the honest baseline for "is this still what we installed".
                # "unknown" (an empty file) is no hash at all -- never a match.
                want = entry.get("installed_sha256") or entry.get("sha256")
                if want == "unknown":
                    want = entry.get("sha256") if entry.get("sha256") != "unknown" else None
                if not rel:
                    continue
                norm = rel.replace("\\", "/")
                if not (norm.startswith(".harness/scripts/") or norm.startswith("tools/harness-bundle/")):
                    continue
                if not want:
                    unverifiable += 1
                    continue
                checked += 1
                target = os.path.join(root, norm.replace("/", os.sep))
                if not os.path.exists(target):
                    drifted += 1
                    if len(examples) < 3:
                        examples.append(norm + " (missing)")
                    continue
                with open(target, "rb") as fh:
                    data = fh.read()
                if want not in _eol_hashes(data):
                    drifted += 1
                    if len(examples) < 3:
                        examples.append(norm)

            unresolved = by_state["conflict"] + by_state["skipped"]

            def _names(paths):
                return ", ".join(paths[:3]) + (" +%d more" % (len(paths) - 3) if len(paths) > 3 else "")

            notes = []
            if by_state["conflict"]:
                notes.append("%d in CONFLICT (yours kept, the shipped copy sits beside it as <file>.new: %s)"
                             % (len(by_state["conflict"]), _names(by_state["conflict"])))
            if by_state["skipped"]:
                notes.append("%d SKIPPED (existed, installed without --force: %s)"
                             % (len(by_state["skipped"]), _names(by_state["skipped"])))
            if by_state["kept"]:
                notes.append("%d kept as yours (%s)" % (len(by_state["kept"]), _names(by_state["kept"])))
            note = ("; the last install also left: " + "; ".join(notes)) if notes else ""

            if checked == 0 and not notes:
                yield INFO, "bundle integrity", (
                    "receipt for v%s carries no per-file hashes — cannot verify the installed files "
                    "are still the ones that were installed. Re-install with a current packer to enable "
                    "this check." % version)
            elif drifted:
                yield FAIL, "bundle integrity", (
                    "%d of %d installed bundled script(s) no longer match the v%s receipt (%s). Something "
                    "overwrote them after install -- in this fleet that is usually the project's own "
                    "git, which tracks .harness/. Re-install the bundle, then COMMIT it, or the next "
                    "checkout restores the old copy again%s."
                    % (drifted, checked, version, ", ".join(examples), note))
            elif unresolved:
                yield WARN, "bundle integrity", (
                    "the v%s install is PARTIAL: %d file(s) were not applied%s. The %d installed "
                    "script(s) checked match the receipt. Resolve each conflict by hand (or adopt the "
                    ".new copy) and re-install; until then this project is not fully on v%s."
                    % (version, len(unresolved), note, checked, version))
            else:
                yield OK, "bundle integrity", "%d bundled script(s) match the v%s receipt%s%s." % (
                    checked, version, note,
                    (" (%d empty/unhashed file(s) not compared)" % unverifiable) if unverifiable else "")
        except Exception as e:
            yield WARN, "bundle integrity", "could not verify bundle files: %s" % e


def as_json(root, ci=False):
    """The same run, as the JSON the push client sends to the Portal (S-1).

    Emitting the identical check list the terminal shows -- not a summary -- so
    the Portal renders exactly what the developer saw. A health screen that
    paraphrases its source is a second place for the truth to drift.
    """
    checks = [{"status": s, "label": l, "detail": d} for s, l, d in run(root, ci=ci)]
    counts = {k: sum(1 for c in checks if c["status"] == k) for k in (OK, WARN, FAIL, INFO)}
    if counts[FAIL]:
        verdict = "failing"
    elif counts[WARN]:
        verdict = "thin"
    else:
        verdict = "healthy"
    return {
        "ran_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "counts": counts,
        "verdict": verdict,
        "checks": checks,
    }


def main(argv):
    # Consuming projects run on Windows consoles whose default codepage (cp932,
    # cp1252, ...) cannot encode the em-dash/arrow characters below and would
    # crash the whole diagnostic mid-print. Force UTF-8 and never die on a glyph.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    root = "."
    strict = False
    want_json = False
    ci = False
    for a in argv[1:]:
        if a == "--strict":
            strict = True
        elif a == "--json":
            want_json = True
        elif a == "--ci":
            ci = True
        elif a in ("-h", "--help"):
            print("usage: harness_doctor.py [ROOT] [--strict] [--json] [--ci]"); return 0
        elif not a.startswith("-"):
            root = a
    root = os.path.abspath(root)

    if want_json:
        # Machine output only -- no banner, so the caller can pipe it straight
        # into the push payload.
        print(json.dumps(as_json(root, ci=ci), ensure_ascii=False))
        return 0

    print("harness doctor  --  %s" % root)
    print("=" * 60)
    counts = {OK: 0, WARN: 0, FAIL: 0, INFO: 0}
    icon = {OK: "[ OK ]", WARN: "[WARN]", FAIL: "[FAIL]", INFO: "[INFO]"}
    for status, label, detail in run(root, ci=ci):
        counts[status] += 1
        print("%s %-20s %s" % (icon[status], label, detail))
    print("=" * 60)
    print("%d OK, %d WARN, %d FAIL" % (counts[OK], counts[WARN], counts[FAIL]))
    if counts[FAIL]:
        print("verdict: evidence pipeline has FAILING checks -- fix the [FAIL] lines above.")
    elif counts[WARN]:
        print("verdict: pipeline works but some evidence is thin (see [WARN]).")
    else:
        print("verdict: evidence pipeline healthy.")
    return 1 if (strict and counts[FAIL]) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
