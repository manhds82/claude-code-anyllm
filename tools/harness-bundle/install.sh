#!/usr/bin/env bash
# Harness Bundle installer (POSIX parity of install.ps1). Verifies the bundle's
# SHA-256 content hash before writing anything (fail-closed), then materializes
# every file byte-exact into the target project. Existing files are skipped
# unless --force. Requires python3 (for JSON/base64/hash; avoids jq/coreutils
# flag differences between macOS and Linux).
#
#   ./install.sh --bundle standard-governance-1.0.0.bundle.json --target /path/to/project [--force] [--merge-claude]
#
#   --merge-claude  After installing, auto-merge CLAUDE.harness.md into CLAUDE.md.
#                   Creates CLAUDE.md if absent; appends with <!-- harness:merged -->
#                   sentinel if present but not yet merged; skips if sentinel found.
set -euo pipefail

BUNDLE=""; TARGET=""; FORCE=0; MERGE_CLAUDE=0; DRY_RUN=0; WITH_CI_GATES=0
PROJECT_NAME=""; PROJECT_DESC=""; FORCE_IDENTITY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)       BUNDLE="$2"; shift 2;;
    --target)       TARGET="$2"; shift 2;;
    --force)        FORCE=1; shift;;
    # Show what an install WOULD do and write nothing. Every consuming team asked
    # for this: they wanted the blast radius before committing to it.
    --dry-run)      DRY_RUN=1; shift;;
    # Copy the shipped CI templates into .github/. Opt-in: adding workflow files
    # changes what runs on every push, not something an install should do quietly.
    --with-ci-gates) WITH_CI_GATES=1; shift;;
    # --merge-claude is the old name; both project the governance text into every
    # guide file listed in casan-policies governance.guide_targets.
    --merge-guides|--merge-claude) MERGE_CLAUDE=1; shift;;
    --project-name)        PROJECT_NAME="$2"; shift 2;;
    --project-description) PROJECT_DESC="$2"; shift 2;;
    --force-identity)      FORCE_IDENTITY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
# Default bundle: newest *.bundle.json next to this script.
if [[ -z "$BUNDLE" ]]; then
  BUNDLE="$(ls -1t "$(dirname "$0")"/*.bundle.json 2>/dev/null | head -1 || true)"
fi
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || { echo "bundle file not found (use --bundle)" >&2; exit 2; }
[[ -n "$TARGET" ]] || { echo "usage: --target <project dir> required" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[[ -n "$PY" ]] || { echo "python3 required" >&2; exit 3; }

# Python helpers shared by every embedded python step below. They used to live in
# the FIRST block only, so the guide-merge and the receipt re-stamp blocks called
# `safe_dest` and died with NameError (the re-stamp one on EVERY run, which the
# `|| echo WARNING` then hid). One definition, prepended to each block.
emit_common_py() {
cat <<'PYC'
import hashlib, os, re, sys
UNKNOWN = "unknown"     # receipt value for a hash that cannot honestly be stated


def sha_hex(data):
    return hashlib.sha256(data).hexdigest()


def sha_or_unknown(data):
    """sha256 of the bytes, or "unknown" for an empty file: the hash of nothing is
    a real hash, and recording it makes every empty file look verified."""
    return sha_hex(data) if len(data) else UNKNOWN


def norm_eol(data):
    """BOM and CRLF stripped -- what an EOL/BOM-only difference (core.autocrlf
    checkout, a Windows editor) must not count as a change. install.ps1 and
    harness-verify.* do exactly the same."""
    if data[:3] == b"\xef\xbb\xbf":
        data = data[3:]
    return data.replace(b"\r\n", b"\n")


def eol_hashes(data):
    """Every sha256 the receipt may hold for these bytes if only EOL/BOM moved.

    The receipt hashes the SHIPPED bytes: LF, and for most .ps1 WITH a UTF-8 BOM.
    A CRLF checkout of such a file (core.autocrlf, or the managed .gitattributes
    `*.ps1 text eol=crlf`) is BOM+CRLF; stripping BOM and CRLF together gives a
    form the receipt never held, so the LF form is tried with the BOM kept too.
    Before 1.8.11 it was not, and an update called every such file hand-edited
    (B-77). install.ps1, harness-verify.* and harness_doctor.py do the same."""
    lf = data.replace(b"\r\n", b"\n")
    return {sha_hex(data), sha_hex(lf), sha_hex(norm_eol(data))}


def safe_dest(target, relpath):
    """Resolve a bundle-declared path INSIDE target, or refuse.

    Destinations were built with os.path.join(target, *path.split("/")) and the
    path came from the bundle. os.path.join is not a containment operator: a
    component of ".." walks out of the target, and an absolute component (or a
    Windows drive letter) discards `target` altogether. A bundle declaring
    "../../../etc/cron.d/harness" installed there.

    The content hash does NOT cover this. It proves the bundle was not altered
    after packing; it says nothing about whether what was packed is benign. A
    bundle is executable governance content fetched from elsewhere, so its
    paths are input, not fact.

    Rejects rather than sanitises: silently rewriting a traversing path to
    something "safe" installs a file the bundle author did not name, which is
    its own surprise. A bundle that wants out of the target is broken or
    hostile, and either way the operator should hear about it.
    """
    if not relpath or relpath.strip() != relpath:
        sys.exit("Refusing bundle path (empty or padded): %r" % relpath)
    if relpath.startswith("/") or relpath.startswith("\\"):
        sys.exit("Refusing absolute bundle path: %r" % relpath)
    if re.match(r"^[A-Za-z]:", relpath):
        sys.exit("Refusing bundle path with a drive letter: %r" % relpath)
    parts = relpath.replace("\\", "/").split("/")
    if any(part in ("..", "") for part in parts):
        sys.exit("Refusing bundle path that escapes the target: %r" % relpath)
    dest = os.path.join(target, *parts)
    root = os.path.realpath(target)
    # realpath the PARENT: the file itself need not exist yet, and a symlink
    # planted at the destination is exactly the trick this is guarding against.
    parent = os.path.realpath(os.path.dirname(dest))
    if parent != root and not parent.startswith(root + os.sep):
        sys.exit("Refusing bundle path that resolves outside the target: %r -> %s" % (relpath, dest))
    return dest
PYC
}

# The installer's own copy of the ownership rules (see the union note inside the
# python block). Resolved relative to this script; absent for a standalone copy
# of the installer, which the python side treats as "bundle rules only".
OWN_RULES="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd || true)/.harness/control/bundle-ownership.yaml"

{ emit_common_py; cat <<'PY'
import json, base64, hashlib, os, re, sys, fnmatch
bundle_path, target, force = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
dry_run = len(sys.argv) > 4 and sys.argv[4] == "1"
own_rules_path = sys.argv[5] if len(sys.argv) > 5 else ""
b = json.load(open(bundle_path, encoding="utf-8"))
# Fail-closed integrity: recompute hash over sorted path:b64 pairs.
hi = "\n".join("%s:%s" % (f["path"], f["b64"]) for f in b["files"])
comp = hashlib.sha256(hi.encode("utf-8")).hexdigest()
if comp != b["content_hash"]:
    sys.exit("Bundle integrity check FAILED: computed %s != declared %s" % (comp, b["content_hash"]))


print("[install] %s v%s (%d files) -> %s" % (b["name"], b["version"], b["file_count"], target))
written = skipped = kept = merged = 0
merges = []
# Files the project OWNS once they exist: never overwritten, not even with
# --force, because they carry per-project decisions. When the shipped copy has
# moved on, a `<file>.new` is dropped beside it to adopt new keys deliberately.
preserve = set(b.get("preserve") or [])
conflicts = []

def parse_ownership(text):
    """Shared by the payload parse and the installer-side fallback below.
    Returns the four rule collections and prints nothing -- the caller decides."""
    owned, globs, keyed, mergem, hookset = [], [], {}, {}, {}
    section = ""
    for line in text.splitlines():
        m = re.match(r"^([a-z_]+):\s*$", line)
        if m:
            section = m.group(1); continue
        if re.match(r"^[a-z_]+:", line):
            section = ""; continue
        m = re.match(r'^\s+-\s*"?([^"]+?)"?\s*$', line)
        if m and section == "project_owned":
            owned.append(m.group(1))
        elif m and section == "project_owned_globs":
            globs.append(m.group(1))
        m = re.match(r'^\s+"([^"]+)":\s*"([^"]+)"', line)
        if m and section == "keyed_lists":
            keyed[m.group(1)] = m.group(2)
        elif m and section == "merge_json_maps":
            mergem[m.group(1)] = m.group(2)
        elif m and section == "merge_hook_settings":
            hookset[m.group(1)] = m.group(2)
    return owned, globs, keyed, mergem, hookset


# Ownership rules (C2) read from the bundle's OWN payload, so the rules governing
# this install are the ones this bundle shipped -- not whatever an older copy left
# on disk. Absent = fall back to `preserve` alone, i.e. previous behaviour exactly.
own_globs, keyed_lists, merge_maps, hook_settings = [], {}, {}, {}
_own = next((f for f in b["files"] if f["path"] == ".harness/control/bundle-ownership.yaml"), None)
if _own:
    try:
        o, g, kl, mm, hs = parse_ownership(base64.b64decode(_own["b64"]).decode("utf-8"))
        preserve.update(o); own_globs.extend(g)
        keyed_lists.update(kl); merge_maps.update(mm); hook_settings.update(hs)
    except Exception as e:
        print("[own] WARNING: bundle-ownership.yaml unreadable (%s); falling back to preserve list only" % e)

# A bundle packed before a rule existed must not reopen the loss that rule
# prevents: v1.6.0 ships no merge_json_maps, so governed by its payload alone it
# would still overwrite tool-registry.json -- the exact defect. So the rules
# that travel BESIDE this installer (../../.harness/control/, in this repo and
# in an installed project alike) are unioned in. A union can only protect more
# than the bundle asked, never less, and the bundle stays authoritative wherever
# both copies define the same path, so a future bundle can still re-scope a rule
# on purpose. No file there is the standalone-installer case and means "bundle
# rules only" -- the previous behaviour, silently.
if own_rules_path and os.path.isfile(own_rules_path):
    try:
        o, g, kl, mm, hs = parse_ownership(open(own_rules_path, encoding="utf-8-sig").read())
        newer = []
        for p in o:
            if p not in preserve:
                preserve.add(p); newer.append("project_owned:%s" % p)
        for gg in g:
            if gg not in own_globs:
                own_globs.append(gg); newer.append("project_owned_globs:%s" % gg)
        for k in sorted(kl):
            if k not in keyed_lists:
                keyed_lists[k] = kl[k]; newer.append("keyed_lists:%s" % k)
        for k in sorted(mm):
            if k not in merge_maps:
                merge_maps[k] = mm[k]; newer.append("merge_json_maps:%s" % k)
        for k in sorted(hs):
            if k not in hook_settings:
                hook_settings[k] = hs[k]; newer.append("merge_hook_settings:%s" % k)
        if newer:
            print("[own] this bundle predates %d ownership rule(s); applied from the installer's copy: %s"
                  % (len(newer), ", ".join(newer)))
    except Exception as e:
        print("[own] WARNING: installer-side bundle-ownership.yaml unreadable (%s); using the bundle's own rules only" % e)

# The PREVIOUS install's receipt already records a sha256 per shipped file.
# Comparing it to disk answers what `preserve` never could: did the project
# hand-edit a file the bundle owns? Overwriting that silently is how four
# separate teams lost work.
prev_hashes = {}      # path -> last INSTALLED hash (the baseline a hand edit is measured against)
prev_ship = {}        # path -> hash of the shipped bytes the last run carried
prev_state = {}       # path -> state the last run recorded ("" for receipts older than states)
_pr = os.path.join(target, ".harness", ".bundle-manifest.json")
if os.path.exists(_pr):
    try:
        # Prefer installed_sha256 -- what the LAST install left on disk. Fall back
        # to sha256 (shipped bytes) only for receipts written before that field
        # existed, where it is the best baseline available. "unknown" is the
        # receipt's way of saying "no honest hash" and is no baseline at all.
        for e in (json.load(open(_pr, encoding="utf-8-sig")).get("files") or []):
            if e.get("path"):
                h = e.get("installed_sha256") or e.get("sha256") or ""
                prev_hashes[e["path"]] = "" if h == UNKNOWN else h
                prev_ship[e["path"]] = "" if e.get("sha256") == UNKNOWN else (e.get("sha256") or "")
                prev_state[e["path"]] = e.get("state") or ""
    except Exception:
        pass          # unreadable receipt just means "no baseline" -- never fatal

# What each file ended as, for the receipt: path -> (state, carried baseline).
# A receipt that only said "version X" while files were skipped, kept or left in
# conflict made the project look fully on X (24hHotnewsAI: receipt 1.8.1, scripts
# older). State is per file, and the hash of a file this run did NOT install is
# never taken as the new baseline -- see the end of the script.
outcome = {}
unchanged = 0


def clean_stale_new(dest, rel):
    """A `<file>.new` is the installer's own marker for 'a shipped copy you have not
    adopted'. Once the file matches the shipped copy it is stale, and leaving it
    makes a resolved conflict look unresolved."""
    if os.path.exists(dest + ".new"):
        if not dry_run:
            os.remove(dest + ".new")
        print("  [CLEAN] %s.new (stale: the file now matches the shipped copy)" % rel)


def owned_glob(path):
    # Match full relative path AND bare filename, so "project-*" / "*.local.*"
    # apply at any depth without the rule author spelling out a prefix.
    return any(fnmatch.fnmatch(path, g) or fnmatch.fnmatch(os.path.basename(path), g)
               for g in own_globs)


def merge_json_map(disk_bytes, ship_bytes, map_key):
    """Field-level merge of a JSON object map (bundle-ownership merge_json_maps).

    Returns (ok, reason, text, stats). Writes nothing and prints nothing -- the
    caller decides -- so a status line can never end up inside the file.
    install.ps1 emits the identical bytes: json.dumps(indent=2,
    ensure_ascii=False) is the canonical form both installers agree on, because
    the merged file gets hashed into the receipt and two spellings of the same
    content would make the other installer report a hand-edit that never was.
    """
    try:
        disk = json.loads(disk_bytes.decode("utf-8"))
        if not isinstance(disk, dict):
            raise ValueError("not an object")
    except Exception:
        return (False, "could not parse your copy as JSON", None, None)
    try:
        ship = json.loads(ship_bytes.decode("utf-8"))
        if not isinstance(ship, dict):
            raise ValueError("not an object")
    except Exception:
        return (False, "could not parse the shipped copy as JSON", None, None)
    if not isinstance(ship.get(map_key), dict):
        return (False, "the shipped copy has no '%s' object" % map_key, None, None)

    ship_map = ship[map_key]
    disk_map = disk.get(map_key) if isinstance(disk.get(map_key), dict) else None
    st = {"added": [], "updated": 0, "yours": [], "overrides": [],
          "fields": 0, "entries": 0, "extra_top": []}

    out_map = {}
    for name, ship_entry in ship_map.items():
        if disk_map is None or name not in disk_map:
            out_map[name] = ship_entry
            st["added"].append(name)
            continue
        disk_entry = disk_map[name]
        if not isinstance(ship_entry, dict) or not isinstance(disk_entry, dict):
            # Not an object on one side -- nothing to merge field-wise, bundle wins.
            out_map[name] = ship_entry
            st["updated"] += 1
            continue
        entry = dict(ship_entry)
        kept_fields = 0
        for k, v in disk_entry.items():
            if k not in ship_entry:
                # The whole point: a field the bundle has no opinion about.
                entry[k] = v
                kept_fields += 1
            elif v != ship_entry[k]:
                st["overrides"].append("%s.%s" % (name, k))
        if kept_fields:
            st["fields"] += kept_fields
            st["entries"] += 1
        out_map[name] = entry
        st["updated"] += 1
    if disk_map is not None:
        for name, v in disk_map.items():
            if name not in ship_map:
                out_map[name] = v
                st["yours"].append(name)

    # Top level: the bundle owns its own keys (schema_version, generated_at...),
    # anything the project added beside them is theirs and rides along.
    root = {}
    for k, v in ship.items():
        root[k] = out_map if k == map_key else v
    for k, v in disk.items():
        if k not in ship:
            root[k] = v
            st["extra_top"].append(k)
    return (True, "", json.dumps(root, indent=2, ensure_ascii=False) + "\n", st)


def hook_matcher(e):
    """Identity of one hook matcher entry (bundle-ownership merge_hook_settings):
    the matcher STRING, "" when absent/null. None marks a malformed (non-object)
    entry, which can only pair with an equally malformed shipped one."""
    if not isinstance(e, dict):
        return None
    m = e.get("matcher", "")
    return "" if m is None else str(m)


def merge_hook_settings_file(disk_bytes, ship_bytes, hooks_key):
    """Matcher-entry merge of a Claude Code settings file (bundle-ownership
    merge_hook_settings). `hooks` is {event: [ {matcher, hooks: [...]}, ... ]},
    so neither the flat-map merge above nor the keyed-list conflict fits its
    shape. Shipped matcher entries update to the shipped version; entries and
    whole events only the project has survive; top-level keys the bundle ships
    stay the bundle's (a replaced project edit is NAMED by the caller); extra
    top-level keys ride along. Duplicate matchers pair by position -- the
    deterministic convention documented in bundle-ownership.yaml. Same contract
    as merge_json_map: returns (ok, reason, text, stats), writes and prints
    nothing, and emits the byte-identical text install.ps1 emits.
    """
    try:
        disk = json.loads(disk_bytes.decode("utf-8"))
        if not isinstance(disk, dict):
            raise ValueError("not an object")
    except Exception:
        return (False, "could not parse your copy as JSON", None, None)
    try:
        ship = json.loads(ship_bytes.decode("utf-8"))
        if not isinstance(ship, dict):
            raise ValueError("not an object")
    except Exception:
        return (False, "could not parse the shipped copy as JSON", None, None)
    if not isinstance(ship.get(hooks_key), dict):
        return (False, "the shipped copy has no '%s' object" % hooks_key, None, None)

    ship_hooks = ship[hooks_key]
    disk_hooks = disk.get(hooks_key) if isinstance(disk.get(hooks_key), dict) else None
    st = {"added": [], "updated": 0, "yours": [], "replaced": [],
          "extra_top": [], "top_wins": []}

    merged_hooks = {}
    for ev, ship_list in ship_hooks.items():
        if not isinstance(ship_list, list):
            ship_list = [ship_list]
        disk_list = None
        if disk_hooks is not None and isinstance(disk_hooks.get(ev), list):
            disk_list = disk_hooks[ev]
        if disk_list is None:
            # Event the project does not have (or holds malformed): shipped wins.
            merged_hooks[ev] = ship_list
            st["added"].extend("%s[%s]" % (ev, hook_matcher(se) or "") for se in ship_list)
            continue
        consumed = [False] * len(disk_list)
        out = []
        for se in ship_list:
            sm = hook_matcher(se)
            j = next((i for i in range(len(disk_list))
                      if not consumed[i] and hook_matcher(disk_list[i]) == sm), None)
            out.append(se)
            if j is None:
                st["added"].append("%s[%s]" % (ev, sm or ""))
            else:
                consumed[j] = True
                st["updated"] += 1
                if disk_list[j] != se:
                    st["replaced"].append("%s[%s]" % (ev, sm or ""))
        for i, de in enumerate(disk_list):
            # The whole point: an entry only the project has.
            if not consumed[i]:
                out.append(de)
                st["yours"].append("%s[%s]" % (ev, hook_matcher(de) or ""))
        merged_hooks[ev] = out
    if disk_hooks is not None:
        for ev, dl in disk_hooks.items():
            if ev not in ship_hooks:
                merged_hooks[ev] = dl
                st["yours"].extend("%s[%s]" % (ev, hook_matcher(de) or "")
                                   for de in (dl if isinstance(dl, list) else []))

    # Top level: shipped keys are the bundle's (hooks replaced by the merge
    # above); keys only the project has ride along.
    root = {}
    for k, v in ship.items():
        if k == hooks_key:
            root[k] = merged_hooks
            continue
        root[k] = v
        if k in disk and disk[k] != v:
            st["top_wins"].append(k)
    for k, v in disk.items():
        if k not in ship:
            root[k] = v
            st["extra_top"].append(k)
    return (True, "", json.dumps(root, indent=2, ensure_ascii=False) + "\n", st)


def list_keys(text, list_key, item_key):
    """Item keys of a keyed YAML list, by line scan -- only has to recognize the
    shape the bundle itself ships: `<list>:` then `  - <key>: value`."""
    keys, in_list = [], False
    for line in text.splitlines():
        if re.match(r"^%s:\s*$" % re.escape(list_key), line):
            in_list = True; continue
        if in_list and re.match(r"^[A-Za-z0-9_]+:", line):
            in_list = False; continue
        if in_list:
            m = re.match(r'^\s+-\s+%s:\s*"?([^"#]+?)"?\s*$' % re.escape(item_key), line)
            if m:
                keys.append(m.group(1).strip())
    return keys


# OS hook selection: the bundle ships settings.json (powershell hooks) and
# settings.posix.json (bash hooks). On this side of C7 parity the ACTIVE file
# must carry the bash variant, so wherever the loop below writes or merges
# .claude/settings.json the shipped side is the posix payload. Until v1.6.1
# this was a `cp -f` at the END of the script -- which, run with --force,
# clobbered the freshly merged settings.json and re-lost the project's own hook
# entries, the exact defect merge_hook_settings exists to prevent.
_posix = next((f for f in b["files"] if f["path"] == ".claude/settings.posix.json"), None)
posix_selected = False

for f in b["files"]:
    dest = safe_dest(target, f["path"])
    if f["path"] == ".claude/settings.json" and _posix is not None:
        data = base64.b64decode(_posix["b64"])
        posix_selected = True
    else:
        data = base64.b64decode(f["b64"])
    exists = os.path.exists(dest)
    ship_hash = sha_or_unknown(base64.b64decode(f["b64"]))   # what the receipt calls `sha256`
    # What a file this run does NOT install carries into the receipt as its
    # baseline: the LAST installed hash, never the hash of what is on disk now.
    carry = prev_hashes.get(f["path"]) or UNKNOWN

    # 1) Project-owned, by exact path or convention glob.
    if exists and (f["path"] in preserve or owned_glob(f["path"])):
        with open(dest, "rb") as fh:
            same = fh.read() == data
        if same:
            print("  [KEEP]  %s (yours; identical to shipped)" % f["path"])
            clean_stale_new(dest, f["path"])
            outcome[f["path"]] = ("kept", ship_hash)
        else:
            if not dry_run:
                with open(dest + ".new", "wb") as fh:
                    fh.write(data)
            print("  [KEEP]  %s (yours; shipped copy saved as %s.new)" % (f["path"], f["path"]))
            outcome[f["path"]] = ("kept", carry)
        kept += 1
        continue

    if exists:
        with open(dest, "rb") as fh:
            disk = fh.read()
        disk_hash = hashlib.sha256(disk).hexdigest()
        disk_forms = eol_hashes(disk)

        # 1b) Already what the bundle ships (byte-exact, or differing only in EOL/BOM
        # -- a core.autocrlf checkout). Nothing to write, nothing to decide, and
        # not a "skip": reporting it as skipped would make every re-run of a
        # current project look partial.
        if disk == data or norm_eol(disk) == norm_eol(data):
            print("  [SAME]  %s" % f["path"])
            clean_stale_new(dest, f["path"])
            outcome[f["path"]] = ("installed", None)
            unchanged += 1
            if f["path"] == ".claude/settings.json" and _posix is not None:
                posix_selected = True
            continue

        # 2) A JSON object map the project may have EXTENDED -- extra FIELDS on
        # entries the bundle ships, and/or entries of its own. Overwriting the
        # whole file is what erased one project's contract/timeout annotations
        # across all 62 registry tools (see merge_json_maps in
        # bundle-ownership.yaml). Merge per entry, per field instead.
        # Runs with or WITHOUT --force on purpose: the merge cannot lose a field
        # the bundle does not ship, and gating it behind --force would leave a
        # plain install with a registry that never learns about new tools --
        # which C3 turns into "unknown tool, denied by default" at run time.
        if f["path"] in merge_maps:
            mk = merge_maps[f["path"]]
            ok, reason, text, st = merge_json_map(disk, data, mk)
            if ok:
                if not dry_run:
                    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
                        fh.write(text)
                print("  [MERGE] %s (%s: %d added, %d updated, %d yours kept; %d project field(s) preserved on %d entry(ies))"
                      % (f["path"], mk, len(st["added"]), st["updated"], len(st["yours"]),
                         st["fields"], st["entries"]))
                if st["yours"]:
                    print("             kept yours: %s" % ", ".join(st["yours"]))
                if st["added"]:
                    print("             added by the bundle: %s" % ", ".join(st["added"]))
                if st["extra_top"]:
                    print("             kept your extra top-level key(s): %s" % ", ".join(st["extra_top"]))
                # Never silent: these are the only edits of theirs that did NOT
                # survive, so name every one (C10).
                if st["overrides"]:
                    print("             bundle value wins on %d field(s) you had changed: %s"
                          % (len(st["overrides"]), ", ".join(st["overrides"])))
                merges.append("%s: %d project field(s) on %d entry(ies), %d project-only entry(ies) kept"
                              % (f["path"], st["fields"], st["entries"], len(st["yours"])))
                merged += 1
                clean_stale_new(dest, f["path"])
                outcome[f["path"]] = ("installed", None)
                continue
            # Unparseable on either side, or the shipped copy lost the map: never
            # write a half-merged governance file. Say so and keep theirs.
            if not dry_run:
                with open(dest + ".new", "wb") as fh:
                    fh.write(data)
            msg = "%s: %s -- not merged" % (f["path"], reason)
            print("  [CONFLICT] %s" % msg)
            print("             kept yours; shipped copy is %s.new" % f["path"])
            conflicts.append(msg); kept += 1
            outcome[f["path"]] = ("conflict", carry)
            continue

        # 2b) Claude Code settings: hooks is {event: [matcher entries]}, a shape
        # the flat-map merge above cannot address. Overwriting wholesale is how
        # a project's own PreToolUse hook vanished with zero warning -- lost
        # enforcement that nothing reported (see merge_hook_settings in
        # bundle-ownership.yaml). Shipped matcher entries update, the project's
        # own entries/events and extra top-level keys survive. Runs with or
        # WITHOUT --force for the same reason as the map merge: it cannot drop
        # a project entry, and gating it would leave stale fleet hooks in place.
        if f["path"] in hook_settings:
            hk = hook_settings[f["path"]]
            ok, reason, text, st = merge_hook_settings_file(disk, data, hk)
            if ok:
                if not dry_run:
                    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
                        fh.write(text)
                print("  [MERGE] %s (%s: %d added, %d updated, %d yours kept; %d extra top-level key(s) kept)"
                      % (f["path"], hk, len(st["added"]), st["updated"], len(st["yours"]),
                         len(st["extra_top"])))
                if st["yours"]:
                    print("             kept your hook entry(ies): %s" % ", ".join(st["yours"]))
                if st["added"]:
                    print("             added by the bundle: %s" % ", ".join(st["added"]))
                if st["extra_top"]:
                    print("             kept your extra top-level key(s): %s" % ", ".join(st["extra_top"]))
                # Never silent: the next two lines name every project edit that
                # did NOT survive (C10).
                if st["replaced"]:
                    print("             bundle version replaces %d hook entry(ies) you had edited: %s"
                          % (len(st["replaced"]), ", ".join(st["replaced"])))
                if st["top_wins"]:
                    print("             bundle value wins on top-level key(s) you had changed: %s (hold local overrides in .claude/settings.local.json)"
                          % ", ".join(st["top_wins"]))
                merges.append("%s: %d project hook entry(ies) kept, %d extra top-level key(s) kept"
                              % (f["path"], len(st["yours"]), len(st["extra_top"])))
                merged += 1
                clean_stale_new(dest, f["path"])
                outcome[f["path"]] = ("installed", None)
                if f["path"] == ".claude/settings.json" and _posix is not None:
                    posix_selected = True
                continue
            # Unparseable, or the shipped copy lost its hooks object: never
            # write half-merged hook config -- a wrong guess here is silently
            # missing enforcement. Say so and keep theirs.
            if not dry_run:
                with open(dest + ".new", "wb") as fh:
                    fh.write(data)
            msg = "%s: %s -- not merged" % (f["path"], reason)
            print("  [CONFLICT] %s" % msg)
            print("             kept yours; shipped copy is %s.new" % f["path"])
            conflicts.append(msg); kept += 1
            outcome[f["path"]] = ("conflict", carry)
            continue

        # 3) A keyed list the project may have EXTENDED. Overwriting is right for
        # the shipped entries and destructive for the project's own, so when the
        # project has entries the bundle does not ship, stop and name them.
        # Deliberately a conflict, not an auto-merge: guessing where to splice a
        # YAML item risks a broken pipeline that still validates (C10).
        if f["path"] in keyed_lists:
            lk, ik = keyed_lists[f["path"]].split(":", 1)
            try:
                mine = list_keys(disk.decode("utf-8"), lk, ik)
                ship = list_keys(data.decode("utf-8"), lk, ik)
            except UnicodeDecodeError:
                mine = ship = []
            extra = [k for k in mine if k not in ship]
            if extra:
                if not dry_run:
                    with open(dest + ".new", "wb") as fh:
                        fh.write(data)
                msg = ("%s: your %s has %d entry(ies) the bundle does not ship -- %s"
                       % (f["path"], lk, len(extra), ", ".join(extra)))
                print("  [CONFLICT] %s" % msg)
                print("             kept yours; shipped copy is %s.new -- carry those entries over by hand" % f["path"])
                conflicts.append(msg); kept += 1
                outcome[f["path"]] = ("conflict", carry)
                continue

        # 4) A bundle-owned file the project hand-edited since the last install.
        # Only claimable when a baseline exists; with no receipt we cannot tell an
        # edit from a first install, and guessing would cry wolf or hide it.
        base = prev_hashes.get(f["path"])
        if base and base not in disk_forms:
            # Hand-edited. If the bundle has not moved on since the last run there is
            # nothing to adopt: keep the edit, no .new, no conflict. (Not when the
            # last run already left this file in conflict -- the receipt's shipped
            # hash then names the copy that was REFUSED, so "unchanged" would be
            # measured against the very bytes the edit is in conflict with.)
            if prev_state.get(f["path"]) != "conflict" and prev_ship.get(f["path"]) == ship_hash:
                print("  [KEEP]  %s (yours; edited since the last install, the bundle has not changed it)" % f["path"])
                kept += 1
                outcome[f["path"]] = ("kept", carry)
                continue
            if not dry_run:
                with open(dest + ".new", "wb") as fh:
                    fh.write(data)
            msg = "%s: edited by hand since the last install (sha differs from the recorded baseline)" % f["path"]
            print("  [CONFLICT] %s" % msg)
            print("             kept yours; shipped copy is %s.new" % f["path"])
            conflicts.append(msg); kept += 1
            outcome[f["path"]] = ("conflict", carry)
            continue

        if not force:
            print("  [SKIP] %s (exists; use --force to overwrite)" % f["path"]); skipped += 1
            outcome[f["path"]] = ("skipped", carry)
            continue

    if not dry_run:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(data)
    if f["path"] == ".claude/settings.json" and _posix is not None:
        posix_selected = True
    print("  [WRITE] %s" % f["path"]); written += 1
    clean_stale_new(dest, f["path"])
    outcome[f["path"]] = ("installed", None)

# Conflicts are listed again by NAME: a count alone reads as "all fine", and the
# whole point of this pass is that some files were deliberately NOT updated.
print("")
print("[summary] written=%d  merged=%d  kept=%d  skipped=%d  conflicted=%d  unchanged=%d" % (written, merged, kept, skipped, len(conflicts), unchanged))
if merges:
    print("[summary] merged in place -- your fields survived:")
    for m in merges:
        print("  - %s" % m)
if conflicts:
    print("[summary] NOT updated -- resolve these by hand:")
    for c in conflicts:
        print("  - %s" % c)
if dry_run:
    print("[summary] DRY RUN -- nothing was written. Re-run without --dry-run to apply.")
    raise SystemExit(0)

# Install receipt: what this run did to EACH file, not just which bundle it came
# from. `version` and `content_hash` name the bundle this run was driven by; they
# are not a claim that every file in it landed -- `status` and each file's `state`
# are. (A receipt that said only "version X" while files were skipped or left in
# conflict is how 24hHotnewsAI read 1.8.1 over scripts that were older.)
#
#   installed  the file on disk is what this run put there (written, merged, or
#              already identical) -- `installed_sha256` is its hash
#   kept       project-owned, or hand-edited while the bundle did not change it
#   conflict   hand-edited AND the bundle changed it: yours kept, shipped copy in
#              <file>.new
#   skipped    exists and no --force
# For every state but "installed", `installed_sha256` is the baseline CARRIED from
# the previous receipt ("unknown" when there is none) -- never the hash of the
# bytes on disk, which would turn the next run's "you edited this" into "you did
# not". `sha256` keeps its meaning (the shipped bytes; the uninstaller reads it).
import hashlib, datetime, json as _json
entries = []
counts = {"installed": 0, "kept": 0, "conflict": 0, "skipped": 0}
for f in b["files"]:
    st, base = outcome[f["path"]]
    counts[st] += 1
    if st == "installed":
        with open(safe_dest(target, f["path"]), "rb") as fh:
            base = sha_or_unknown(fh.read())
    entries.append({"path": f["path"], "sha256": sha_or_unknown(base64.b64decode(f["b64"])),
                    "installed_sha256": base, "state": st})
receipt = {
    "name": b["name"], "version": b["version"], "content_hash": b["content_hash"],
    "installed_at": datetime.datetime.now().astimezone().isoformat(),
    "status": "partial" if (counts["conflict"] or counts["skipped"]) else "complete",
    "counts": counts,
    # Recorded so a maintainer can SEE which files this install treats as
    # project-owned, instead of having to read the installer to find out.
    "preserve": sorted(preserve),
    "files": entries,
}
rdir = os.path.join(target, ".harness"); os.makedirs(rdir, exist_ok=True)
with open(os.path.join(rdir, ".bundle-manifest.json"), "w", encoding="utf-8") as fh:
    _json.dump(receipt, fh, indent=2)
if receipt["status"] == "partial":
    print("[summary] receipt status: PARTIAL -- %d conflict(s), %d skipped: the receipt records each file's state, "
          "it does not claim v%s is fully applied." % (counts["conflict"], counts["skipped"], b["version"]))
if posix_selected:
    print("[install] selected POSIX (bash) hooks for .claude/settings.json")
print("[install] done: %d written, %d merged, %d skipped, %d kept (project-owned). Integrity OK (%s)." % (written, merged, skipped, kept, b["content_hash"]))
PY
} | "$PY" - "$BUNDLE" "$TARGET" "$FORCE" "$DRY_RUN" "$OWN_RULES"

# A dry run has to stop HERE. Everything below scaffolds real files -- portal-sync
# stubs, buglist.md, the context store, project identity, guide merging -- so
# letting it continue would make --dry-run write exactly the things the flag
# exists to avoid, which is worse than not having the flag.
if [[ "$DRY_RUN" == "1" ]]; then
  echo "[install] dry run complete -- no scaffolding, identity or guide changes were applied."
  exit 0
fi

# --- Exec bit on shipped .sh files (C7 parity meets git). A bundle installed
# and committed from Windows ships every .sh as mode 100644 -- NTFS has no exec
# bit to record -- and the first run on Linux prod dies with "Permission
# denied". Two halves, both needed:
#   1. chmod +x fixes THIS checkout (a clone inherits only what git recorded);
#   2. the git INDEX bit (update-index --chmod=+x) is what a commit records and
#      every later clone inherits. --add covers a first install where the files
#      are not yet tracked; with core.filemode=false a later `git add` keeps
#      the recorded index mode instead of resetting it.
# Best-effort: not a git work tree just means half 2 does not apply -- but that
# is SAID, because the failure mode is silent (C10).
SH_LIST=()
while IFS= read -r rel; do
  rel="${rel%$'\r'}"   # Windows python emits CRLF; a stowaway \r fails every -f test below
  [[ -n "$rel" && -f "$TARGET/$rel" ]] && SH_LIST+=("$rel")
done < <("$PY" -c 'import json, sys
b = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(f["path"] for f in b["files"] if f["path"].endswith(".sh")))' "$BUNDLE")
if [[ ${#SH_LIST[@]} -eq 0 ]]; then
  # Never silent (C10): an empty list here means the bundle ships no .sh files
  # at all, or none landed on disk -- either way the operator should see it.
  echo "[execbit] no shipped .sh files found on disk -- nothing to chmod/stamp"
fi
if [[ ${#SH_LIST[@]} -gt 0 ]]; then
  for rel in "${SH_LIST[@]}"; do
    chmod +x "$TARGET/$rel" || echo "[execbit] WARNING: chmod +x failed on $rel"
  done
  echo "[execbit] chmod +x on ${#SH_LIST[@]} shipped .sh file(s)"
  if command -v git >/dev/null 2>&1 && [[ "$(git -C "$TARGET" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]]; then
    if git -C "$TARGET" update-index --add --chmod=+x -- "${SH_LIST[@]}" 2>/dev/null; then
      echo "[execbit] git index +x (mode 100755) recorded on ${#SH_LIST[@]} .sh file(s) -- survives commits, including from Windows checkouts"
    else
      echo "[execbit] WARNING: git update-index --chmod=+x failed -- the filesystem bit is set, but a commit from a filemode-less checkout may still ship mode 100644"
    fi
  else
    echo "[execbit] target is not a git work tree -- filesystem +x only; the index bit applies once the project is under git"
  fi
fi

# --- Portal-sync scaffold: create the two files a newcomer would otherwise have
# to hand-author, at the right location, ready to edit. NEVER overwrite existing
# ones (a real key / configured project_id is preserved). push-telemetry.sh reads
# exactly these two files to sync telemetry to the Portal. ---
mkdir -p "$TARGET/.harness"
SYNC_JSON="$TARGET/.harness/portal-sync.json"
if [[ ! -f "$SYNC_JSON" ]]; then
  cat > "$SYNC_JSON" <<'JSON'
{
  "_README": "Fill portal_url and project_id from your Control Portal (open the Project, then Settings, then Reveal ingest key). Next, paste the ingest key into portal-sync.key in THIS same .harness folder. This file is shared by every clone and is meant to be committed: it holds NO per-person or per-machine field (your email goes in .harness/local/checkout.json via set-member-email). Set pdp_enforce to true to make the PreToolUse hook consult the Portal PDP (H4 outbound allowlist, H5 approval, H3 release gate) -- leave false to keep it off. You may delete this _README line.",
  "portal_url": "https://YOUR-PORTAL-DOMAIN",
  "project_id": "PASTE-PROJECT-ID-HERE",
  "pdp_enforce": false
}
JSON
  echo "[scaffold] created .harness/portal-sync.json  -> EDIT portal_url + project_id"
else
  echo "[scaffold] .harness/portal-sync.json already exists -> kept"
fi
SYNC_KEY="$TARGET/.harness/portal-sync.key"
if [[ ! -f "$SYNC_KEY" ]]; then
  : > "$SYNC_KEY"
  echo "[scaffold] created empty .harness/portal-sync.key -> PASTE ingest key here (1 line)"
else
  echo "[scaffold] .harness/portal-sync.key already exists -> kept"
fi

# --- Buglist scaffold (M6): living buglist.md at project root from the shipped
# template; never overwrite an existing one. ---
BUG_FILE="$TARGET/buglist.md"
BUG_TMPL="$TARGET/.harness/templates/buglist.md"
if [[ ! -f "$BUG_FILE" && -f "$BUG_TMPL" ]]; then
  sed "s/<PROJECT>/$(basename "$TARGET")/g" "$BUG_TMPL" > "$BUG_FILE"
  echo "[scaffold] created buglist.md (log every bug here -- see rule in the file)"
elif [[ -f "$BUG_FILE" ]]; then
  echo "[scaffold] buglist.md already exists -> kept"
fi

# --- Agent Pack scaffold (v1.6.0, parity with install.ps1): auto-generate
# agent-config.yaml by detecting the stack, so review->fix->test works from day
# one. Never overwrite (project-owned). Stack undetected -> write the annotated
# sample so a human fills it in rather than a wrong command failing silently.
AC_FILE="$TARGET/.harness/control/agent-config.yaml"
AC_SAMPLE="$TARGET/.harness/templates/agent-pack/agent-config.yaml.sample"
if [[ ! -f "$AC_FILE" && -f "$AC_SAMPLE" ]]; then
  unit=""; full=""; detected=""
  if [[ -f "$TARGET/package.json" ]]; then
    if grep -q '"vitest"' "$TARGET/package.json"; then unit="npx vitest related --run {files}"; full="npx vitest run"; detected="vitest"
    elif grep -q '"jest"' "$TARGET/package.json"; then unit="npx jest --findRelatedTests {files}"; full="npx jest"; detected="jest"; fi
  fi
  if [[ -z "$detected" && ( -f "$TARGET/pyproject.toml" || -f "$TARGET/pytest.ini" ) ]]; then
    unit="pytest --testmon -q"; full="pytest -q"; detected="pytest"; fi
  if [[ -z "$detected" && -f "$TARGET/composer.json" ]]; then
    unit="php artisan test --filter {files}"; full="php artisan test"; detected="phpunit"; fi
  if [[ -n "$detected" ]]; then
    cat > "$AC_FILE" <<YAML
# Agent Pack project config -- AUTO-GENERATED by installer (detected: $detected).
# Tune to taste. Project-owned: re-install never overwrites this.
# Schema: .harness/schemas/agent-config.schema.json
test:
  unit_related_cmd: "$unit"
  full_suite_cmd:   "$full"
  integration_smoke: []
impact:
  force_full_test_on:
    - "**/migrations/**"
    - "**/schema.*"
    - "**/middleware.*"
    - "package-lock.json"
    - "composer.lock"
    - "poetry.lock"
YAML
    echo "[scaffold] agent-config.yaml generated (detected $detected test runner)"
  else
    cp "$AC_SAMPLE" "$AC_FILE"
    echo "[scaffold] agent-config.yaml: stack not detected -> wrote sample to fill in"
  fi
fi

# --- CI gates scaffold (--with-ci-gates, parity with install.ps1): copy the
# shipped workflow templates into .github/. Opt-in, because adding workflow files
# changes what runs on every push. Never overwrites an existing workflow.
if [[ "$WITH_CI_GATES" == "1" ]]; then
  CI_SRC="$TARGET/.harness/templates/ci"
  if [[ ! -d "$CI_SRC" ]]; then
    echo "[ci] no templates/ci in this bundle -- nothing to copy"
  else
    mkdir -p "$TARGET/.github/workflows"
    _ci_copy() {  # $1=template name  $2=destination
      [[ -f "$CI_SRC/$1" ]] || return 0
      if [[ -f "$2" ]]; then echo "[ci] $(basename "$2") already exists -> kept"; return 0; fi
      cp "$CI_SRC/$1" "$2"
      echo "[ci] wrote $(basename "$2")"
    }
    _ci_copy "harness-gate.yml.template" "$TARGET/.github/workflows/harness-gate.yml"
    _ci_copy "tests.yml.template"        "$TARGET/.github/workflows/tests.yml"
    _ci_copy "CODEOWNERS.template"       "$TARGET/.github/CODEOWNERS"
    # Substitute the owner handle so CODEOWNERS is usable as written. No owner in
    # the contract -> leave the placeholder visible; inventing a handle silently
    # routes reviews to nobody, which is worse than an obvious TODO.
    if [[ -f "$TARGET/.github/CODEOWNERS" ]]; then
      OWNER="$(grep -oE '^[[:space:]]*owner:[[:space:]]*"?@?[A-Za-z0-9_-]+' "$TARGET/contracts/project.yaml" 2>/dev/null \
               | sed -E 's/.*owner:[[:space:]]*"?@?//' | head -1 || true)"
      if [[ -n "$OWNER" ]]; then
        sed -i.bak "s/@your-handle-here/@$OWNER/g" "$TARGET/.github/CODEOWNERS" && rm -f "$TARGET/.github/CODEOWNERS.bak"
      else
        echo "[ci] CODEOWNERS: no owner in contracts/project.yaml -- left @your-handle-here to fill in"
      fi
    fi
    echo "[ci] NOTE: CODEOWNERS only enforces when branch protection requires Code Owner review (C10)."
    echo "[ci] NOTE: tests.yml ships with every stack block commented -- uncomment yours or it fails by design."
  fi
fi

# C5: never commit the ingest key. Ensure the target project's .gitignore
# ignores it (idempotent -- add the line only if missing).
GI="$TARGET/.gitignore"
if ! grep -qF ".harness/portal-sync.key" "$GI" 2>/dev/null; then
  printf '\n# Harness Portal ingest key -- secret, never commit (C5)\n.harness/portal-sync.key\n' >> "$GI"
  echo "[scaffold] added portal-sync.key to .gitignore (C5)"
fi

# Portal v2 P1 1.7: per-machine state (checkout credential, member_email) lives in .harness/local/.
# That folder must never reach git -- ignore it in the target project (idempotent).
if ! grep -qE '^/?\.harness/local/?[[:space:]]*$' "$GI" 2>/dev/null; then
  printf '\n# Harness per-machine state (checkout credential, member_email) -- never commit\n.harness/local/\n' >> "$GI"
  echo "[scaffold] added .harness/local/ to .gitignore (machine-local state)"
fi

# The legacy-guide migration below writes a one-time '<file>.pre-migration.bak'.
# That is a local safety net, not project content -- ignore it so it does not
# show up as untracked noise in every project the migration touched.
if ! grep -qF "*.pre-migration.bak" "$GI" 2>/dev/null; then
  printf '\n# One-time backup written when a legacy guide block is migrated\n*.pre-migration.bak\n' >> "$GI"
  echo "[scaffold] added *.pre-migration.bak to .gitignore"
fi

# The ledger's append lock (evidence-ledger: byte-range lock on this file) is
# runtime state, like the chain itself -- never project content.
if ! grep -qF ".harness/ledger/chain.lock" "$GI" 2>/dev/null; then
  printf '\n# Harness ledger append lock - runtime state\n.harness/ledger/chain.lock\n' >> "$GI"
  echo "[scaffold] added ledger chain.lock to .gitignore"
fi

# `<file>.new` is the installer's marker for "a shipped copy you have not adopted"
# (a project-owned or conflicted file). It is a local to-do, not project content:
# committing one ships the conflict to everybody and to the next checkout.
if ! grep -qE '^\*\.new[[:space:]]*$' "$GI" 2>/dev/null; then
  printf '\n# Shipped copies the installer leaves beside a file you own or edited - resolve, then delete\n*.new\n' >> "$GI"
  echo "[scaffold] added *.new to .gitignore"
fi

# A project that runs Prettier over the repo reformats the bundle's own files (PS
# parity: install.ps1). Only when the project uses Prettier; one marker line keeps
# this idempotent.
USES_PRETTIER=0
for f in "$TARGET"/.prettierrc "$TARGET"/.prettierrc.* "$TARGET"/prettier.config.*; do
  [ -e "$f" ] && USES_PRETTIER=1
done
[ "$USES_PRETTIER" = 0 ] && [ -f "$TARGET/package.json" ] && grep -q '"prettier"' "$TARGET/package.json" && USES_PRETTIER=1
PI="$TARGET/.prettierignore"
PI_MARKER="# harness-bundle: files owned by the governance bundle"
if [ "$USES_PRETTIER" = 1 ] && ! grep -qF "$PI_MARKER" "$PI" 2>/dev/null; then
  printf '\n%s\n%s\n' "$PI_MARKER" "# Reformatting them breaks the bundle integrity check and can change what they mean." >> "$PI"
  printf '%s\n' .harness/ tools/harness-bundle/ contracts/ .claude/agents/ .claude/skills/ \
    .claude/settings.json .claude/settings.posix.json CLAUDE.harness.md >> "$PI"
  echo "[scaffold] project uses Prettier -- added the bundle's paths to .prettierignore"
fi

# --- H1 scaffold: build the context pointer store so a freshly-onboarded project
# satisfies its own context contract right away (the policy-ci suite asserts it,
# and the release gate would otherwise block until the first session ran the
# hook). Best-effort: a failure here must never fail the install.
CTX_BUILD="$TARGET/.harness/scripts/bash/harness-context-build.sh"
CTX_STORE="$TARGET/.harness/context/pipeline-context.yaml"
if [ -f "$CTX_BUILD" ] && [ ! -f "$CTX_STORE" ]; then
  if HARNESS_ROOT="$TARGET" bash "$CTX_BUILD" >/dev/null 2>&1 && [ -f "$CTX_STORE" ]; then
    echo "[scaffold] built .harness/context/pipeline-context.yaml (H1)"
  else
    echo "[scaffold] could not build the H1 pointer store (non-fatal)"
  fi
fi

# --- Project identity + governance projection (--merge-guides) ---
# ONE canonical text (CLAUDE.harness.md) -> every agent-guide file the project
# uses, as a DELIMITED managed block, so re-installing refreshes only that block
# and never touches what the project wrote around it.
{ emit_common_py; cat <<'PY'
target, do_guides = sys.argv[1], sys.argv[2] == "1"
pname, pdesc, force_id = sys.argv[3], sys.argv[4], sys.argv[5] == "1"

# ---- identity: patch only the two scalars inside the `project:` block --------
if pname:
    if not pdesc:
        pdesc = pname
    contract = os.path.join(target, "contracts", "project.yaml")
    if not os.path.isfile(contract):
        print("[identity] contracts/project.yaml not found -- skipped")
    else:
        lines = open(contract, encoding="utf-8").read().split("\n")
        cur, inp = "", False
        for ln in lines:
            if re.match(r"^project:\s*$", ln):
                inp = True; continue
            if inp:
                if re.match(r"^\S", ln): break
                m = re.match(r"^\s+name:\s*(.*)$", ln)
                if m: cur = m.group(1).strip().strip('"')
        # A name starting with "-" is never legitimate (it can only come from an
        # argument-binding slip), so treat it as unclaimed and let a re-run fix it.
        placeholder = cur in ("", "harness-toolkit", "my-project") or cur.startswith("-")
        if not force_id and not placeholder:
            print("[identity] kept existing project name '%s' (use --force-identity to overwrite)" % cur)
        else:
            out, inp, changed = [], False, False
            for ln in lines:
                if re.match(r"^project:\s*$", ln):
                    inp = True; out.append(ln); continue
                if inp:
                    if re.match(r"^\S", ln):
                        inp = False
                    else:
                        m = re.match(r"^(\s+)name:\s*", ln)
                        if m:
                            out.append('%sname: "%s"' % (m.group(1), pname)); changed = True; continue
                        m = re.match(r"^(\s+)description:\s*", ln)
                        if m:
                            out.append('%sdescription: "%s"' % (m.group(1), pdesc)); changed = True; continue
                out.append(ln)
            if changed:
                open(contract, "w", encoding="utf-8", newline="\n").write("\n".join(out))
                print("[identity] contracts/project.yaml -> name/description = '%s'" % pname)
            else:
                print("[identity] could not find name/description under 'project:' -- skipped")

# ---- guides: project the common governance text -----------------------------
if do_guides:
    src = os.path.join(target, "CLAUDE.harness.md")
    if not os.path.isfile(src):
        print("[guides] CLAUDE.harness.md not found in target -- skipping")
        sys.exit(0)
    gov = open(src, encoding="utf-8").read().strip()

    # C2: the target list is data (casan-policies governance.guide_targets).
    targets, policy = [], os.path.join(target, ".harness", "control", "casan-policies.yaml")
    if os.path.isfile(policy):
        inb = False
        for ln in open(policy, encoding="utf-8-sig"):
            ln = ln.rstrip("\n")
            if re.match(r"^\s*guide_targets:\s*(#.*)?$", ln):
                inb = True; continue
            if inb:
                if re.match(r"^\s*#", ln): continue
                m = re.match(r"^\s*-\s*(.+?)\s*$", ln)
                if m:
                    v = re.sub(r"\s+#.*$", "", m.group(1)).strip().strip('"').strip("'")
                    if v: targets.append(v)
                elif ln.strip():
                    break
    if not targets:
        targets = ["CLAUDE.md", "AGENTS.md", ".github/copilot-instructions.md"]

    BEGIN, END = "<!-- BEGIN harness-governance -->", "<!-- END harness-governance -->"
    note = ("<!-- standard-governance - MANAGED BLOCK. Edits inside are replaced on the next "
            "install; put your own project rules OUTSIDE this block. -->")
    block = "%s\n%s\n\n%s\n\n%s" % (BEGIN, note, gov, END)
    for rel in targets:
        p = safe_dest(target, rel)
        os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
        if not os.path.exists(p):
            open(p, "w", encoding="utf-8", newline="\n").write(block + "\n")
            print("[guides] created %s" % rel); continue
        cur = open(p, encoding="utf-8").read()
        # rfind for the closing marker: if the governance text (or the project's
        # own notes) mentions the marker inside the block, a first-match search
        # would cut the block short and leave orphaned text on every refresh.
        bi, ei = cur.find(BEGIN), cur.rfind(END)
        if bi >= 0 and ei > bi:
            open(p, "w", encoding="utf-8", newline="\n").write(cur[:bi] + block + cur[ei + len(END):])
            print("[guides] refreshed managed block in %s" % rel)
        elif re.search(r"<!--\s*harness:merged\s*-->", cur):
            # Pre-1.5.0 merge appended the text with only a start sentinel, running
            # to EOF, so it could never be refreshed. Keep everything BEFORE the
            # sentinel (the project's own content) and re-emit a managed block.
            # A one-time .bak keeps the conversion reversible.
            mm = (re.search(r"(?m)^[ \t]*-{3,}[ \t]*\r?\n<!--\s*harness:merged\s*-->", cur)
                  or re.search(r"<!--\s*harness:merged\s*-->", cur))
            bak = p + ".pre-migration.bak"
            if not os.path.exists(bak):
                open(bak, "w", encoding="utf-8", newline="").write(cur)
            pre = cur[:mm.start()].rstrip()
            open(p, "w", encoding="utf-8", newline="\n").write(pre + "\n\n---\n\n" + block + "\n")
            print("[guides] migrated legacy block in %s -> managed block (backup: %s.pre-migration.bak)" % (rel, rel))
        else:
            open(p, "w", encoding="utf-8", newline="\n").write(cur.rstrip() + "\n\n---\n\n" + block + "\n")
            print("[guides] appended governance to existing %s (your content untouched)" % rel)
PY
} | "$PY" - "$TARGET" "$MERGE_CLAUDE" "$PROJECT_NAME" "$PROJECT_DESC" "$FORCE_IDENTITY"

# --- OS hook selection (macOS/Linux) now happens INSIDE the install loop: the
# python step substitutes the settings.posix.json payload wherever it writes or
# merges .claude/settings.json, so the bash variant is selected file-by-file.
# The old end-of-script `cp -f settings.posix.json settings.json` is gone on
# purpose: run with --force it re-clobbered the freshly merged settings.json
# and lost the project's own hook entries -- the exact defect
# merge_hook_settings (bundle-ownership.yaml) exists to prevent.

# --- Re-stamp the receipt with what this install actually LEFT ON DISK ---------
# The baseline for "did the project hand-edit a bundle-owned file?" must be the
# state the installer finished in, not the bytes the bundle shipped. Steps above
# deliberately modify files after writing them -- the guide merge appends a managed
# block, settings.posix.json is copied over settings.json, identity is stamped --
# so comparing against the shipped hash flagged .claude/settings.json as
# hand-edited on the very next run. That false positive would train a maintainer to
# ignore conflict reports, which costs more than having no detection at all.
#
# `sha256` keeps its original meaning (the shipped bytes) because the uninstaller
# uses it to tell a pristine file from a user-edited one; `installed_sha256` is
# added alongside, and the tamper check prefers it when present.
{ emit_common_py; cat <<'PY'
import json
target = sys.argv[1]
p = os.path.join(target, ".harness", ".bundle-manifest.json")
if not os.path.exists(p):
    raise SystemExit(0)
r = json.load(open(p, encoding="utf-8-sig"))
for e in (r.get("files") or []):
    # Only a file this run INSTALLED has a hash worth re-reading. The others keep
    # the baseline phase 1 carried over: re-hashing a conflicted or kept file here
    # would make the hand edit the new baseline.
    if e.get("state", "installed") != "installed":
        continue
    fp = safe_dest(target, e["path"])
    ih = UNKNOWN
    if os.path.exists(fp):
        with open(fp, "rb") as fh:
            ih = sha_or_unknown(fh.read())
    e["installed_sha256"] = ih
with open(p, "w", encoding="utf-8") as fh:
    json.dump(r, fh, indent=2)
PY
} | "$PY" - "$TARGET" || echo "[receipt] WARNING: could not re-stamp installed hashes; next run may report false conflicts"
