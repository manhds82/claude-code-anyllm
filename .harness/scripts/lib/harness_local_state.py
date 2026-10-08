#!/usr/bin/env python3
"""harness_local_state -- the ONE reader/writer for per-machine state (Portal v2 P1 1.7).

Why: `.harness/portal-sync.json` used to carry `member_email` (one PERSON) next to
`portal_url` / `project_id` (the PROJECT), so the file could not be committed without
handing every clone somebody else's identity.  The split:

    .harness/portal-sync.json          project-wide, committable, NO machine/person field
    .harness/local/checkout.json       this machine: checkout_id, device_id, credential
                                       (dpapi-v1: / plain-v1:), and member_email
    .harness/control/machine-state-paths.yaml
                                       the list of everything that is machine-local

Every script that needs member_email goes through here, so push-telemetry.ps1 / .sh,
collect-codex.ps1 / .sh, set-member-email, connect-portal and the repair cannot drift.

Provenance (C13): a read returns the value AND where it came from.  The old location is
still honoured -- but it yields a WARNING that names the file, never a quiet pass.

CLI (stdout: one JSON line; exit 0 unless the operation itself failed):
    member-email <root>               {"value","source","warning"}
    set-member-email <root> <email>   write .harness/local/checkout.json (keeps other keys)
    tracked <root> [spec_root]        {"ok":bool,"patterns":[...],"tracked":[machine-local files git tracks],"error":""}
    migrate-member-email <root>       move member_email out of the committed portal-sync.json
                                      into the local file (local FIRST, committed file only
                                      after the local write read back)
"""
import json
import os
import re
import subprocess
import sys

LOCAL_REL = ".harness/local/checkout.json"
LEGACY_REL = ".harness/portal-sync.json"
SPEC_REL = ".harness/control/machine-state-paths.yaml"
FIELD = "member_email"


def _p(root, rel):
    return os.path.join(root, *rel.split("/"))


def _load_json(path):
    """(data, error). error is '' when absent-but-fine is NOT the case: a missing file is
    (None, 'absent'); a file that does not parse is (None, 'unreadable: ...')."""
    if not os.path.isfile(path):
        return None, "absent"
    try:
        with open(path, encoding="utf-8-sig") as f:
            d = json.load(f)
        return (d, "") if isinstance(d, dict) else (None, "unreadable: not an object")
    except (OSError, ValueError) as e:
        return None, "unreadable: %s" % type(e).__name__


def parent_checkout(root):
    """Main checkout root when `root` is a linked git worktree, else None."""
    dotgit = os.path.join(root, ".git")
    if not os.path.isfile(dotgit):
        return None
    try:
        with open(dotgit, encoding="utf-8") as f:
            line = f.readline().strip()
    except OSError:
        return None
    if not line.startswith("gitdir:"):
        return None
    gitdir = line[len("gitdir:"):].strip()
    if not os.path.isabs(gitdir):
        gitdir = os.path.normpath(os.path.join(root, gitdir))
    if "/worktrees/" not in gitdir.replace("\\", "/"):
        return None
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.normpath(gitdir))))


def _checkout_binds_person(root):
    """True when this machine holds a checkout credential (id + secret): the server derives the
    person from it, so a missing member_email is not an attribution gap and warning about it
    on every push would be a false alarm (C14). Any doubt -> False (keep the warning)."""
    try:
        import importlib.util
        lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness_checkout_facts.py")
        if not os.path.isfile(lib):
            return False
        sp = importlib.util.spec_from_file_location("harness_checkout_facts", lib)
        mod = importlib.util.module_from_spec(sp)
        sp.loader.exec_module(mod)
        return bool(mod.checkout_auth(root))
    except Exception:  # noqa: BLE001
        return False


def read_member_email(root):
    """-> {"value","source","warning"}.  source: "local:<path>", "local:<path> (parent
    checkout)", "legacy:<path>", or "none".  warning is "" only for a clean local read."""
    root = os.path.abspath(root)
    parent = parent_checkout(root)
    roots = [(root, "")] + ([(parent, " (parent checkout)")] if parent else [])
    notes = []
    for r, tag in roots:
        path = _p(r, LOCAL_REL)
        d, err = _load_json(path)
        if d is not None:
            v = str(d.get(FIELD) or "").strip()
            if v:
                return {"value": v, "source": "local:" + path + tag, "warning": "; ".join(notes)}
        elif err != "absent":
            notes.append("%s is %s -- ignored" % (LOCAL_REL, err))
    for r, tag in roots:
        path = _p(r, LEGACY_REL)
        d, err = _load_json(path)
        if d is not None:
            v = str(d.get(FIELD) or "").strip()
            if v:
                notes.append(
                    "%s read from the LEGACY committed %s (%s), not %s -- that file is shared by "
                    "every clone; move it with tools/harness-bundle/fix-untrack-machine-state "
                    "or set-member-email" % (FIELD, LEGACY_REL, path, LOCAL_REL))
                return {"value": v, "source": "legacy:" + path + tag, "warning": "; ".join(notes)}
        elif err != "absent":
            notes.append("%s is %s -- ignored" % (LEGACY_REL, err))
    if not _checkout_binds_person(root):
        notes.append("%s is not set (looked in %s and %s): the Portal cannot attribute this machine's "
                     "tokens to a person -- run set-member-email" % (FIELD, LOCAL_REL, LEGACY_REL))
    return {"value": "", "source": "none", "warning": "; ".join(notes)}


def write_member_email(root, email):
    """Write member_email into <root>/.harness/local/checkout.json, keeping every other key
    (the credential!).  Raises OSError when the folder cannot be made."""
    root = os.path.abspath(root)
    path = _p(root, LOCAL_REL)
    d, err = _load_json(path)
    if d is None:
        if err != "absent":
            raise OSError("%s exists but is %s; refusing to overwrite a credential file" % (path, err))
        d = {}
    d[FIELD] = str(email).strip()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    # B6: the file holds the credential, so it is born 0600 -- never created with the default
    # umask and tightened afterwards (the mode argument is ignored on Windows, where the
    # ordinary write is all there is).
    try:
        os.remove(tmp)      # a stale temp from a crashed run would defeat O_EXCL
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)
    return path


# ---- the machine-local path list -------------------------------------------------------

def _glob_to_re(pat):
    out, i = [], 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def load_spec(root):
    """-> (spec dict, error).  Uses PyYAML when present; otherwise a narrow reader that
    only understands the `path:` / `file:` / `field:` / `moved_to:` lines (enough for the
    repair on a machine without PyYAML).  Missing file -> (None, 'absent')."""
    path = _p(os.path.abspath(root), SPEC_REL)
    if not os.path.isfile(path):
        return None, "absent"
    try:
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
    except OSError as e:
        return None, "unreadable: %s" % type(e).__name__
    try:
        import yaml  # type: ignore
        d = yaml.safe_load(text)
        return (d, "") if isinstance(d, dict) else (None, "unreadable: not a mapping")
    except ImportError:
        pass
    except Exception as e:  # noqa: BLE001
        return None, "unreadable: %s" % type(e).__name__
    spec, section, cur = {"machine_local": [], "moved_fields": []}, None, None
    for line in text.splitlines():
        s = line.split("#", 1)[0].rstrip() if not re.search(r'["\']', line) else line.rstrip()
        m = re.match(r"^([a-z_]+):\s*$", s)
        if m:
            section = m.group(1)
            continue
        m = re.match(r"^\s*-\s*(path|file):\s*(.+?)\s*$", s)
        if m and section in ("machine_local", "moved_fields"):
            cur = {m.group(1): m.group(2).strip("\"'")}
            spec[section].append(cur)
            continue
        m = re.match(r"^\s+(field|moved_to|status|kind|grade|needs_flag):\s*(.+?)\s*$", s)
        if m and cur is not None and section in ("machine_local", "moved_fields"):
            cur[m.group(1)] = m.group(2).strip("\"'")
    return spec, ""


def git_tracked(root):
    """-> (list of tracked repo-relative paths, error).  error 'no git' / 'not a repo'."""
    try:
        r = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None, "git is not available"
    if r.returncode != 0:
        return None, "not a git work tree"
    return [x.decode("utf-8", "replace") for x in r.stdout.split(b"\0") if x], ""


def tracked_machine_files(root, spec_root=None, with_patterns=False):
    """-> (sorted list of tracked files that match machine_local, error).
    spec_root: read the path list from another checkout (the repair uses the toolkit's own
    list for a project that predates the file).  with_patterns: -> (files, patterns, error)."""
    root = os.path.abspath(root)
    spec, err = load_spec(spec_root or root)
    if spec is None:
        res = (None, "machine-state-paths.yaml %s" % err)
        return (res[0], [], res[1]) if with_patterns else res
    tracked, err = git_tracked(root)
    if tracked is None:
        return (None, [], err) if with_patterns else (None, err)
    pairs = [(str(e["path"]), _glob_to_re(str(e["path"]))) for e in (spec.get("machine_local") or []) if e.get("path")]
    hit = sorted(t for t in tracked if any(r.match(t) for _, r in pairs))
    if not with_patterns:
        return hit, ""
    used = [pt for pt, r in pairs if any(r.match(t) for t in hit)]
    return hit, used, ""


def _committed_json(root, rel):
    """(data, error) of the INDEX blob of `rel` (what the next commit carries), falling back to
    the working tree only when git cannot answer. A field removed from the working tree but
    still staged is still committed; one only in an uncommitted edit is not."""
    try:
        r = subprocess.run(["git", "-C", root, "show", ":" + rel], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return _load_json(_p(root, rel))
    if r.returncode != 0:
        return _load_json(_p(root, rel))
    try:
        d = json.loads(r.stdout.decode("utf-8-sig"))
        return (d, "") if isinstance(d, dict) else (None, "unreadable: not an object")
    except ValueError as e:
        return None, "unreadable: %s" % type(e).__name__


def guarded_patterns(spec_root):
    """-> list of spec `path`s whose entry carries `needs_flag`."""
    spec, _ = load_spec(spec_root)
    return [str(e["path"]) for e in ((spec or {}).get("machine_local") or [])
            if e.get("needs_flag") and e.get("path")]


def guarded_machine_files(root, files, spec_root=None):
    """-> {file: flag} for the tracked machine-local `files` whose spec entry carries
    `needs_flag` (today: the live ledger, flag "include-ledger"). The repair refuses to untrack
    these without the matching explicit flag; the policy check grades them WARN, not FAIL --
    a FAIL that the default repair refuses to clear could never be cleared (C14)."""
    spec, _ = load_spec(spec_root or root)
    out = {}
    for e in ((spec or {}).get("machine_local") or []):
        flag = e.get("needs_flag")
        if not (flag and e.get("path")):
            continue
        rx = _glob_to_re(str(e["path"]))
        for f in files:
            if rx.match(f):
                out[f] = str(flag)
    return out


def committed_field_leaks(root):
    """-> list of {"file","field","moved_to"} for fields that sit in a TRACKED committed file
    although the spec says they live elsewhere."""
    root = os.path.abspath(root)
    spec, _ = load_spec(root)
    tracked, _ = git_tracked(root)
    if not spec or tracked is None:
        return []
    out = []
    for mv in spec.get("moved_fields") or []:
        f = mv.get("file")
        if f in tracked:
            d, _e = _committed_json(root, f)
            if d is not None and str(d.get(mv.get("field")) or "").strip():
                out.append({"file": f, "field": mv.get("field"), "moved_to": mv.get("moved_to")})
    return out


def migrate_member_email(root):
    """Move member_email from the committed config into the local file.  Order matters:
    local is written and READ BACK before the committed file is touched, and the committed
    file is rewritten only if that succeeded.  -> {"moved":bool,"value":str,"note":str}"""
    root = os.path.abspath(root)
    legacy = _p(root, LEGACY_REL)
    d, err = _load_json(legacy)
    if d is None:
        return {"moved": False, "value": "", "note": "%s %s" % (LEGACY_REL, err)}
    if FIELD not in d:
        return {"moved": False, "value": "", "note": "no %s in %s" % (FIELD, LEGACY_REL)}
    value = str(d.get(FIELD) or "").strip()
    if value:
        have = read_member_email(root)
        if not have["source"].startswith("local:") or have["value"] != value:
            # an existing, different local value is the machine's own choice: keep it
            if have["source"].startswith("local:"):
                value = have["value"]
            else:
                write_member_email(root, value)
                back = read_member_email(root)
                if back["value"] != value or not back["source"].startswith("local:"):
                    raise OSError("member_email did not read back from %s; committed file untouched" % LOCAL_REL)
    del d[FIELD]
    tmp = legacy + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, legacy)
    return {"moved": True, "value": value, "note": "moved to %s" % LOCAL_REL}


def _emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":"), ensure_ascii=True) + "\n")


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cmd, root = argv[1], argv[2]
    try:
        if cmd == "member-email":
            _emit(read_member_email(root))
        elif cmd == "set-member-email":
            if len(argv) < 4 or not argv[3].strip():
                sys.stderr.write("set-member-email <root> <email>\n")
                return 2
            _emit({"written": write_member_email(root, argv[3])})
        elif cmd == "tracked":
            files, pats, err = tracked_machine_files(root, argv[3] if len(argv) > 3 else None, True)
            spec_arg = argv[3] if len(argv) > 3 else None
            _emit({"ok": err == "", "tracked": files or [], "patterns": pats, "error": err,
                   "guarded": guarded_machine_files(root, files or [], spec_arg),
                   # spec paths that carry needs_flag: the repair adds these to .gitignore ONLY
                   # when the matching flag is given (QA p1bc #7)
                   "guarded_patterns": guarded_patterns(spec_arg or root)})
        elif cmd == "migrate-member-email":
            _emit(migrate_member_email(root))
        else:
            sys.stderr.write("unknown command: %s\n" % cmd)
            return 2
    except OSError as e:
        sys.stderr.write("[local-state] FAILED: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
