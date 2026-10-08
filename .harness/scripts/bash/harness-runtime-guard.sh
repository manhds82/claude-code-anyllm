#!/usr/bin/env bash
# PreToolUse hook — Runtime Guard (H4), bash parity version.
# Reads risk-policy.yaml (SSOT) to decide allow/deny for tool calls.
# C2: Reads YAML config — never hardcode deny rules in this script.
# C10: Local hook is defense-in-depth; high-risk needs server-side PDP.

set -euo pipefail

INPUT_JSON=""
if [ ! -t 0 ]; then
    INPUT_JSON=$(cat)
fi

if [ -z "$INPUT_JSON" ]; then
    exit 0
fi

# Claude Code's PreToolUse payload uses tool_name / tool_input; accept the
# older tool / input shape too.
TOOL_NAME=$(echo "$INPUT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name') or d.get('tool') or '')" 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$INPUT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('tool_input') or d.get('input') or {}))" 2>/dev/null || echo "{}")

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RISK_POLICY="$HARNESS_ROOT/.harness/control/risk-policy.yaml"

if [ ! -f "$RISK_POLICY" ]; then
    exit 0
fi

# Extract deny patterns from YAML (simple grep-based parser)
DENY_PATTERNS=$(python3 -c "
import sys
# LF, not the platform newline: a Windows python writes CRLF into a pipe, Git
# Bash strips only the LAST line's CR, and every other pattern then ended in
# '\r' and matched nothing (P0 0.8, 30-09 -- rm -rf, force-push, pipe-to-shell
# all passed this guard on Windows while golden said 36/36).
try:
    sys.stdout.reconfigure(newline='\n')
except Exception:
    pass
try:
    import yaml  # optional: absent -> no YAML deny patterns, not a crash
    # utf-8-sig: explicit encoding (locale-independent) + strips BOM if present
    with open('$RISK_POLICY', 'r', encoding='utf-8-sig') as f:
        data = yaml.safe_load(f)
    patterns = [p['pattern'] for p in data.get('command_deny_patterns', [])]
    for pat in patterns:
        print(pat)
except Exception:
    pass
" 2>/dev/null || true)

# Build command string
COMMAND_STRING=""
if [ -n "$TOOL_INPUT" ] && [ "$TOOL_INPUT" != "{}" ]; then
    COMMAND_STRING=$(echo "$TOOL_INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('command', d.get('script', '')))
" 2>/dev/null)
fi

# STDERR is the only channel that reaches the agent. Claude Code surfaces a
# non-zero PreToolUse exit as "No stderr output" when nothing was written there,
# so a deny told the agent it was blocked but never by what: it would guess,
# rewrite the command and retry, and every occurrence looked like a brand-new
# mystery. Every deny path must name the rule it matched, on stderr.
# Message text is kept byte-identical to Write-DenyToStderr in the .ps1 (C7).
deny_to_stderr() {
    _reason="$1"; _tool="$2"; _cmd="$3"
    _snip=""
    # Capped at 200 chars: the command may carry a secret and this text is
    # echoed verbatim into the agent transcript. Plain `if` rather than
    # `[ -n ] && ...` so an empty command cannot hand `set -e` a non-zero
    # function return in place of the guard's own exit code.
    if [ -n "$_cmd" ]; then
        _snip=" | command: $(printf '%.200s' "$_cmd")"
    fi
    printf '[harness-runtime-guard] DENIED tool=%s :: %s%s\n' "$_tool" "$_reason" "$_snip" >&2
}

# Persist a deny so the Portal ingest can pick it up (C9 + portal-spec §9):
#   1. .harness/telemetry/security-events.jsonl  -> security_incidents (authoritative)
#   2. .harness/ledger/chain.jsonl deny entry    -> action_log (blocked count)
persist_deny() {
    local tool="$1" pattern="$2" cmd="$3"
    local tel_dir="$HARNESS_ROOT/.harness/telemetry"
    mkdir -p "$tel_dir"
    GUARD_TOOL="$tool" GUARD_PATTERN="$pattern" GUARD_CMD="$cmd" \
    GUARD_EVENTS_FILE="$tel_dir/security-events.jsonl" \
    GUARD_USER="${HARNESS_USER:-${USER:-}}" GUARD_SESSION="${HARNESS_SESSION_ID:-}" \
    python3 - <<'PY' 2>/dev/null || true
import os, json, hashlib, datetime
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tool = os.environ.get("GUARD_TOOL", "")
pattern = os.environ.get("GUARD_PATTERN", "")
cmd = os.environ.get("GUARD_CMD", "")
event_id = "se-" + hashlib.sha256(f"{ts}|{tool}|{pattern}|{cmd}".encode()).hexdigest()[:24]
cmd_snip = cmd[:240]
event = {
    "event_id": event_id,
    "timestamp": ts,
    "type": "guard_block",
    "severity": "high",
    "category": tool[:50],
    "excerpt": f'blocked command: "{cmd_snip}" | matched deny-pattern: {pattern}',
    "detected_by": "harness-runtime-guard.sh",
    "actor_user": os.environ.get("GUARD_USER", ""),
    "session_id": os.environ.get("GUARD_SESSION", ""),
}
with open(os.environ["GUARD_EVENTS_FILE"], "a", encoding="utf-8") as f:
    f.write(json.dumps(event) + "\n")
PY
    # Ledger deny entry (best-effort; never block the guard decision on it)
    local ledger="$HARNESS_ROOT/.harness/scripts/bash/evidence-ledger.sh"
    if [ -x "$ledger" ] || [ -f "$ledger" ]; then
        local input_hash
        input_hash=$(printf '%s' "$cmd" | sha256sum | cut -d' ' -f1)
        local entry
        entry=$(GUARD_TOOL="$tool" GUARD_PATTERN="$pattern" GUARD_HASH="$input_hash" \
                GUARD_USER="${HARNESS_USER:-${USER:-}}" GUARD_SESSION="${HARNESS_SESSION_ID:-}" \
                python3 -c "
import os, json
print(json.dumps({
    'actor': {'agent': 'claude-code', 'user': os.environ.get('GUARD_USER',''), 'session_id': os.environ.get('GUARD_SESSION',''), 'role': 'member'},
    'action': {'type': 'tool_call', 'tool': os.environ.get('GUARD_TOOL',''), 'description': 'blocked by runtime guard', 'input_hash': os.environ.get('GUARD_HASH',''), 'output_hash': ''},
    'decision': {'result': 'deny', 'reason': 'deny pattern: ' + os.environ.get('GUARD_PATTERN',''), 'risk_level': 'high'},
}))" 2>/dev/null)
        [ -n "$entry" ] && bash "$ledger" append --entry-json "$entry" >/dev/null 2>&1 || true
    fi
}

# Check each deny pattern
while IFS= read -r pattern; do
    pattern="${pattern%$'\r'}"      # belt to the reconfigure above: a CR here disables the rule
    [ -z "$pattern" ] && continue
    # A policy pattern that begins with '-' (e.g. the -EncodedCommand rule) makes
    # grep read it as an option: it prints usage noise on stderr and reports
    # no-match. stderr is the agent-facing channel now, so that noise would bury
    # the single DENIED line under three lines of grep usage text. Silence grep's
    # stderr only — the match result (what is denied) is unchanged. Making
    # dash-leading patterns actually enforce here needs '--', which would switch
    # on a rule this script has never applied; that is a policy change, not ours.
    if echo "$COMMAND_STRING" | grep -qE "$pattern" 2>/dev/null; then
        REASON="Command matched deny pattern: $pattern"
        deny_to_stderr "$REASON" "$TOOL_NAME" "$COMMAND_STRING"
        persist_deny "$TOOL_NAME" "$pattern" "$COMMAND_STRING" || true
        echo "{\"permissionDecision\":\"deny\",\"reason\":\"$REASON\",\"tool\":\"$TOOL_NAME\"}"
        exit 2
    fi
done <<< "$DENY_PATTERNS"

# --- Tool-registry deny-by-default (C3) -------------------------------------
# This layer was missing from the bash twin entirely: the PowerShell guard
# consulted tool-registry.json and refused any registered tool marked
# high/critical with default_action=deny, and this script went straight from
# the command patterns to the PDP. On a Linux/macOS checkout every registered
# side-effect tool -- deploy and mysql_query included -- was governed by
# nothing but the shell-command regexes, which do not see an MCP tool call at
# all (it carries no command string).
#
# Name shapes, same as the PowerShell side: Claude Code sends
# `mcp__<server>__<tool>` while the registry keys `<server>.<tool>`. Candidates
# are tried most-precise first, ending with any `*.<tool>` so a server mounted
# under a second alias cannot slip past a policy that names it once.
TOOL_REGISTRY="$HARNESS_ROOT/.harness/control/tool-registry.json"
if [ -f "$TOOL_REGISTRY" ]; then
    REG_VERDICT=$(REG_FILE="$TOOL_REGISTRY" TOOL="$TOOL_NAME" python3 - <<'REG' 2>/dev/null || true
import json, os, re

try:
    tools = json.load(open(os.environ["REG_FILE"], encoding="utf-8-sig")).get("tools", {})
except Exception:
    raise SystemExit

name = os.environ.get("TOOL", "")
candidates = [name]
m = re.match(r"^mcp__(.+?)__(.+)$", name)
if m:
    server, short = m.group(1), m.group(2)
    candidates += ["%s.%s" % (server, short), short]
    candidates += [k for k in tools if k.endswith("." + short)]

for key in candidates:
    entry = tools.get(key)
    if not isinstance(entry, dict):
        continue
    if entry.get("risk_level") in ("high", "critical") and entry.get("default_action") == "deny":
        print("%s	%s" % (key, entry.get("risk_level")))
    break
REG
)
    if [ -n "$REG_VERDICT" ]; then
        REG_KEY=$(printf '%s' "$REG_VERDICT" | cut -f1)
        REG_RISK=$(printf '%s' "$REG_VERDICT" | cut -f2)
        REASON="Tool '$TOOL_NAME' (registry key '$REG_KEY') has risk level '$REG_RISK' - deny-by-default"
        deny_to_stderr "$REASON" "$TOOL_NAME" "$COMMAND_STRING"
        persist_deny "$TOOL_NAME" "deny-by-default ($REG_RISK)" "$COMMAND_STRING" || true
        echo "{\"permissionDecision\":\"deny\",\"reason\":\"$REASON\",\"tool\":\"$TOOL_NAME\"}"
        exit 2
    fi
fi

# --- Server-side PDP consult (H4/H5) — opt-in via portal-sync.json pdp_enforce.
# Best-effort/fail-open (C10: defense-in-depth + server decision, not a hard
# boundary). Only for high-risk shapes, to avoid latency on ordinary calls.
# Resolve WHERE portal-sync.json lives (see the PS twin for the full
# rationale). Since Portal v2 P1 1.7 it holds no per-machine field (member_email
# moved to .harness/local/) and may be committed, but older projects still gitignore
# it and the ingest KEY never travels with git: in a git WORKTREE they exist only in the
# MAIN checkout; looking solely under HARNESS_ROOT silently skipped the PDP
# consult (C12). git's own common-dir is the authority for the main root
# (C13). HARNESS_ROOT itself stays the worktree -- commit_head must be THIS
# checkout's HEAD -- so the key path travels separately as SYNC_KEY_FILE.
SYNC_ROOT="$HARNESS_ROOT"
if [ ! -f "$SYNC_ROOT/.harness/portal-sync.json" ] && [ -f "$HARNESS_ROOT/.git" ]; then
    _common=$(git -C "$HARNESS_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    [ -n "$_common" ] && SYNC_ROOT=$(dirname "$_common")
fi
SYNC_CFG="$SYNC_ROOT/.harness/portal-sync.json"
if [ -n "$COMMAND_STRING" ] && [ -f "$SYNC_CFG" ]; then
    PDP_JSON=$(SYNC_CFG="$SYNC_CFG" TOOL="$TOOL_NAME" CMD="$COMMAND_STRING" \
      HARNESS_ROOT="$HARNESS_ROOT" KEY_ENV="${HARNESS_PORTAL_INGEST_KEY:-}" \
      SYNC_KEY_FILE="$SYNC_ROOT/.harness/portal-sync.key" \
      SESSION="${HARNESS_SESSION_ID:-}" USER_ENV="${HARNESS_USER:-}" \
      AUTH_LIB="$HARNESS_ROOT/.harness/scripts/lib/harness_checkout_facts.py" \
      HOST_ENV="$(hostname 2>/dev/null || echo '')" python3 - <<'PY' 2>/dev/null || true
import os, json, re, subprocess, sys, urllib.request
try:
    cfg = json.load(open(os.environ["SYNC_CFG"], encoding="utf-8-sig"))
except Exception:
    raise SystemExit
if not (cfg.get("pdp_enforce") is True and cfg.get("portal_url") and cfg.get("project_id")):
    raise SystemExit
tool = os.environ.get("TOOL", ""); cmd = os.environ.get("CMD", "")
# Two separate ways a real release reached NO gate at all; keep both fixes.
#
# 1. `docker\s+compose\s+up` was matched LITERALLY, so the form every script in
#    this repo actually uses -- `docker compose -f a.yml -f b.yml up -d` -- was
#    never sent, and a compose release issued through a shell got no PDP
#    decision: no gate, no approval, not even a decision row. Any compose
#    command is now sent; the server decides which subcommands mutate.
# 2. `mcp__codeprovider-mcp__deploy` is not the string "deploy", so the
#    shortlist never matched a real MCP call until this normalisation.
#
# Kept deliberately BROAD otherwise (a bare `deploy` still matches a command
# that merely names a deploy file): over-asking costs one round trip answered
# allow, while under-asking silently ungates a release. The precise
# mention-vs-invocation rule stays server-side, in app/core/pdp.py.
# Must stay in step with harness-runtime-guard.ps1 (C7 parity).
_m = re.match(r"^mcp__(.+?)__(.+)$", tool)
short_tool = _m.group(2) if _m else tool
high = re.search(r"(?i)\b(curl|wget|Invoke-WebRequest|iwr|nc|ncat|http_fetch|deploy|drop\s+table|truncate\s+table|delete\s+from|alter\s+table)\b", cmd) \
       or re.search(r"(?i)\bdocker[-\s]+compose\b", cmd) \
       or re.search(r"(?i)(deploy|release|\bkubectl\s+apply\b|\bhelm\s+(install|upgrade)\b|\bterraform\s+apply\b|\bansible-playbook\b)", cmd) \
       or short_tool in ("deploy","rollback_deploy","mysql_query","exec_in_container","http_fetch")
if not high:
    raise SystemExit
# Portal v2 P1 1.2b: authenticate with the CHECKOUT credential (X-Checkout-Id +
# X-Checkout-Credential, and NOT the shared key) when this machine holds one; the
# server derives checkout and member from it, so a "declared" actor cannot borrow
# someone else's approval. The shared key is the legacy fallback only. The shared
# reader is loaded INSIDE this already-running python: no extra process on any path.
# The value goes into the request headers and nowhere else (C5). Parity with the .ps1 (C7).
def _native(p):
    m = re.match(r"^/([a-zA-Z])/(.*)$", p)
    return "%s:/%s" % (m.group(1), m.group(2)) if (m and os.name == "nt") else p

fm = None
headers = {}
src = "none"
try:
    import importlib.util
    lib = _native(os.environ.get("AUTH_LIB", ""))
    if lib and os.path.isfile(lib):
        spec = importlib.util.spec_from_file_location("harness_checkout_facts", lib)
        fm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fm)
        a = fm.checkout_auth(_native(os.environ["HARNESS_ROOT"]))
        if a:
            headers = {"X-Checkout-Id": a["checkout_id"], "X-Checkout-Credential": a["checkout_credential"]}
            src = "checkout"
except Exception:
    headers = {}
if not headers:
    key = os.environ.get("KEY_ENV") or ""
    if not key:
        # From SYNC_KEY_FILE (already worktree-resolved by the shell), NOT
        # derived from HARNESS_ROOT -- which stays the worktree for commit_head.
        kf = os.environ.get("SYNC_KEY_FILE", "")
        if kf and os.path.isfile(kf):
            key = open(kf, encoding="utf-8").read().strip()
    if key:
        headers = {"X-Ingest-Key": key}
        src = "legacy-key"
if not headers:
    raise SystemExit
# Legacy path: at most one line a day per machine (stamp file), never per tool call (C14).
warn = ""
if src == "legacy-key" and fm is not None:
    try:
        warn = fm.legacy_warning("harness-runtime-guard")
    except Exception:
        warn = ""
url = cfg["portal_url"].rstrip("/") + "/api/pdp/" + cfg["project_id"] + "/decide"
# Actor identity: prefer the per-machine human identity (same convention as the
# ledger-deny actor in persist_deny()) so the Portal can resolve a real requester,
# not a session id nobody can read (C10). Fall back to session id only when the
# developer machine has no HARNESS_USER configured, so we still send *something*.
actor = os.environ.get("USER_ENV") or os.environ.get("SESSION", "")
actor_host = os.environ.get("HOST_ENV", "")
# H3 pipeline-record gate: resolve what HEAD actually is on this checkout right
# now (deploy takes no commit of its own -- it pulls HEAD), not a caller claim.
# Best-effort: no git / not a repo -> empty string, which the gate (only when
# its opt-in toggle is on) reports as unverifiable rather than guessing.
commit_head = ""
try:
    commit_head = subprocess.check_output(
        ["git", "-C", os.environ["HARNESS_ROOT"], "rev-parse", "HEAD"],
        stderr=subprocess.DEVNULL, timeout=5,
    ).decode().strip()
except Exception:
    pass
body = json.dumps({"tool": tool, "command": cmd, "actor": actor, "actor_host": actor_host, "commit_head": commit_head}).encode()
req = urllib.request.Request(url, data=body, method="POST",
    headers={"Content-Type": "application/json", "User-Agent": "harness-runtime-guard/1.0", **headers})
js = ""
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        d = json.load(r)
    js = json.dumps({"decision": d.get("decision"), "reason": d.get("reason", ""), "approval_id": d.get("approval_id", "")})
except Exception as _e:
    js = ""
    # Fail-open stays, but an explicit server 401/403 (revoked / disabled / legacy window closed)
    # is not "the network is down": say so, once a day (own stamp, same dir + 24h TTL, C14).
    try:
        if getattr(_e, "code", 0) in (401, 403) and fm is not None:
            _rw = fm.rejected_warning("harness-runtime-guard")
            if _rw:
                warn = (warn + " " + _rw).strip()
    except Exception:
        pass
# Two lines: the legacy warning (often empty), then the decision JSON (empty on a
# network error -- fail-open). The shell splits them with parameter expansion, so
# the warning costs no process.
try:
    sys.stdout.reconfigure(newline="\n")
except Exception:
    pass
sys.stdout.write(warn.replace("\n", " ") + "\n" + js + "\n")
PY
)
    # Line 1: the throttled legacy-key warning (usually empty); line 2: the decision JSON.
    PDP_WARN=""
    if [ -n "$PDP_JSON" ]; then
        PDP_OUT="$PDP_JSON"
        PDP_WARN="${PDP_OUT%%$'\n'*}"; PDP_WARN="${PDP_WARN%$'\r'}"
        if [ "$PDP_OUT" != "$PDP_WARN" ]; then
            PDP_JSON="${PDP_OUT#*$'\n'}"; PDP_JSON="${PDP_JSON%%$'\n'*}"; PDP_JSON="${PDP_JSON%$'\r'}"
        else
            PDP_JSON=""
        fi
    fi
    if [ -n "$PDP_WARN" ]; then printf '%s\n' "$PDP_WARN" >&2; fi
    if [ -n "$PDP_JSON" ]; then
        PDP_DECISION=$(echo "$PDP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('decision',''))" 2>/dev/null)
        if [ "$PDP_DECISION" = "deny" ] || [ "$PDP_DECISION" = "ask" ]; then
            PDP_REASON=$(echo "$PDP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('reason',''))" 2>/dev/null)
            deny_to_stderr "PDP $PDP_DECISION: $PDP_REASON" "$TOOL_NAME" "$COMMAND_STRING"
            persist_deny "$TOOL_NAME" "pdp:$PDP_DECISION" "$COMMAND_STRING" || true
            echo "{\"permissionDecision\":\"deny\",\"reason\":\"PDP $PDP_DECISION: $PDP_REASON\",\"tool\":\"$TOOL_NAME\"}"
            exit 2
        fi
    fi
fi

# ---------------------------------------------------------------- F2 (B0)
# Sensitivity gate, parity with the .ps1 (C7). Everything above judges the
# COMMAND; this judges the TARGET of a file write. Before 1.8.6 the bash guard
# had no F2 at all, so on Linux/macOS a Write into migrations/ or a .env file was
# never escalated. Same config (sensitive-paths.json), same matcher
# (lib/harness_sensitivity.py), same message text as Write-DenyToStderr's caller.
# Runs only when enforce_at_pretooluse is true. FAIL-OPEN on any error: a
# sensitivity check that cannot run must never brick a shell.
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit)
        F2_VERDICT=$(TOOL_INPUT="$TOOL_INPUT" F2_ROOT="$HARNESS_ROOT" F2_TOOL="$TOOL_NAME" \
            F2_MATCHER="$(cd "$(dirname "$0")" && pwd)/../lib/harness_sensitivity.py" \
            python3 - <<'F2' 2>/dev/null || true
import json, os, re, subprocess, sys

def native(p):
    # Git Bash hands out /e/x paths; a Windows python needs E:/x.
    m = re.match(r"^/([a-zA-Z])/(.*)$", p)
    return "%s:/%s" % (m.group(1), m.group(2)) if (m and os.name == "nt") else p

try:
    root = native(os.environ["F2_ROOT"]).replace("\\", "/").rstrip("/")
    cfg = json.load(open(os.path.join(root, ".harness", "control", "sensitive-paths.json"),
                         encoding="utf-8-sig"))
    if cfg.get("enforce_at_pretooluse") is True:
        ti = json.loads(os.environ.get("TOOL_INPUT") or "{}")
        target = next((str(ti[k]) for k in ("file_path", "path", "notebook_path") if ti.get(k)), "")
        rel = native(target).replace("\\", "/")
        if rel.lower().startswith(root.lower() + "/"):
            rel = rel[len(root) + 1:]
        if rel:
            out = subprocess.run([sys.executable, native(os.environ["F2_MATCHER"]), root,
                                  "--path", rel, "--json"], capture_output=True, text=True, timeout=20)
            v = json.loads(out.stdout) if out.returncode == 0 else {}
            if v.get("rule") and v.get("tier") in ("high", "critical"):
                why = ("F2 sensitivity: '%s' khop rule '%s' -> diem %s (tier %s). %s Can nguoi duyet truoc khi ghi."
                       % (rel, v["rule"], v.get("score"), v["tier"], v.get("reason", "")))
                # F2 approval path (P1 1.0), parity with the .ps1 (C7). Only for a rule
                # sensitive-paths.json marks `approvable` (C2). The matcher does the HTTP
                # call and the content hash, so both guards send the same bind. ONLY an
                # exact "allow" lets the write through: no portal-sync.json, Portal down,
                # garbled reply, pending, rejected -- all stay DENIED. Defense-in-depth
                # (C10): a shell write never reaches this block.
                if v.get("approvable") is True:
                    pd = {}
                    try:
                        ask = subprocess.run(
                            [sys.executable, native(os.environ["F2_MATCHER"]), root, "--path", rel,
                             "--ask-portal", "--tool", os.environ.get("F2_TOOL", "Write"), "--hook-input-stdin"],
                            input=json.dumps({"tool_input": ti}).encode("utf-8"),
                            capture_output=True, timeout=30)
                        if ask.returncode == 0:
                            pd = json.loads(ask.stdout.decode("utf-8"))
                    except Exception:
                        pd = {}
                    if pd.get("decision") == "allow":
                        raise SystemExit(0)      # approved: print nothing -> the guard allows
                    if pd.get("decision") not in (None, "skip"):
                        if pd.get("approval_id"):
                            why += (" Portal: %s (approval_id=%s) - nguoi duyet vao Portal > Approvals duyet dung file nay, roi chay lai."
                                    % (pd.get("decision"), pd.get("approval_id")))
                        else:
                            why += " Khong hoi duoc Portal (%s) - giu nguyen chan." % pd.get("reason", "")
                print(json.dumps({"rel": rel, "rule": v["rule"], "why": why}))
except Exception:
    pass
F2
)
        if [ -n "$F2_VERDICT" ]; then
            F2_REL=$(printf '%s' "$F2_VERDICT" | python3 -c "import sys,json;print(json.load(sys.stdin)['rel'])" 2>/dev/null || true)
            F2_RULE=$(printf '%s' "$F2_VERDICT" | python3 -c "import sys,json;print(json.load(sys.stdin)['rule'])" 2>/dev/null || true)
            F2_WHY=$(printf '%s' "$F2_VERDICT" | python3 -c "import sys,json;print(json.load(sys.stdin)['why'])" 2>/dev/null || true)
            if [ -n "$F2_WHY" ]; then
                deny_to_stderr "$F2_WHY" "$TOOL_NAME" "$F2_REL"
                persist_deny "$TOOL_NAME" "sensitivity:$F2_RULE" "$F2_REL" || true
                printf '%s' "$F2_WHY" | TOOL="$TOOL_NAME" python3 -c "import sys,json,os;print(json.dumps({'permissionDecision':'deny','reason':sys.stdin.read(),'tool':os.environ['TOOL']}))" 2>/dev/null || true
                exit 2
            fi
        fi
        ;;
esac

exit 0
