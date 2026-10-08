#!/usr/bin/env python3
"""policy-ci -- the regression suite the CASAN evaluation layer requires.

`.harness/control/casan-policies.yaml` declares
`evaluation.regression_suites_required` and gates a release on those suites
passing. This is the bundle's reference implementation of `policy-ci`: it
enforces the governance conventions the constitution states (C2/C4/C5/C8/C10)
against the ACTUAL policy files, so config drift fails here instead of being
discovered at a gateway.

Deliberately generic -- every check reads the project's own policy files, so it
is meaningful in any project the bundle is dropped into. No project paths are
hardcoded.

Dependencies: stdlib. PyYAML is used when available; without it the YAML-only
checks report as SKIPPED rather than silently passing (C10 -- never fabricate a
green run).

Reporting: prints counts in the format `harness-eval` parses ("Passed : N"), so
the eval runner stays the single writer of test-reports.jsonl.

Usage:  python harness_policy_check.py <repo_root>
Exit:   0 when nothing failed, 1 on any failure (usable directly as a CI gate).
"""
import glob
import json
import os
import re
import sys

try:
    import yaml  # type: ignore
    _HAS_YAML = True
except Exception:  # pragma: no cover - environment dependent
    _HAS_YAML = False

PASSED, FAILED, SKIPPED, WARNED = [], [], [], []


def ok(name):
    PASSED.append(name)


def fail(name, why):
    FAILED.append("%s: %s" % (name, why))


def skip(name, why):
    SKIPPED.append("%s: %s" % (name, why))


def warn(name, why):
    """Something true and worth fixing that is NOT breaking anything today.

    Added because a check went out claiming "every reader fails on it" when
    every reader in this system opens with utf-8-sig and copes. Forcing that
    into fail() would have been a red build over a latent hazard; forcing it
    into ok() would have hidden it. Overstating a consequence is the same
    category of defect as missing one (C14), so the vocabulary gained the level
    the finding actually needed.

    Warnings do NOT fail the suite. `harness-eval` parses Passed/Failed/Skipped
    by anchored label, so the extra count line below is ignored by the release
    gate rather than breaking it."""
    WARNED.append("%s: %s" % (name, why))


def load(path):
    with open(path, encoding="utf-8-sig") as f:
        text = f.read()
    if path.endswith(".json"):
        return json.loads(text)
    if not _HAS_YAML:
        raise RuntimeError("PyYAML not installed")
    return yaml.safe_load(text)


def control_files(control):
    if not os.path.isdir(control):
        return []
    return sorted(
        os.path.join(control, n)
        for n in os.listdir(control)
        if os.path.splitext(n)[1] in (".json", ".yaml", ".yml")
    )


def evidence(items, n=8):
    """Cap a FAIL's evidence list. The existing checks stop at a handful
    (`leak_model[:5]`) for the same reason: a failure line carrying 40 paths is
    scrolled past, and a check nobody reads is a check nobody acts on."""
    items = list(items)
    if len(items) <= n:
        return "; ".join(items)
    return "; ".join(items[:n]) + "; (+%d more)" % (len(items) - n)


# Vendor trees, build output and VCS metadata. Pruning them is not cosmetic:
# the file-shape checks below walk the WHOLE project (see walk_ext), and a
# consuming project's node_modules alone carries thousands of .sh we neither
# own nor can fix.
# The first five match the set the plane check already walks with; the rest are
# unambiguous vendor/tooling trees. Names that a project might plausibly use for
# its OWN sources (env/, target/) are deliberately absent -- pruning one of those
# would hide a real CRLF script, which is a silent pass, the worst outcome here.
PRUNE_DIRS = {"node_modules", "__pycache__", ".venv", "dist", "build",
              ".git", "venv", ".vite", ".next", ".pytest_cache", ".mypy_cache",
              "vendor", "site-packages", ".tox", ".gradle"}


# Test trees, by directory name or by file name. Both forms are needed: pytest
# finds `tests/foo.py` and `src/pkg/test_foo.py` alike, and jest finds
# `__tests__/x.ts` and `x.spec.ts`. Used only by the plane checks, which ask
# what the SHIPPED product does -- never by the CRLF/BOM checks, where a test
# script is as broken as any other file.
_TEST_DIRS = {"tests", "test", "spec", "specs", "__tests__", "e2e", "testing"}
_TEST_FILE = re.compile(
    r"(^|[\\/])(conftest\.py|test_[^\\/]+|[^\\/]+_test\.[a-z]+"
    r"|[^\\/]+\.(test|spec)\.[a-z]+)$", re.I)


def is_test_path(rel):
    """True if `rel` (a path relative to the repo root) is test code."""
    parts = rel.replace("\\", "/").split("/")
    return any(p.lower() in _TEST_DIRS for p in parts[:-1]) or bool(_TEST_FILE.search(rel))


def walk_ext(root, exts):
    """Every file under `root` with one of `exts`, vendor/VCS trees pruned.

    Deliberately project-wide rather than scoped to `.harness/`: the CRLF and
    BOM defects below arrive through the CONSUMING project's own checkout, so a
    scan limited to bundle-installed paths would miss the `entrypoint.sh` that
    is what actually crash-loops the container.

    Known blind spot: a shipped script that lives under a pruned name (a
    hand-written `build/entrypoint.sh`) is not seen."""
    found = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in PRUNE_DIRS]
        # A nested `.git` means a submodule, a vendored checkout or an agent
        # worktree -- a different repo, governed by its own .gitattributes.
        # Counting it here double-reports this project's own files under a path
        # nobody can fix from here.
        dirs[:] = [d for d in dirs
                   if not os.path.exists(os.path.join(dirpath, d, ".git"))]
        for fn in files:
            if os.path.splitext(fn)[1].lower() in exts:
                found.append(os.path.join(dirpath, fn))
    return sorted(found)


def read_bytes(path, limit=None):
    try:
        with open(path, "rb") as f:
            return f.read() if limit is None else f.read(limit)
    except Exception:
        return b""


def lines_over_limit(path, limit, chunk=1 << 20):
    """(lineno, byte_len) for every line of `path` longer than `limit` bytes.

    Streamed in fixed-size chunks; never materialises a line. The entries this
    hunts DOUBLE in size per append, so "read the line, then measure it" is
    itself the multi-minute stall this check exists to catch."""
    over = []
    lineno, cur = 1, 0
    with open(path, "rb") as f:
        while True:
            buf = f.read(chunk)
            if not buf:
                break
            start = 0
            while True:
                nl = buf.find(b"\n", start)
                if nl == -1:
                    cur += len(buf) - start
                    break
                cur += nl - start
                if cur > limit:
                    over.append((lineno, cur))
                lineno += 1
                cur = 0
                start = nl + 1
    if cur > limit:
        over.append((lineno, cur))
    return over


def count_lines(path, chunk=1 << 20):
    """Total lines in `path`, streamed. Used to say how much of the chain came
    AFTER the last bad entry -- a defect that stopped 400 appends ago and one
    that is still writing are the same finding until you know that number."""
    n, last = 0, b"\n"
    with open(path, "rb") as f:
        while True:
            buf = f.read(chunk)
            if not buf:
                break
            n += buf.count(b"\n")
            last = buf[-1:]
    if last != b"\n":
        n += 1  # trailing line with no newline
    return n


# --------------------------------------------------------------- schema subset
def check_schema(instance, schema, where):
    """Minimal JSON-Schema subset: type + required + property types. Enough to
    catch a malformed or gutted policy; not a full validator (jsonschema is not
    a bundle dependency)."""
    errs = []
    pyt = {"object": dict, "array": list, "string": str,
           "integer": int, "number": (int, float), "boolean": bool}
    t = schema.get("type")
    if t in pyt and not isinstance(instance, pyt[t]):
        if not (t in ("integer", "number") and isinstance(instance, bool)):
            return ["%s: expected %s, got %s" % (where, t, type(instance).__name__)]
    if t == "object" and isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errs.append("%s: missing required key '%s'" % (where, key))
        for key, sub in (schema.get("properties") or {}).items():
            if key in instance and isinstance(sub, dict) and "type" in sub:
                errs.extend(check_schema(instance[key], sub, "%s.%s" % (where, key)))
    return errs


# ------------------------------------------------------------------ C5 secrets
# Live-secret shapes, NOT placeholders -- kept narrow so docs that talk ABOUT
# secrets are not flagged.
SECRET_RE = [
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{40,}"),
    re.compile(r"sk-[A-Za-z0-9]{32,}"),
    re.compile(r"gsk_[A-Za-z0-9]{40,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{20,}"),
]
# Pattern files legitimately contain secret-shaped regexes; test fixtures carry
# dummy keys. Skipping them is what keeps this check signal, not noise.
SECRET_SKIP = re.compile(r"(patterns\.json|golden-cases|test_|[\\/]tests?[\\/]|conftest)")

# ------------------------------------------------------------- CP932 lead byte
def cp932_lead(b):
    """True when byte `b` opens a two-byte CP932 (Shift-JIS) sequence.

    Why this matters for a UTF-8 file: Windows PowerShell 5.1 reads a BOM-less
    .ps1 in the system ANSI codepage. On a Japanese machine that is CP932,
    where these bytes are LEAD bytes that consume the byte after them. The
    trailing byte of a Vietnamese character or an em dash (E2 80 94) lands in
    this range, so a comment ending in one swallows its own newline -- and the
    NEXT LINE OF CODE vanishes from the parsed script. Exit code stays 0 and
    the file on disk is correct, so neither CI nor code review can see it."""
    return (0x81 <= b <= 0x9F) or (0xE0 <= b <= 0xFC)


# --------------------------------------------------- PowerShell block tracking
# `function|filter` at a statement start only. Anchoring here is what keeps the
# Write-Output check from crying wolf: an unanchored keyword match also fires on
# `-CommandType Function -Name X`, which would mark the NEXT unrelated `{` as a
# function body and flag top-level code. Under-reporting an exotic declaration
# is the safe direction; a check that produces false positives gets disabled.
PS_FUNC_RE = re.compile(r"(?:^|[;}])\s*(?:function|filter)\s+[A-Za-z_]", re.I)


def ps_blank_noncode(text):
    """Blank out comments, strings and here-strings, preserving every byte
    position and line break, so the braces that survive are real block
    delimiters. Without this, `"{0}"` in a format string or a `{` inside a
    comment desynchronises the depth counter and the caller silently reports
    nonsense."""
    out = []
    i, n = 0, len(text)
    state = None   # None | line | block | sq | dq | hs-sq | hs-dq
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "<" and nxt == "#":
                state = "block"; out.append("  "); i += 2; continue
            if c == "#":
                state = "line"; out.append(" "); i += 1; continue
            if c == "@" and nxt in ("'", '"'):
                # A here-string only opens when @" is the last token on the
                # line; otherwise @" is just a splat next to a string.
                eol = text.find("\n", i)
                if text[i + 2:eol if eol != -1 else n].strip() == "":
                    state = "hs-sq" if nxt == "'" else "hs-dq"
                    out.append("  "); i += 2; continue
            if c == "'":
                state = "sq"; out.append(" "); i += 1; continue
            if c == '"':
                state = "dq"; out.append(" "); i += 1; continue
            if c == "`":
                # Backtick-newline is a line continuation. Emitting the newline
                # keeps reported line numbers aligned with the real file.
                out.append(" ")
                if nxt:
                    out.append("\n" if nxt == "\n" else " ")
                i += 2; continue
            out.append(c); i += 1; continue
        if state == "line":
            if c == "\n":
                state = None; out.append("\n"); i += 1; continue
            out.append(" "); i += 1; continue
        if state == "block":
            if c == "#" and nxt == ">":
                state = None; out.append("  "); i += 2; continue
            out.append("\n" if c == "\n" else " "); i += 1; continue
        if state == "sq":
            if c == "'" and nxt == "'":
                out.append("  "); i += 2; continue
            if c == "'":
                state = None
            out.append("\n" if c == "\n" else " "); i += 1; continue
        if state == "dq":
            if c == "`":
                out.append(" ")
                if nxt:
                    out.append("\n" if nxt == "\n" else " ")
                i += 2; continue
            if c == '"' and nxt == '"':
                out.append("  "); i += 2; continue
            if c == '"':
                state = None
            out.append("\n" if c == "\n" else " "); i += 1; continue
        # here-string: the terminator must sit at the start of a line
        quote = "'" if state == "hs-sq" else '"'
        if c == "\n" and text[i + 1:i + 3] == quote + "@":
            state = None; out.append("\n  "); i += 3; continue
        out.append("\n" if c == "\n" else " "); i += 1; continue
    return "".join(out)


def ps_write_output_in_function(text):
    """-> (line_numbers, saw_body, None)  or  (None, None, reason).

    Line numbers of every `Write-Output` sitting inside a `function`/`filter`
    body, plus whether the file declared any function body at all (no body means
    nothing was actually checked -- the caller must SKIP, not claim a pass).

    Returns a reason instead when the brace depth does not resolve to zero: the
    blanking above then lost sync with the real source, and a guess here is
    exactly the fabricated result C10 forbids."""
    stack, pending, hits, saw_body = [], False, [], False
    for lineno, ln in enumerate(ps_blank_noncode(text).split("\n"), 1):
        if PS_FUNC_RE.search(ln):
            pending = True
        # Searched in the BLANKED line, so a Write-Output named inside a comment
        # or a string is not a hit -- this repo carries exactly such a comment
        # inside a function body today, explaining why the call was removed.
        want = ln.lower().find("write-output")
        for col, ch in enumerate(ln):
            if ch == "{":
                stack.append(pending)
                saw_body = saw_body or pending
                pending = False
            elif ch == "}":
                if not stack:
                    return None, None, "unbalanced '}'"
                stack.pop()
            elif col == want and any(stack):
                hits.append(lineno)
    if stack:
        return None, None, "%d unclosed '{'" % len(stack)
    return hits, saw_body, None


ALLOWED_MODELS = {
    "claude-opus-5-5", "claude-sonnet-5-5",
    "claude-haiku-4-5-20251001", "claude-haiku-4-5",
}
# The ladder before 1.8.3. casan-policies.yaml is on the bundle's preserve list,
# so every fleet project still carries these after updating: that is a WARN
# (true, worth fixing, breaks nothing yet), not a FAIL that reddens the whole
# fleet over a file the update is not allowed to touch.
RETIRED_MODELS = {"claude-fable-5", "claude-opus-4-8", "claude-sonnet-5"}
# What Claude Code itself accepts in an agent's `model:` besides a full id.
_AGENT_MODEL_ALIASES = {"opus", "sonnet", "haiku", "inherit"}

H_LAYERS = ("context", "tool", "evaluation", "security",
            "governance", "agentops", "orchestration")


# Tools Claude Code itself provides; `Agent(a, b)` is the bounded subagent form.
_BUILTIN_AGENT_TOOLS = {
    "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "Bash", "PowerShell", "Skill",
    "WebFetch", "WebSearch", "TodoWrite", "NotebookEdit", "Agent", "Task",
}


def _split_tools(value):
    """`tools:` as Claude Code reads it: a comma list (commas inside Agent(...) kept) or a YAML list."""
    if value is None:
        return []
    if isinstance(value, list):
        return [str(t).strip() for t in value if str(t).strip()]
    out, depth, cur = [], 0, ""
    for ch in str(value):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def check_agents(root):
    """agents:definitions -- each .claude/agents/*.md must be an agent Claude Code can load.

    2026-09-30: all 15 shipped agents opened `---` and never closed it, so the whole
    file was YAML with the prompt in an `instructions:` key, and Claude Code loaded
    none of them. boss.md also named three unresolvable tools and an unbounded Agent.
    Nothing checked it; every gate was green over agents that did not exist."""
    adir = os.path.join(root, ".claude", "agents")
    files = sorted(glob.glob(os.path.join(adir, "*.md")))
    files = [f for f in files if os.path.basename(f).lower() != "readme.md"]
    if not files:
        skip("agents:definitions", "no .claude/agents/*.md in this repo")
        return
    registry = set()
    reg_path = os.path.join(root, ".harness", "control", "tool-registry.json")
    try:
        with open(reg_path, encoding="utf-8-sig") as fh:
            reg = json.load(fh)
        tools = reg.get("tools", reg)
        registry = set(tools.keys() if isinstance(tools, dict) else (t.get("name") for t in tools))
    except (OSError, ValueError, AttributeError):
        pass
    problems = []
    for f in files:
        name = os.path.basename(f)
        with open(f, encoding="utf-8-sig", errors="replace") as fh:
            lines = fh.read().replace("\r\n", "\n").split("\n")
        if not lines or lines[0].strip() != "---":
            problems.append("%s: does not start with a `---` frontmatter line" % name)
            continue
        close = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
        if close is None:
            problems.append("%s: frontmatter opened with `---` and never closed -- Claude Code "
                            "cannot load it (the prompt must be the body, not an `instructions:` key)" % name)
            continue
        fm_text, body = "\n".join(lines[1:close]), "\n".join(lines[close + 1:])
        try:
            import yaml  # noqa: PLC0415 -- optional, like load()
            fm = yaml.safe_load(fm_text) or {}
        except ImportError:
            fm = {}
            for ln in fm_text.split("\n"):
                m = re.match(r"^(\w+):\s*(.*)$", ln)
                if m:
                    fm[m.group(1)] = m.group(2).strip().strip('"')
        except Exception as e:  # noqa: BLE001
            problems.append("%s: frontmatter is not valid YAML (%s)" % (name, str(e).split("\n")[0]))
            continue
        if not isinstance(fm, dict) or not fm.get("name") or not fm.get("description"):
            problems.append("%s: frontmatter needs `name` and `description`" % name)
        if not body.strip():
            problems.append("%s: empty body -- the agent would run with no instructions" % name)
        model = str(fm.get("model") or "").strip() if isinstance(fm, dict) else ""
        if model and model not in ALLOWED_MODELS and model not in _AGENT_MODEL_ALIASES:
            problems.append("%s: model `%s` is not on the C4 ladder (%s) nor a Claude Code alias"
                            % (name, model, ", ".join(sorted(ALLOWED_MODELS))))
        for t in _split_tools(fm.get("tools") if isinstance(fm, dict) else None):
            base = t.split("(", 1)[0].strip()
            if base in _BUILTIN_AGENT_TOOLS or base in registry:
                continue
            m = re.match(r"^mcp__(.+?)__(.+)$", base)
            if m and "%s.%s" % (m.group(1), m.group(2)) in registry:
                continue
            problems.append("%s: tool `%s` is neither built-in nor in tool-registry.json" % (name, t))
    if problems:
        fail("agents:definitions", "%d problem(s): %s" % (len(problems), evidence(problems)))
    else:
        ok("agents:definitions")


def check_local_state(root):
    """Portal v2 P1 1.7: machine-local state must not be tracked by git.

    The list lives in .harness/control/machine-state-paths.yaml (C2/C8); the matching is
    harness_local_state's, shared with the repair script so the check and the fix cannot
    disagree about scope.

    Grades: a TRACKED machine-local file is a FAIL (a key, a cursor or a live chain handed to
    every clone; it only gets worse). Not being able to look -- no list, no git -- is a SKIP,
    never a pass (C12). A committed config that still names a person (member_email) is a WARN:
    a migration debt that leaks no secret, and failing every fleet project over it would get
    the rule switched off (C14)."""
    spec_path = os.path.join(root, ".harness", "control", "machine-state-paths.yaml")
    names = ("local-state:machine-files-not-tracked", "local-state:committed-config-clean")
    if not os.path.isfile(spec_path):
        for n in names:
            skip(n, "no .harness/control/machine-state-paths.yaml -- this project predates the split "
                    "of machine-local state (update the bundle)")
        return
    try:
        import importlib.util
        lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness_local_state.py")
        sp = importlib.util.spec_from_file_location("harness_local_state", lib)
        hls = importlib.util.module_from_spec(sp)
        sp.loader.exec_module(hls)
    except Exception as e:  # noqa: BLE001
        for n in names:
            skip(n, "harness_local_state.py cannot be loaded (%s)" % type(e).__name__)
        return
    files, err = hls.tracked_machine_files(root)
    if files is None:
        for n in names:
            skip(n, "cannot tell what git tracks: %s -- unproven, not green" % err)
        return
    guarded = hls.guarded_machine_files(root, files)
    hard = [f for f in files if f not in guarded]
    if hard:
        fail(names[0], "git TRACKS %d machine-local file(s); untrack them with "
             "tools/harness-bundle/fix-untrack-machine-state (git rm --cached, files stay on disk): %s%s"
             % (len(files), evidence(files),
                "" if not guarded else " -- the ledger paths among them need the explicit -IncludeLedger flag"))
    elif files:
        # Only the live ledger: the default repair refuses it (other clones lose their copy when
        # they pull), so a FAIL here could never be cleared by it (C14). WARN, naming the flag.
        warn(names[0], "git tracks the live ledger (%d file(s)): %s -- the repair skips it by default "
             "(a clone that pulls the untracking commit has its tracked copy DELETED, C9); run "
             "tools/harness-bundle/fix-untrack-machine-state with -IncludeLedger in every clone "
             "BEFORE it pulls, or archive the chain first" % (len(files), evidence(files)))
    else:
        ok(names[0])
    leaks = hls.committed_field_leaks(root)
    if leaks:
        warn(names[1], "committed %s" % evidence(
            ["%s carries '%s' (belongs in %s)" % (x["file"], x["field"], x["moved_to"]) for x in leaks]))
    else:
        ok(names[1])


def check_tool_defaults(root):
    """C6: risk-policy's tool_deny_defaults must not contradict tool-registry.json.

    The guard decides from the registry; nothing reads tool_deny_defaults. It
    still reads like policy -- on 30-09 it said run_command and http_fetch were
    "ask" while the enforced registry said "deny". WARN, not FAIL: it misleads
    a reader but opens no hole, and risk-policy.yaml is project-owned
    (preserve), so a FAIL would redden every project over a file an update
    cannot touch."""
    rp = os.path.join(root, ".harness", "control", "risk-policy.yaml")
    rg = os.path.join(root, ".harness", "control", "tool-registry.json")
    if not (os.path.isfile(rp) and os.path.isfile(rg)):
        skip("C6:tool-defaults-match-registry", "risk-policy.yaml or tool-registry.json absent")
        return
    try:
        defaults = (load(rp) or {}).get("tool_deny_defaults") or {}
        reg = load(rg)
        tools = reg.get("tools", reg) if isinstance(reg, dict) else {}
    except Exception as e:  # noqa: BLE001
        skip("C6:tool-defaults-match-registry", "cannot read the two files (%s)" % str(e).split("\n")[0])
        return
    if not defaults:
        skip("C6:tool-defaults-match-registry", "risk-policy.yaml declares no tool_deny_defaults")
        return
    problems = []
    for name, d in sorted(defaults.items()):
        entries = [(k, v) for k, v in tools.items()
                   if isinstance(v, dict) and (k == name or k.endswith("." + name))]
        if not entries:
            problems.append("%s: not in tool-registry.json (the guard does not know it)" % name)
            continue
        for key, v in entries:
            want = (v.get("default_action"), v.get("risk_level"))
            have = ((d or {}).get("action"), (d or {}).get("risk"))
            if want != have:
                problems.append("%s: risk-policy says %s/%s, registry %s says %s/%s"
                                % (name, have[1], have[0], key, want[1], want[0]))
    if problems:
        warn("C6:tool-defaults-match-registry",
             "tool_deny_defaults contradicts tool-registry.json, which is what the guard enforces -- "
             "fix risk-policy.yaml (it is only a copy): %s" % evidence(problems))
    else:
        ok("C6:tool-defaults-match-registry")


def check_baseline_denies_covered(root):
    """B-75: a shipped baseline deny case the project's own deny policy misses.

    baseline-guard-cases.jsonl is bundle-managed and replaced on update;
    risk-policy.yaml is project-owned (preserve) and is not. When a release
    ships a new pattern together with the cases that test it, the project gets
    the cases without the pattern and golden goes red with only "expect deny,
    got allow" to go on (AllIn1Site after 4bfb4c53: 4 failures). Golden staying
    red is right -- the guard really does not block those commands -- so this
    is a WARN that names the case and the shipped pattern to copy over, never a
    FAIL, and it never edits the preserved file."""
    name = "golden:baseline-denies-covered"
    try:
        import harness_golden as G
    except Exception as e:  # noqa: BLE001
        skip(name, "harness_golden.py not importable (%s)" % e)
        return
    base = os.path.join(root, G._dataset_dir(root).replace("/", os.sep), "baseline-guard-cases.jsonl")
    rp = os.path.join(root, ".harness", "control", "risk-policy.yaml")
    if not (os.path.isfile(base) and os.path.isfile(rp)):
        skip(name, "baseline-guard-cases.jsonl or risk-policy.yaml absent")
        return

    def compiled(pats):
        out = []
        for p in pats:
            try:
                out.append((p, re.compile(p)))
            except re.error:
                continue  # same fail-open as the guard and the golden runner
        return out

    have = compiled(G._load_deny_patterns(root))
    shipped_p = rp + ".new"
    shipped = compiled(G._load_deny_patterns(root, shipped_p)) if os.path.isfile(shipped_p) else []
    missing = []
    for line in open(base, encoding="utf-8-sig"):
        try:
            c = json.loads(line)
        except ValueError:
            continue
        inp = c.get("input", "")
        if c.get("expect") != "deny" or any(rx.search(inp) for _, rx in have):
            continue
        fix = [p for p, rx in shipped if rx.search(inp)]
        if fix:
            missing.append("%s -> copy pattern %s from risk-policy.yaml.new" % (c.get("id"), fix[0]))
        else:
            missing.append("%s (no risk-policy.yaml.new pattern blocks it either)" % c.get("id"))
    if missing:
        warn(name, "%d shipped baseline deny case(s) your risk-policy.yaml does not block, so golden fails "
             "on them. risk-policy.yaml is yours (preserve) and updates do not change it: %s"
             % (len(missing), evidence(missing)))
    else:
        ok(name)


def run(root):
    harness = os.path.join(root, ".harness")
    control = os.path.join(harness, "control")
    schemas = os.path.join(harness, "schemas")

    # ---- layout ----------------------------------------------------------
    if os.path.isdir(control) and os.path.isdir(schemas) and control_files(control):
        ok("layout")
    else:
        fail("layout", "missing .harness/control, .harness/schemas, or policy files")
        return  # nothing below is meaningful

    check_agents(root)
    check_tool_defaults(root)
    check_baseline_denies_covered(root)
    check_local_state(root)

    # ---- every policy parses --------------------------------------------
    parsed = {}
    for p in control_files(control):
        name = os.path.basename(p)
        try:
            data = load(p)
        except RuntimeError as e:
            skip("parses:" + name, str(e))
            continue
        except Exception as e:
            fail("parses:" + name, "does not parse (%s)" % e)
            continue
        if data is None:
            fail("parses:" + name, "parsed to nothing")
        else:
            parsed[name] = data
            ok("parses:" + name)

    # ---- C8: JSON policies are schema-backed and satisfy their schema ----
    exempt = {"injection-patterns.json", "secret-patterns.json"}
    for p in control_files(control):
        name = os.path.basename(p)
        if not name.endswith(".json") or name in exempt:
            continue
        sp = os.path.join(schemas, os.path.splitext(name)[0] + ".schema.json")
        if not os.path.isfile(sp):
            fail("C8:schema-exists:" + name, "no matching schema in .harness/schemas")
        else:
            ok("C8:schema-exists:" + name)
    for name, data in parsed.items():
        sp = os.path.join(schemas, os.path.splitext(name)[0] + ".schema.json")
        if not os.path.isfile(sp):
            continue
        try:
            errs = check_schema(data, load(sp), name)
        except Exception as e:
            skip("C8:schema-valid:" + name, str(e))
            continue
        if errs:
            fail("C8:schema-valid:" + name, "; ".join(errs))
        else:
            ok("C8:schema-valid:" + name)

    # ---- C4 + C10 on casan-policies -------------------------------------
    casan = parsed.get("casan-policies.yaml")
    if casan is None:
        skip("C4:model-ladder", "casan-policies.yaml unavailable")
        skip("C10:h-layers", "casan-policies.yaml unavailable")
    else:
        ladder = (casan.get("orchestration") or {}).get("model_fallback") or {}
        if not ladder:
            fail("C4:model-ladder", "orchestration.model_fallback not declared")
        else:
            named = set()
            for chain in ladder.values():
                named.update(chain if isinstance(chain, list) else [chain])
            stray = sorted(m for m in named if m not in ALLOWED_MODELS | RETIRED_MODELS)
            retired = sorted(m for m in named if m in RETIRED_MODELS)
            if stray:
                fail("C4:model-ladder", "unlicensed model IDs: %s" % stray)
            elif retired:
                warn("C4:model-ladder", "orchestration.model_fallback still names retired model(s) %s. "
                     "The ladder since 1.8.3 is %s. casan-policies.yaml is project-owned (preserve), "
                     "so the bundle update did not change it -- edit model_fallback by hand."
                     % (retired, sorted(ALLOWED_MODELS - {"claude-haiku-4-5"})))
            else:
                ok("C4:model-ladder")

        missing = [L for L in H_LAYERS if L not in casan]
        no_enf = [L for L in H_LAYERS
                  if L in casan and isinstance(casan[L], dict) and "enforced_at" not in casan[L]]
        if missing or no_enf:
            fail("C10:h-layers", "missing layers %s; missing enforced_at %s" % (missing, no_enf))
        else:
            ok("C10:h-layers")

    # ---- H1: the pointer store honours the context contract --------------
    if casan is None:
        skip("H1:pointer-store", "casan-policies.yaml unavailable")
    else:
        ctx = casan.get("context") or {}
        rel = ctx.get("pointer_store") or ".harness/context/pipeline-context.yaml"
        store = os.path.join(root, rel.replace("/", os.sep))
        if not os.path.isfile(store):
            fail("H1:pointer-store", "missing pointer store: %s" % rel)
        else:
            try:
                data = load(store) or {}
            except RuntimeError as e:
                data = None
                skip("H1:pointer-store", str(e))
            except Exception as e:
                data = None
                fail("H1:pointer-store", "does not parse (%s)" % e)
            if data is not None:
                problems = []
                for key in ctx.get("required_keys", []):
                    if key not in data or data[key] in ("", None, []):
                        problems.append("missing/empty required key '%s'" % key)
                for ptr in ("srs_path", "spec_path"):
                    v = data.get(ptr)
                    if v and not os.path.exists(os.path.join(root, v.replace("/", os.sep))):
                        problems.append("%s -> '%s' does not exist (dangling)" % (ptr, v))
                if problems:
                    fail("H1:pointer-store", "; ".join(problems))
                else:
                    ok("H1:pointer-store")

    # ---- plane separation: the harness governs the ASSISTANT, not the product
    # casan-policies declares Claude model ids under orchestration.model_fallback.
    # In a repo whose PRODUCT also calls LLMs, that reads like "the model fallback
    # chain", and wiring the product gateway to it looks like an H7 uplift. It is
    # an outage: an assistant-plane model id sent to another provider's endpoint
    # fails every call, and surfaces as a bad KEY rather than a bad model name.
    # Two assertions -- the second catches the runtime-lookup form that grepping
    # for model ids alone would miss.
    # Each H layer states its plane in machine-readable form, so this check --
    # and any consumer -- can assert it instead of parsing a comment. Absent is
    # SKIP, not FAIL: casan-policies.yaml is preserved on upgrade, so a project
    # that predates the field must not have its release gate broken by it.
    if casan is None:
        skip("plane:governs-declared", "casan-policies.yaml unavailable")
    else:
        declared = {L: (casan.get(L) or {}).get("governs")
                    for L in H_LAYERS if isinstance(casan.get(L), dict)}
        wrong = sorted("%s=%r" % (L, v) for L, v in declared.items()
                       if v is not None and v not in ("assistant_workflow", "product_runtime"))
        absent = sorted(L for L, v in declared.items() if v is None)
        if wrong:
            fail("plane:governs-declared",
                 "unknown plane (expected assistant_workflow|product_runtime): %s" % ", ".join(wrong))
        elif absent:
            skip("plane:governs-declared",
                 "layers without `governs:` -- add it to state the plane: %s" % ", ".join(absent))
        else:
            ok("plane:governs-declared")

    src_dirs = []
    for g in ((casan or {}).get("context") or {}).get("source_globs") or []:
        for m in glob.glob(os.path.join(root, g.replace("/", os.sep))):
            d = m if os.path.isdir(m) else os.path.dirname(m)
            rel = os.path.relpath(d, root) if d else ""
            if rel and rel != "." and os.path.isdir(d) and not rel.startswith((".harness", ".claude", ".git")):
                if rel not in src_dirs:
                    src_dirs.append(rel)
    if not src_dirs:
        skip("plane:no-assistant-model-in-product", "context.source_globs matches no product directory in this repo")
        skip("plane:product-does-not-read-harness", "context.source_globs matches no product directory in this repo")
    else:
        model_ids = set()
        for chain in ((casan.get("orchestration") or {}).get("model_fallback") or {}).values():
            model_ids.update(chain if isinstance(chain, list) else [chain])
        try:
            pp = load(os.path.join(control, "power-policy.json"))
            for v in (pp.get("model_tier_map") or {}).values():
                # A tier maps to ONE model id (str) in some configs and to a
                # fallback LIST in others (this repo's own power-policy.json is
                # the list shape) -- the old `isinstance(v, str)` guard silently
                # dropped every list-shaped tier, so only orchestration's own
                # model_fallback ever fed this check.
                model_ids.update(v if isinstance(v, list) else [v])
        except Exception:
            pass
        # No vendor prefix filter: these ids come from the harness's OWN
        # assistant-plane config (orchestration.model_fallback /
        # power-policy.json), so whatever is configured there IS the
        # assistant-plane id, whichever vendor a deployment actually pins (C4 --
        # "Fable 5/Opus 4.8/Sonnet 5/Haiku 4.5" is THIS harness's chosen ladder,
        # not the only ladder the check can recognize). The old
        # `m.startswith("claude-")` filter meant a deployment pinned to a
        # different vendor's model ids would silently produce an EMPTY set here
        # -- the check would report green having verified nothing.
        model_ids = {m for m in model_ids if isinstance(m, str) and m.strip()}

        leak_model, leak_harness = [], []
        for rel in src_dirs:
            for dirpath, _d, files in os.walk(os.path.join(root, rel)):
                if any(part in dirpath for part in ("node_modules", "__pycache__", ".venv", "dist", "build")):
                    continue
                for fn in files:
                    if os.path.splitext(fn)[1] not in (".py", ".ts", ".tsx", ".js", ".jsx", ".go", ".java", ".rb", ".php", ".cs"):
                        continue
                    fp = os.path.join(dirpath, fn)
                    # A test is not product runtime. This rule asks what the
                    # SHIPPED product does; a test that names `.harness/` is
                    # usually asserting the separation rather than breaking it --
                    # one project failed here on a test whose whole purpose is
                    # proving the public export EXCLUDES the harness layer. It
                    # was swept in because `source_globs: */__init__.py` makes
                    # any package a "product directory", tests included. A rule
                    # that fires on the code enforcing it is the false alarm C14
                    # calls a P0.
                    if is_test_path(os.path.relpath(fp, root)):
                        continue
                    try:
                        text = open(fp, encoding="utf-8", errors="ignore").read()
                    except Exception:
                        continue
                    where = os.path.relpath(fp, root)
                    for mid in model_ids:
                        if mid in text:
                            leak_model.append("%s: %s" % (where, mid))
                            break
                    # `.harness` followed by any separator, so both "/.harness/x"
                    # and an escaped Windows path in source are caught.
                    if re.search(r"\.harness[\\/]", text):
                        leak_harness.append(where)
        if leak_model:
            fail("plane:no-assistant-model-in-product",
                 "assistant-plane model id in product code: " + "; ".join(leak_model[:5]))
        else:
            ok("plane:no-assistant-model-in-product")
        if leak_harness:
            fail("plane:product-does-not-read-harness",
                 "product code reads .harness/: " + "; ".join(leak_harness[:5]))
        else:
            ok("plane:product-does-not-read-harness")

    # ---- C5: no hardcoded secrets in the governed surface -----------------
    hits = []
    for rel in (".harness/control", ".harness/scripts", ".harness/schemas", "contracts"):
        base = os.path.join(root, rel.replace("/", os.sep))
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, files in os.walk(base):
            for fn in files:
                fp = os.path.join(dirpath, fn)
                if os.path.splitext(fn)[1] in (".pyc", ".png", ".jpg", ".gz", ".key"):
                    continue
                if SECRET_SKIP.search(fp):
                    continue
                try:
                    with open(fp, encoding="utf-8", errors="ignore") as f:
                        text = f.read()
                except Exception:
                    continue
                for rx in SECRET_RE:
                    m = rx.search(text)
                    if m:
                        v = m.group(0)
                        # Report the location, MASK the value -- never echo a secret.
                        hits.append("%s: %s...%s" % (os.path.relpath(fp, root), v[:4], v[-4:]))
                        break
    if hits:
        fail("C5:no-hardcoded-secrets", "; ".join(hits))
    else:
        ok("C5:no-hardcoded-secrets")

    # ---- C8: a bundle manifest must be real YAML --------------------------
    # The packer reads bundle.yaml line-by-line, so a manifest can carry an
    # unescaped quote inside a double-quoted scalar, pack cleanly, and still be
    # unparseable to every other consumer. Only meaningful in a repo that
    # PUBLISHES bundles; a consuming project has no bundles/ and skips.
    manifests = sorted(glob.glob(os.path.join(root, "bundles", "*", "bundle.yaml")))
    if not manifests:
        skip("C8:bundle-manifest-parses", "no bundles/*/bundle.yaml in this repo")
    else:
        bad = []
        for m in manifests:
            rel = os.path.relpath(m, root)
            try:
                data = load(m)
            except RuntimeError as e:
                bad = None
                skip("C8:bundle-manifest-parses", str(e))
                break
            except Exception as e:
                bad.append("%s: %s" % (rel, str(e).split("\n")[0]))
                continue
            for key in ("name", "version", "description"):
                if not (isinstance(data, dict) and data.get(key)):
                    bad.append("%s: missing '%s'" % (rel, key))
        if bad:
            fail("C8:bundle-manifest-parses", "; ".join(bad))
        elif bad is not None:
            ok("C8:bundle-manifest-parses")

    # ---- file shape: the three defects that survive code review -----------
    # Everything above reads policy. The three below read BYTES, because each
    # of these failures is invisible in a diff: the file renders correctly in
    # every editor, and the damage happens in the shell that loads it.

    # CRLF in a .sh makes Linux read the shebang as "/bin/sh\r" and exec fails
    # with "no such file or directory" -- naming the INTERPRETER, not the
    # script, which is why one project burned hours on 115 crash-loops with the
    # file present and executable. The publishing repo is usually clean; the
    # corruption happens in the CONSUMING checkout, where git's core.autocrlf
    # rewrites the installed scripts and Docker then bakes them into an image.
    # The fix is a .gitattributes -- see .harness/templates/gitattributes.template.
    # Scope: first 400 bytes. The shebang is what breaks exec, and a head-only
    # read stays cheap over a whole project. A CRLF appearing LATER in a file
    # (which breaks `case` labels and quoted arguments) is NOT reported here.
    sh_files = walk_ext(root, {".sh"})
    if not sh_files:
        skip("crlf:shell-scripts-are-lf", "no .sh files under %s" % root)
    else:
        crlf = [os.path.relpath(p, root) for p in sh_files
                if b"\r\n" in read_bytes(p, 400)]
        if crlf:
            fail("crlf:shell-scripts-are-lf",
                 "%d of %d .sh start with CRLF -- Linux will exec '/bin/sh\\r' and "
                 "report 'no such file or directory' for the INTERPRETER: %s"
                 % (len(crlf), len(sh_files), evidence(crlf)))
        else:
            ok("crlf:shell-scripts-are-lf")

    # A BOM-less .ps1 is read by Windows PowerShell 5.1 in the system ANSI
    # codepage, so on a CP932 machine any line whose last byte is a lead byte
    # eats the newline AND the line after it. The script still exits 0. This
    # has already silently disabled a live rule in a shipped project.
    ps_files = walk_ext(root, {".ps1"})
    if not ps_files:
        skip("bom:powershell-has-utf8-bom", "no .ps1 files under %s" % root)
    else:
        # Three outcomes, not two. A BOM-less file whose bytes are all ASCII
        # decodes IDENTICALLY under UTF-8 and under any ANSI codepage -- nothing
        # about it is wrong today, only fragile the moment someone types an
        # accented character into it. Fleet-wide that was 45 of 181 findings,
        # every one of them reported with the same red as a file that really
        # does mis-decode. Grading them the same is how a check stops being
        # read (C14), so latent files WARN and only genuine mis-decodes FAIL.
        mojibake, hazard, latent = [], [], []
        for p in ps_files:
            raw = read_bytes(p)
            if not raw or raw[:3] == b"\xef\xbb\xbf":
                continue
            rel = os.path.relpath(p, root)
            hit = False
            for lineno, line in enumerate(raw.split(b"\n"), 1):
                line = line.rstrip(b"\r")
                if line and cp932_lead(line[-1]):
                    hazard.append("%s:%d" % (rel, lineno))
                    hit = True
            if hit:
                mojibake.append(rel)
            elif any(b > 0x7F for b in raw):
                # Non-ASCII but no line ENDS in a lead byte: no line is
                # swallowed, but the text still decodes wrong -- mangled output,
                # and mangled string literals if any are compared against.
                mojibake.append(rel)
            else:
                latent.append(rel)
        if mojibake:
            why = ("%d of %d .ps1 have no UTF-8 BOM AND contain non-ASCII bytes, so "
                   "Windows PowerShell 5.1 decodes them in the ANSI codepage and the "
                   "text is wrong: %s" % (len(mojibake), len(ps_files), evidence(mojibake)))
            if hazard:
                why += (" || %d line(s) end in a CP932 lead byte "
                        "(0x81-0x9F / 0xE0-0xFC) -- on a CP932 machine each one "
                        "SWALLOWS THE NEXT LINE OF CODE and the script still exits 0: %s"
                        % (len(hazard), evidence(hazard)))
            if latent:
                why += (" || plus %d BOM-less file(s) that are pure ASCII, harmless "
                        "today -- see the warning" % len(latent))
            fail("bom:powershell-has-utf8-bom", why)
        elif latent:
            warn("bom:powershell-has-utf8-bom",
                 "%d of %d .ps1 have no UTF-8 BOM. They are pure ASCII, so they decode "
                 "identically either way and nothing is broken now; the first non-ASCII "
                 "character typed into one turns that into silent corruption: %s"
                 % (len(latent), len(ps_files), evidence(latent)))
        else:
            ok("bom:powershell-has-utf8-bom")

    # The MIRROR IMAGE of the check above, and the one the fleet actually keeps
    # tripping over. A .ps1 NEEDS a BOM; a data file must NOT have one.
    #
    # `Add-Content -Encoding utf8` on Windows PowerShell 5.1 always writes
    # EF BB BF on first write -- there is no "utf8 no BOM" flag -- so the first
    # line of a .jsonl stops being valid JSON and every reader downstream fails
    # on it. Two projects logged this independently, and the second one's own
    # note says the trap was already written down when the bundle script hit it
    # anyway. Documentation did not prevent it; nothing was checking.
    #
    # Scoped to the harness's own evidence files: a project's product data is
    # its own business, and widening this to every .json in the repo would
    # produce noise on vendored fixtures.
    data_dirs = [os.path.join(root, ".harness", "telemetry"),
                 os.path.join(root, ".harness", "ledger"),
                 os.path.join(root, ".harness", "eval")]
    data_files = []
    for d in data_dirs:
        if not os.path.isdir(d):
            continue
        for dirpath, _dirs, names in os.walk(d):
            for n in names:
                if n.endswith((".jsonl", ".json", ".log")):
                    data_files.append(os.path.join(dirpath, n))
    if not data_files:
        skip("bom:evidence-files-have-no-bom", "no .harness evidence files under %s yet" % root)
    else:
        bommed = [os.path.relpath(p, root) for p in data_files
                  if read_bytes(p, 3)[:3] == b"\xef\xbb\xbf"]
        if bommed:
            # WARN, not FAIL, and the wording is exact -- the first version of
            # this check claimed "every reader fails on it, ingest, doctor and
            # the Portal alike", which is FALSE. All three of this system's
            # evidence readers open with utf-8-sig, which strips a BOM silently.
            # They were hardened that way after B-06, so the BOM is TOLERATED
            # here, not harmless everywhere: jq, most JS and Go tooling, and any
            # future reader that forgets utf-8-sig still break on it, which is
            # exactly how B-06 surfaced in the first place.
            #
            # Overstating a consequence is the C14 failure this check exists to
            # help prevent, and it is worth more to be believed than to be loud.
            warn("bom:evidence-files-have-no-bom",
                 "%d of %d evidence file(s) start with a UTF-8 BOM: %s "
                 "|| This system's own readers open with utf-8-sig and cope, so nothing is broken "
                 "today. But the file is not valid JSONL for anything else -- jq and most non-Python "
                 "tooling reject line 1 -- and depending on every future reader remembering "
                 "utf-8-sig is the fragile part. Written by `Add-Content -Encoding utf8`, which on "
                 "PS 5.1 has no BOM-less mode; use [System.IO.File]::AppendAllText with "
                 "UTF8Encoding($false). `fix-fleet-evidence` strips them outside the ledger."
                 % (len(bommed), len(data_files), evidence(bommed)))
        else:
            ok("bom:evidence-files-have-no-bom")

    # In PowerShell every value on the success stream inside a function joins
    # that function's RETURN VALUE. A progress message written with
    # Write-Output therefore corrupts the data the caller gets -- this bundle
    # shipped exactly that and every telemetry push was rejected 422, from the
    # second push onward only. Use Write-Host / Write-Verbose for messages.
    if not ps_files:
        skip("ps:no-write-output-in-function", "no .ps1 files under %s" % root)
    else:
        hits, unread, bodies = [], [], 0
        for p in ps_files:
            rel = os.path.relpath(p, root)
            raw = read_bytes(p)
            if not raw:
                continue
            text = raw.decode("utf-8-sig", "replace").replace("\r\n", "\n")
            lines, saw_body, why = ps_write_output_in_function(text)
            if lines is None:
                unread.append("%s (%s)" % (rel, why))
                continue
            bodies += 1 if saw_body else 0
            hits.extend("%s:%d" % (rel, n) for n in lines)
        if unread:
            skip("ps:no-write-output-in-function:unanalysed",
                 "brace depth did not resolve, so these files were NOT checked: %s"
                 % evidence(unread))
        if hits:
            fail("ps:no-write-output-in-function",
                 "Write-Output inside a function body -- the message joins the "
                 "function's RETURN VALUE and silently corrupts it: %s || Scope: only "
                 "`function`/`filter` bodies whose braces balance; a scriptblock held "
                 "in a variable and a dot-sourced fragment are NOT covered."
                 % evidence(hits))
        elif bodies:
            ok("ps:no-write-output-in-function")
        else:
            skip("ps:no-write-output-in-function",
                 "no function/filter bodies found in %d .ps1 -- nothing to check"
                 % len(ps_files))

    # ---- C9: an oversized ledger entry means the WRITER regressed ---------
    # A pre-b730629 append bug embedded each entry's predecessors, so entries
    # DOUBLED in size per write. This repo's own chain grew a 2.19 MB single
    # line; tailing it in PowerShell 5.1 took 70 measured minutes, so the
    # PostToolUse hook timed out on every append and the ledger ran silent for
    # 14 days. The reader now tolerates such lines -- this check exists so a
    # regressed writer can never again get 14 quiet days.
    # Byte lengths only, no JSON parsing: parsing a poisoned line is exactly
    # the stall being detected. ACTIVE chain.jsonl only, never chain-*.jsonl
    # archives -- a sealed archive is known-bad history kept as evidence, and
    # flagging it would fail a repo forever for what it deliberately sealed.
    if casan is None:
        led_gov, led_why = {}, "casan-policies.yaml unavailable"
    else:
        led_gov = casan.get("governance") or {}
        led_why = "governance.ledger_max_entry_bytes not set"
    led_rel = led_gov.get("immutable_ledger") or ".harness/ledger/chain.jsonl"
    led_limit = led_gov.get("ledger_max_entry_bytes")
    if isinstance(led_limit, bool) or not isinstance(led_limit, int) or led_limit <= 0:
        led_limit, led_src = 65536, "default 65536 -- %s" % led_why
    else:
        led_src = "governance.ledger_max_entry_bytes"
    led = os.path.join(root, led_rel.replace("/", os.sep))
    if not os.path.isfile(led):
        skip("ledger:no-oversized-entry",
             "no active ledger at %s -- nothing has appended yet" % led_rel)
    else:
        # The active chain is appended to by live hooks; a transient sharing
        # violation must degrade to an honest SKIP, not take the suite down.
        try:
            over = lines_over_limit(led, led_limit)
        except Exception as e:
            over = None
            skip("ledger:no-oversized-entry",
                 "ledger exists but was NOT scanned (%s)" % e)
        if over:
            # Live or historical? The chain is append-only, so a fixed writer
            # cannot un-poison what it already wrote -- the bad lines stay
            # forever and the check stays red forever, which is how a gate stops
            # being read (C14). Saying how many CLEAN entries were appended after
            # the last bad one separates "this is still happening, stop it" from
            # "this ended N appends ago, seal it" -- two findings that were
            # printing identically.
            try:
                total = count_lines(led)
            except Exception:
                total = None
            since = (total - over[-1][0]) if total else None
            if since and since > 0:
                era = (" || The last oversized entry is line %d of %d: %s appended "
                       "since, all within the limit, so the writer is no longer "
                       "producing them. This is history, and an append-only chain "
                       "cannot be edited -- run `evidence-ledger.ps1 seal` (or "
                       "evidence-ledger.sh seal) to archive the poisoned segment and "
                       "start a clean one."
                       % (over[-1][0], total,
                          "1 entry has been" if since == 1
                          else "%d entries have been" % since))
            else:
                era = (" || The newest entry in the chain is one of these, so the "
                       "writer is embedding its predecessors RIGHT NOW -- every append "
                       "makes the next one bigger. Stop the writer, then run "
                       "`evidence-ledger.ps1 seal` (or evidence-ledger.sh seal).")
            fail("ledger:no-oversized-entry",
                 "%d line(s) in %s exceed %d bytes (%s; healthy entries are <1 KB): %s%s"
                 % (len(over), led_rel, led_limit, led_src,
                    evidence("line %d = %d B" % (ln, b) for ln, b in over), era))
        elif over is not None:
            ok("ledger:no-oversized-entry")

    # ---- U3: the manifest must describe a bundle that actually exists --------
    #
    # `version:` in bundle.yaml is the identity every install receipt records.
    # Editing the manifest without bumping it, or bumping it without packing,
    # both leave the same state: the manifest describes something no artifact
    # matches. Consequences are quiet and land later --
    #
    #   - reinstalling the declared version uses the OLD manifest, so a `preserve`
    #     entry added since is not honoured and a project's own file gets
    #     overwritten (this repo added baseline-w0.json to preserve in exactly
    #     that window);
    #   - the fleet reports "everyone on 1.8.0" against an artifact that was
    #     packed from different rules.
    #
    # Only runs where bundles/ is authored. A consuming project has no manifest
    # and must SKIP, not pass -- passing would claim a check ran that could not.
    manifests = sorted(glob.glob(os.path.join(root, "bundles", "*", "bundle.yaml")))
    if not manifests:
        skip("bundle:manifest-has-packed-artifact",
             "no bundles/*/bundle.yaml under %s — this project consumes bundles, it does not author them" % root)
    else:
        problems = []
        for man in manifests:
            bdir = os.path.dirname(man)
            bname = os.path.basename(bdir)
            ver = ""
            try:
                with open(man, encoding="utf-8-sig", errors="replace") as fh:
                    for line in fh:
                        m = re.match(r'^version:\s*"?([0-9][^"\s]*)"?', line)
                        if m:
                            ver = m.group(1)
                            break
            except OSError as e:
                problems.append("%s: cannot read manifest (%s)" % (bname, e))
                continue
            if not ver:
                problems.append("%s: manifest declares no version:" % bname)
                continue
            art = os.path.join(bdir, "%s-%s.bundle.json" % (bname, ver))
            if not os.path.exists(art):
                packed = sorted(os.path.basename(p) for p in glob.glob(os.path.join(bdir, "*.bundle.json")))
                problems.append(
                    "%s: manifest declares v%s but %s does not exist (packed: %s)"
                    % (bname, ver, os.path.basename(art), ", ".join(packed[-3:]) or "none"))
        if problems:
            fail("bundle:manifest-has-packed-artifact",
                 "a manifest describes a bundle nobody can install; pack it, or put the version "
                 "back to one that is packed: " + evidence(problems))
        else:
            ok("bundle:manifest-has-packed-artifact")


if __name__ == "__main__":
    # Consuming projects run on Windows consoles whose codepage (cp932, cp1252,
    # ...) cannot encode an em-dash; one such glyph in a SKIP/WARN line raised
    # UnicodeEncodeError AFTER the counts printed, so harness-eval recorded a
    # clean run as failed (AllIn1Site, 2026-10-06). Same guard as harness_doctor.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    run(sys.argv[1] if len(sys.argv) > 1 else ".")
    print("Passed : %d" % len(PASSED))
    print("Failed : %d" % len(FAILED))
    print("Skipped : %d" % len(SKIPPED))
    print("Warned : %d" % len(WARNED))
    for f in FAILED:
        print("  FAIL " + f)
    for w in WARNED:
        print("  WARN " + w)
    for s in SKIPPED:
        print("  SKIP " + s)
    # A warning never fails the suite -- that is the whole point of the level.
    sys.exit(1 if FAILED else 0)
