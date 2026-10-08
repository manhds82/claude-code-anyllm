#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Push local .harness telemetry to the Control Portal (push-ingest API).
.DESCRIPTION
  For dev machines whose checkout path the Portal backend cannot read (e.g.
  Windows E:\ checkouts). Reads the local telemetry/ledger files and POSTs
  their contents to POST {portal_url}/api/ingest/{project_id}. The backend
  runs the same ingest pipeline it uses for server checkouts (same dedupe),
  so re-pushing the same files is safe and idempotent.

  Config: .harness/portal-sync.json
    { "portal_url": "https://<portal-host>", "project_id": "<uuid>" }
  Ingest key (C5 — never commit it): either env HARNESS_PORTAL_INGEST_KEY or
  the git-ignored file .harness/portal-sync.key (single line).

  Wired into harness-session-end.ps1 (best-effort) so every session pushes
  automatically; safe to run by hand any time.
#>
param(
    [string]$HarnessRoot = "",
    # Send only "this checkout is alive and this is what it looks like" (P1 1.3).
    [switch]$Heartbeat
)

$ErrorActionPreference = "Stop"

if (-not $HarnessRoot) {
    $HarnessRoot = $env:HARNESS_ROOT
    if (-not $HarnessRoot) { $HarnessRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path }
}

# --- Codex usage, collected HERE rather than only at Claude session end (B9b) --
#
# Same reasoning as the self-healing resample further down: capture usage even
# if the hook never fired. For Codex that is not an edge case but the normal
# one -- Codex has no hook at all, so its only trigger was a CLAUDE session
# ending in this same project. A project worked on with Codex only would have
# reported nothing, forever, while the collector sat installed and looking fine.
#
# In the pusher, so every caller is covered at once: the session-end hook, the
# fleet driver on its timer (which needs no Claude), and a manual push. One
# place -- three copies of the release classifier drifting apart (B-13/B-14) is
# the argument against repeating it per caller.
#
# BEFORE the config checks below, all of which `exit 0` on an unconfigured
# project. Collecting is local work and worth doing regardless: this repo's own
# umbrella root still carries the installer's placeholder portal_url, and it is
# exactly the directory Codex records as its cwd. Collect there anyway and the
# data is waiting the moment someone wires it up; collect only after the checks
# and it is lost for good.
#
# Best-effort, and silent about the ordinary case: most machines run no Codex.
try {
    $CodexCollector = Join-Path $PSScriptRoot "collect-codex.ps1"
    if (Test-Path $CodexCollector) { & $CodexCollector -HarnessRoot $HarnessRoot *>$null }
} catch { }

$ConfigFile = Join-Path $HarnessRoot ".harness\portal-sync.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Output "[push-telemetry] No .harness/portal-sync.json -- push sync not configured, skipping."
    exit 0
}
$Config = Get-Content -Path $ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $Config.portal_url -or -not $Config.project_id) {
    Write-Warning "[push-telemetry] portal-sync.json missing portal_url/project_id"
    exit 0
}
# The installer scaffolds this placeholder; left unfilled it fails as a DNS
# error, which reads as a network problem and sends whoever is looking at the
# wrong thing entirely. Say what is actually wrong (moved here from
# harness-sync.local.ps1 so every caller of this script gets the clear message,
# not just the fleet-wide loop).
if ("$($Config.portal_url)" -like "*YOUR-PORTAL-DOMAIN*") {
    Write-Warning ("[push-telemetry] portal_url is still the installer placeholder ({0}) -- fill in .harness/portal-sync.json" -f $Config.portal_url)
    exit 0
}

# Checkout identity (Portal v2 P1 1.3). One shared python lib computes what this
# folder can say about itself -- who it claims to be, its receipt, the release its
# files really match, git remote/branch/HEAD/dirty -- so this script and its bash
# twin cannot drift on the payload. Best-effort: no python / no lib = no facts, and
# the push goes out exactly as before.
$Facts = $null
try {
    $FactsLib = Join-Path $HarnessRoot ".harness\scripts\lib\harness_checkout_facts.py"
    if (Test-Path $FactsLib) {
        $pyf = Get-Command python -ErrorAction SilentlyContinue
        if (-not $pyf) { $pyf = Get-Command python3 -ErrorAction SilentlyContinue }
        if ($pyf) {
            $fj = (& $pyf.Source $FactsLib $HarnessRoot 2>$null) -join ""
            if ($fj) { $Facts = $fj | ConvertFrom-Json }
        }
    }
} catch { $Facts = $null }

# member_email (Portal v2 P1 1.7): names one PERSON, so it lives in the git-ignored
# .harness/local/checkout.json, not in the committable portal-sync.json. The shared reader
# falls back to the old place and says where the value came from (C13): a legacy or missing
# value is a warning here, never a silent pass.
$MemberEmail = ""
$MemberFromLib = $false
try {
    $StateLib = Join-Path $HarnessRoot ".harness\scripts\lib\harness_local_state.py"
    if (Test-Path $StateLib) {
        $pym = Get-Command python -ErrorAction SilentlyContinue
        if (-not $pym) { $pym = Get-Command python3 -ErrorAction SilentlyContinue }
        if ($pym) {
            $mj = (& $pym.Source $StateLib member-email $HarnessRoot 2>$null) -join ""
            if ($mj) {
                $Me = $mj | ConvertFrom-Json
                $MemberEmail = "$($Me.value)"; $MemberFromLib = $true
                if ($Me.warning) { Write-Warning "[push-telemetry] $($Me.warning)" }
            }
        }
    }
} catch { }
if (-not $MemberFromLib -and $Config.member_email) {
    $MemberEmail = "$($Config.member_email)"
    Write-Warning "[push-telemetry] member_email read from the legacy .harness/portal-sync.json (harness_local_state.py unavailable -- no python or no lib)"
}

# The checkout credential (git-ignored .harness/local/checkout.json, or env) is
# sent as headers when this machine holds one; otherwise the legacy shared key.
$CheckoutId = ""; $CheckoutCred = ""
if ($Facts -and $Facts.auth) {
    $CheckoutId = "$($Facts.auth.checkout_id)"
    $CheckoutCred = "$($Facts.auth.checkout_credential)"
}

# Ingest key: env wins, then git-ignored key file (C5: never in the repo).
$IngestKey = $env:HARNESS_PORTAL_INGEST_KEY
if (-not $IngestKey) {
    $KeyFile = Join-Path $HarnessRoot ".harness\portal-sync.key"
    if (Test-Path $KeyFile) { $IngestKey = (Get-Content -Path $KeyFile -Raw).Trim() }
}
if (-not $IngestKey -and -not $CheckoutCred) {
    Write-Warning "[push-telemetry] No checkout credential (.harness/local/checkout.json) and no ingest key (env HARNESS_PORTAL_INGEST_KEY or .harness/portal-sync.key)"
    exit 0
}
if ($CheckoutCred) {
    $AuthHeaders = @{ "X-Checkout-Id" = $CheckoutId; "X-Checkout-Credential" = $CheckoutCred }
} else {
    $AuthHeaders = @{ "X-Ingest-Key" = $IngestKey }
    # Legacy path (no checkout enrolled on this machine): say so at most once a day, per
    # machine, via the shared stamp (C14) -- never per push. Names no key.
    try {
        $LegacyLib = Join-Path $HarnessRoot ".harness\scripts\lib\harness_checkout_facts.py"
        $pyw = Get-Command python -ErrorAction SilentlyContinue
        if (-not $pyw) { $pyw = Get-Command python3 -ErrorAction SilentlyContinue }
        if ($pyw -and (Test-Path $LegacyLib)) {
            $lw = (& $pyw.Source $LegacyLib --legacy-warning push-telemetry 2>$null) -join ""
            if ($lw) { Write-Warning $lw }
        }
    } catch { }
}

function Add-CheckoutFacts([hashtable]$Target) {
    <#  The claims a push makes about its machine. The server COMPARES these with
        what it holds for the credential; it never uses them to pick the checkout. #>
    if (-not $Facts) { return }
    foreach ($k in 'checkout_id', 'device_id', 'path_hash', 'receipt', 'receipt_at_head',
                   'git_remote', 'git_branch', 'git_head') {
        if ($Facts.$k) { $Target[$k] = "$($Facts.$k)" }
    }
    if ($null -ne $Facts.git_dirty) { $Target['git_dirty'] = [bool]$Facts.git_dirty }
    if ($Facts.disk_fingerprint) { $Target['disk_fingerprint'] = $Facts.disk_fingerprint }
    if ($Facts.worktree) { $Target['worktree'] = $true }
}

if ($Heartbeat) {
    if (-not $CheckoutCred) {
        Write-Output "[push-telemetry] heartbeat needs a checkout credential (.harness/local/checkout.json) -- skipped."
        exit 0
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $hb = @{}
        Add-CheckoutFacts $hb
        $HbUrl = "$($Config.portal_url.TrimEnd('/'))/api/ingest/$($Config.project_id)/heartbeat"
        $HbResp = Invoke-RestMethod -Uri $HbUrl -Method Post -ContentType "application/json; charset=utf-8" `
            -Headers $AuthHeaders -UserAgent "harness-push-telemetry/1.0" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes(($hb | ConvertTo-Json -Depth 6 -Compress))) -TimeoutSec 30
        if ($HbResp.quarantined) { Write-Warning "[push-telemetry] $($HbResp.note)" }
        else { Write-Output "[push-telemetry] heartbeat OK" }
    } catch {
        Write-Warning "[push-telemetry] Heartbeat failed: $($_.Exception.Message)"
    }
    exit 0
}

function Read-IfExists([string]$Path) {
    if (Test-Path $Path) {
        # utf8 read strips BOM; returns "" for empty files
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }
    return ""
}

# Resolved HERE, not next to the $Body that consumes them: $PushCursorFile below
# is built from $Tel, and when the assignment sat further down the file $Tel was
# still $null at that point. Join-Path then threw on a null Path and the script
# died before doing anything -- with $ErrorActionPreference = "Stop" and a hook
# that swallows output, every project on 1.6.0 lost telemetry in total silence.
$Tel    = Join-Path $HarnessRoot ".harness\telemetry"
$Ledger = Join-Path $HarnessRoot ".harness\ledger"

# A repo the bundle just installed into, with zero Claude Code sessions run in
# it yet, genuinely has no .harness\telemetry\ -- nothing has ever written to
# it. WriteAllText on the cursor files below then throws DirectoryNotFoundException,
# every single run, forever (it never gets created on its own). The bash twin
# already does this (os.makedirs(tel, exist_ok=True)); this was a real C7 gap,
# found by running the driver against 6 freshly-installed repos and reading
# what it actually printed, not by inspecting the code.
New-Item -ItemType Directory -Force -Path $Tel | Out-Null

# --- Incremental send for the append-only logs ---------------------------------
# These files only ever grow, and the push used to send each one WHOLE on every
# run. This repo's own chain.jsonl reached 24.8 MB against the ingest endpoint's
# 10 MB per-field cap, and another project's reached 3.0 MB -- and the failure did
# NOT surface as a clean 413. The body was cut off mid-write, so the client saw
# "connection aborted" / "write operation timed out", i.e. a network error. Nobody
# reading that message would suspect a size limit, which is why telemetry for the
# two largest projects had been silently failing.
#
# Safe to send only the tail because every one of these ingests dedupes
# server-side -- chain.jsonl by entry_hash, tool-calls.log by line hash,
# security-events.jsonl by source_ref, test-reports by ref. So an overlapping or
# even a full re-send can never double-count; the cursor is an optimisation, not
# a correctness requirement. That is what makes losing the cursor harmless.
$PushCursorFile = Join-Path $Tel ".push-cursor.json"
$MaxFieldBytes = 4MB   # well under the server's 10 MB, leaving room for the envelope

$PushCursors = @{}
if (Test-Path $PushCursorFile) {
    try {
        $cj = Get-Content -Path $PushCursorFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($p in $cj.PSObject.Properties) { $PushCursors[$p.Name] = [int64]$p.Value }
    } catch { }   # unreadable cursor = send from 0; dedupe makes that safe
}
$PushCursorsNew = @{}

# S-3 — content-hash skip for the two payload parts that are SNAPSHOTS, not
# append-only logs. chain.jsonl and friends grow, so a byte cursor works; the
# CASAN snapshot and the evidence bundles are re-sent whole every push, which on
# this repo is ~2 MB of identical JSON every five minutes. That is the shape of
# cost that gets a sync switched off, and a sync nobody runs is the failure the
# whole evidence pipeline exists to avoid.
#
# Skipping on an unchanged hash alone would be a one-way door: if the Portal
# ever lost the snapshot, the client would never send it again. So the skip
# EXPIRES -- an unchanged snapshot is re-sent in full once a week, which makes
# the optimisation self-healing rather than something someone has to remember.
$ContentStateFile = Join-Path $Tel ".push-content.json"
$ContentState = @{}
if (Test-Path $ContentStateFile) {
    try {
        $csj = Get-Content -Path $ContentStateFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($p in $csj.PSObject.Properties) { $ContentState[$p.Name] = $p.Value }
    } catch { }   # unreadable state = send everything; correctness never depends on it
}
$ContentStateNew = @{}
$FullResendAfterDays = 7

function Test-ContentUnchanged([string]$Key, [string]$Payload) {
    <#  True when this exact content was already accepted recently enough that
        re-sending it would buy nothing. Records the new hash either way. #>
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString(
        $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Payload))) -replace '-', '').ToLower()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ContentStateNew[$Key] = @{ hash = $hash; sent_at = $now }

    $prev = $ContentState[$Key]
    if (-not $prev) { return $false }
    if ("$($prev.hash)" -ne $hash) { return $false }
    $age = $now - [int64]$prev.sent_at
    if ($age -ge ($FullResendAfterDays * 86400)) { return $false }
    # Unchanged and recent: keep the stored sent_at so the weekly resend is
    # measured from the last ACTUAL send, not refreshed on every skip -- or the
    # deadline would never arrive and the self-healing property would be gone.
    $ContentStateNew[$Key] = @{ hash = $hash; sent_at = [int64]$prev.sent_at }
    return $true
}

function Read-Incremental([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { return "" }
    $len = (Get-Item $Path).Length
    $from = 0L
    if ($PushCursors.ContainsKey($Key)) { $from = $PushCursors[$Key] }
    # File shorter than the cursor means it was rotated or truncated, so the
    # cursor points into a file that no longer exists. Start over rather than
    # read from a meaningless offset.
    if ($from -gt $len) { $from = 0L }

    $take = $len - $from
    $truncated = $false
    if ($take -gt $MaxFieldBytes) { $take = [int64]$MaxFieldBytes; $truncated = $true }
    if ($take -le 0) { $PushCursorsNew[$Key] = $len; return "" }

    $buf = New-Object byte[] $take
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { $fs.Seek($from, 'Begin') | Out-Null; $read = $fs.Read($buf, 0, $take) } finally { $fs.Dispose() }
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)

    # Never hand the server a half-written final line: cut back to the last
    # newline and let the remainder go out on the next push. A truncated JSON line
    # would be dropped by the reader anyway, and the cursor would have skipped
    # past it -- losing that entry permanently.
    $lastNl = $text.LastIndexOf("`n")
    if ($lastNl -lt 0) {
        # A single line longer than the whole budget. Sending nothing is the
        # honest outcome; say so rather than shipping a fragment.
        if ($truncated) { Write-Warning "[push-telemetry] $Key : one line exceeds $([int]($MaxFieldBytes/1MB))MB; skipped" }
        $PushCursorsNew[$Key] = $from
        return ""
    }
    $text = $text.Substring(0, $lastNl + 1)
    $PushCursorsNew[$Key] = $from + [System.Text.Encoding]::UTF8.GetByteCount($text)

    if ($from -gt 0 -or $truncated) {
        $msg = "[push-telemetry] $Key : sending $([math]::Round($text.Length/1KB,1))KB from offset $from of $len"
        if ($truncated) { $msg += " (capped; remainder goes next run)" }
        # Write-Host, NOT Write-Output: inside a function every value on the
        # success stream joins the RETURN VALUE, so Write-Output made this
        # return @($msg, $text) instead of $text. The body field then serialized
        # as a JSON array and the server rejected the whole push with 422
        # ("Input should be a valid string") -- losing the other fields too.
        # It only bites from the SECOND push onward, when $from > 0 makes this
        # branch reachable, so a fresh install always looked healthy.
        Write-Host $msg
    }
    return $text
}

# --- Self-healing resample: rebuild agentops.log from THIS project's Claude
# Code transcripts before pushing, so token usage is captured even if the
# SessionEnd sampler never fired. Transcript dirs are matched CASE-INSENSITIVELY
# (Claude Code encodes the drive letter as 'E--' or 'e--') and recursively
# (sub-folders, git worktrees, and subagents/*.jsonl). Best-effort; a failure
# here never blocks the push of whatever agentops.log already exists.
#
# Read-merge-write, NOT blind overwrite: agentops-sampler.ps1 (SubagentStop
# hook) already stamps active_account/active_member onto rows it writes live.
# This block only sees raw transcripts, which carry neither field, so a plain
# "w" rebuild from scratch would erase every stamp on every push -- and for a
# plain (non-delegating) main session, this resample is the ONLY writer, since
# the sampler is wired solely to SubagentStop. Fix: read whatever agentops.log
# already has, keyed the same way (session_id:agent_name); a transcript-derived
# row only replaces an existing one when it has STRICTLY MORE tokens (genuine
# "resumed, more happened" case), and only a replaced/new row gets re-stamped
# with the CURRENT pointer/env values -- coarser than a live per-turn stamp,
# but far better than silently blank. Anything the transcript scan doesn't
# touch at all (rotated out of the transcript window) survives untouched.
try {
    $rs = @'
import os, re, json, glob
from datetime import datetime, timezone
root = os.environ["HS_ROOT"]
home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
proot = os.path.join(home, ".claude", "projects")

def _load_existing(fp):
    # Keyed identically to the transcript scan below so the merge lines up.
    # Unparseable lines are skipped, never allowed to crash the resample.
    d = {}
    try:
        with open(fp, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try: rec = json.loads(line)
                except Exception: continue
                sid = rec.get("session_id"); agent = rec.get("agent_name")
                if not sid or not agent: continue
                d[sid + ":" + agent] = rec
    except OSError:
        pass
    return d

def _active_account():
    # Same global per-machine pointer harness-switch-account writes; absent or
    # unreadable -> "" so an old client (no such file yet) sees the same blank
    # it always has.
    try:
        p = os.path.join(home, ".harness", "active-account.local.json")
        with open(p, encoding="utf-8-sig") as f:
            return str((json.load(f) or {}).get("active_account") or "")
    except Exception:
        return ""

if os.path.isdir(proot):
    e = re.sub(r"[:\\/._]", "-", root).lower()
    dirs = [d for d in glob.glob(os.path.join(proot, "*")) if os.path.isdir(d)
            and (os.path.basename(d).lower() == e or os.path.basename(d).lower().startswith(e + "-"))]
    def sample(fp):
        tin = tout = tools = 0; model = ""; first = last = None; by = {}
        try:
            with open(fp, encoding="utf-8-sig") as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try: rec = json.loads(line)
                    except Exception: continue
                    ts = rec.get("timestamp")
                    if ts: first = first or ts; last = ts
                    if rec.get("type") != "assistant": continue
                    msg = rec.get("message") or {}
                    if not isinstance(msg, dict): continue
                    u = msg.get("usage"); mid = msg.get("id")
                    if u and mid: by[mid] = u
                    m = msg.get("model")
                    if m and m != "<synthetic>": model = m
                    for b in (msg.get("content") or []):
                        if isinstance(b, dict) and b.get("type") == "tool_use": tools += 1
        except OSError:
            return None
        for u in by.values():
            tin += int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0)
            tout += int(u.get("output_tokens") or 0)
        if tin == 0 and tout == 0 and not model: return None
        return {"tin": tin, "tout": tout, "tools": tools, "model": model or "unknown", "first": first, "last": last}
    entries = {}
    for d in dirs:
        for fp in glob.glob(os.path.join(d, "**", "*.jsonl"), recursive=True):
            sid = os.path.splitext(os.path.basename(fp))[0]
            r = sample(fp)
            if not r: continue
            agent = "subagent" if (os.sep + "subagents" + os.sep) in fp else "main"
            k = sid + ":" + agent
            prev = entries.get(k)
            if prev and (prev["tin"] + prev["tout"]) >= (r["tin"] + r["tout"]): continue
            r["sid"] = sid; r["agent"] = agent; entries[k] = r
    if entries:
        tel = os.path.join(root, ".harness", "telemetry"); os.makedirs(tel, exist_ok=True)
        log_path = os.path.join(tel, "agentops.log")
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        active_account = _active_account()
        active_member = os.environ.get("HARNESS_USER") or ""
        # Union base: every row the current file already has, so anything the
        # transcript scan below has no key for is preserved untouched.
        merged = _load_existing(log_path)
        for r in entries.values():
            k = r["sid"] + ":" + r["agent"]
            old_rec = merged.get(k)
            new_tokens = r["tin"] + r["tout"]
            if old_rec is not None:
                old_tokens = int(old_rec.get("tokens_in") or 0) + int(old_rec.get("tokens_out") or 0)
                if old_tokens >= new_tokens:
                    continue  # existing row (and its active_account/active_member) survives untouched
            cost = r["tin"] / 1e6 * 3.0 + r["tout"] / 1e6 * 15.0
            merged[k] = {
                "timestamp": now, "agent_name": r["agent"], "model": r["model"], "session_id": r["sid"],
                "status": "completed", "tokens_in": r["tin"], "tokens_out": r["tout"],
                "total_tokens": r["tin"] + r["tout"], "estimated_cost_usd": round(cost, 6),
                "latency_ms": 0, "tool_calls": r["tools"],
                "start_time": r["first"] or now, "end_time": r["last"] or now,
                "active_account": active_account, "active_member": active_member,
                # Stamped explicitly (B9a). This block reads CLAUDE CODE
                # transcripts, so the value is a fact about the source, not a
                # default. The ingest would infer the same thing from a missing
                # field, but a writer that knows the answer should say it --
                # otherwise the only rows in the file without the stamp are the
                # ones this resample rebuilt, and the next person to read the
                # file has to work out why.
                "assistant": "claude-code",
            }
        with open(log_path, "w", encoding="utf-8") as out:
            for rec in merged.values():
                out.write(json.dumps(rec, separators=(",", ":")) + "\n")
'@
    $py = (Get-Command python3 -ErrorAction SilentlyContinue) ; if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) { $env:HS_ROOT = $HarnessRoot; $rs | & $py.Source - }
} catch { }

$Body = @{
    agentops        = Read-IfExists (Join-Path $Tel "agentops.log")
    chain_jsonl     = Read-Incremental (Join-Path $Ledger "chain.jsonl") "chain.jsonl"
    security_events = Read-Incremental (Join-Path $Tel "security-events.jsonl") "security-events.jsonl"
    tool_calls      = Read-Incremental (Join-Path $Tel "tool-calls.log") "tool-calls.log"
    test_reports    = Read-Incremental (Join-Path $Tel "test-reports.jsonl") "test-reports.jsonl"
    # P-7: Agent Pack runs. The pack shipped to eleven projects with no way to
    # tell whether anyone runs it, let alone whether it works. Incremental like
    # the other append-only logs -- a run log grows for the life of the project
    # and resending it whole every five minutes is how a sync gets switched off.
    pipeline_runs   = Read-Incremental (Join-Path $Tel "pipeline-runs.jsonl") "pipeline-runs.jsonl"
    # S-6: the SHAPE of the whole chain, not its contents. chain_jsonl above is
    # incremental, so the server only ever sees a delta and cannot tell whether
    # the file behind it was rebuilt. Four fields, computed over the full chain
    # here, let the Portal remember where this chain had reached and notice if
    # the next one does not extend it. Best-effort: never block a push.
    ledger_anchor   = $(
        try {
            $ap = Join-Path $HarnessRoot ".harness\scripts\lib\harness_ledger_anchor.py"
            if (Test-Path $ap) {
                $pya = Get-Command python -ErrorAction SilentlyContinue
                if (-not $pya) { $pya = Get-Command python3 -ErrorAction SilentlyContinue }
                if ($pya) { (& $pya.Source $ap $HarnessRoot 2>$null) -join "" } else { "" }
            } else { "" }
        } catch { "" }
    )
    member_email    = $MemberEmail
    buglist         = Read-IfExists (Join-Path $HarnessRoot "buglist.md")
    # S-1: evidence-pipeline self-check, computed at push time. Without it the
    # Portal knows a project's SCORE but not whether its pipeline is alive --
    # state that only ever existed in a developer's terminal, which is how three
    # projects ran for weeks with a dead pipeline whose only symptom was a score
    # that would not move. Best-effort: doctor failing must never block the push.
    doctor          = $(
        try {
            $dp = Join-Path $HarnessRoot ".harness\scripts\lib\harness_doctor.py"
            if (Test-Path $dp) {
                $py = Get-Command python -ErrorAction SilentlyContinue
                if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
                if ($py) { (& $py.Source $dp $HarnessRoot --json 2>$null) -join "" } else { "" }
            } else { "" }
        } catch { "" }
    )
}

# H3 — evidence bundles -> prompt_scores (send {filename: content})
$Bundles = @{}
$BundleDir = Join-Path $Ledger "bundles"
if (Test-Path $BundleDir) {
    foreach ($bf in Get-ChildItem -Path $BundleDir -Filter *.json -File -ErrorAction SilentlyContinue) {
        # Read-IfExists, not Get-Content -Raw: the FileSystem provider hangs
        # PSPath/PSDrive/PSProvider NoteProperties off the string it returns, so
        # ConvertTo-Json emits {"value":"...","PSPath":...} instead of a bare
        # string — and bundles is typed dict[str,str], so the ingest model 422s
        # the ENTIRE push, telemetry included, not just the bundle.
        $Bundles[$bf.Name] = Read-IfExists $bf.FullName
    }
}

# S-3: the bundle set rarely changes between pushes; re-sending every file every
# five minutes is pure repetition. Hashed as sorted name+content so a rename or
# an edit both register as a change.
if ($Bundles.Count -gt 0) {
    $bKey = (($Bundles.Keys | Sort-Object | ForEach-Object { "$_`n$($Bundles[$_])" }) -join "`n--`n")
    if (Test-ContentUnchanged "bundles" $bKey) {
        Write-Host "[push-telemetry] bundles unchanged since last send -- skipped ($($Bundles.Count) file(s))"
        $Bundles = @{}
    }
}
$Body.bundles = $Bundles

# H1 — source<->doc traceability scan (this repo). Best-effort: needs the
# bundle-installed scanner lib + a python interpreter; skipped silently if absent.
$Body.source_doc_map = ""
$DocScan = Join-Path $HarnessRoot ".harness\scripts\lib\harness_docscan.py"
$pyd = (Get-Command python3 -ErrorAction SilentlyContinue); if (-not $pyd) { $pyd = Get-Command python -ErrorAction SilentlyContinue }
if ($pyd -and (Test-Path $DocScan)) {
    try { $Body.source_doc_map = (& $pyd.Source $DocScan $HarnessRoot 2>$null | Out-String).Trim() } catch { }
}
# CASAN evidence snapshot — a push-based project has no server checkout, so
# harness_root_ref is empty and every machine-checked criterion reads not-met.
# Ship the raw files those checks read; scoring stays server-side, so this can
# only cost the project points, never inflate them. Same best-effort contract
# as source_doc_map above: needs python + the bundle-installed lib.
$Body.casan_files = @{}
$Body.casan_manifest = @()
$Body.casan_skipped = @()
$SnapLib = Join-Path $HarnessRoot ".harness\scripts\lib\harness_casan_snapshot.py"
if ($pyd -and (Test-Path $SnapLib)) {
    try {
        # -join "" rather than Out-String: the payload is one very long line and
        # Out-String is a formatter, not a concatenator.
        $SnapRaw = ((& $pyd.Source $SnapLib $HarnessRoot 2>$null) -join "")
        if ($SnapRaw) {
            $Snap = $SnapRaw | ConvertFrom-Json
            # Rehydrate as a hashtable, not the PSCustomObject ConvertFrom-Json
            # returns: PS 5.1 calls any non-null object $true, so an empty
            # PSCustomObject would silently defeat the guard below.
            $cf = @{}
            foreach ($p in $Snap.files.PSObject.Properties) { $cf[$p.Name] = $p.Value }
            $Body.casan_files = $cf
            # @(... | Where-Object { $_ }) so a single-entry list stays an array
            # AND an absent key does not become @($null) -> [null]: the ingest
            # model types these list[dict] and 422s the ENTIRE push on a null
            # element, telemetry included.
            $Body.casan_manifest = @($Snap.manifest | Where-Object { $_ })
            # The third state. Without it the server cannot tell a control we
            # deliberately did not send from one the project does not have, and
            # it scores both as not-met — a false RED is as bad as a false GREEN.
            $Body.casan_skipped = @($Snap.skipped | Where-Object { $_ })
            $Withheld = @($Body.casan_skipped | Where-Object { $_.withheld }).Count
            Write-Output ("[push-telemetry] CASAN snapshot: {0} files, {1} manifest entries, {2} skipped ({3} withheld)" -f `
                $cf.Count, $Body.casan_manifest.Count, $Body.casan_skipped.Count, $Withheld)

            # S-3: hash the WHOLE snapshot -- files, manifest and skipped list.
            # Hashing only the files would let a change in the withheld set slip
            # through unsent, and withheld-vs-absent is the distinction that
            # stops a deliberate omission from scoring as a failure.
            if (Test-ContentUnchanged "casan_snapshot" $SnapRaw) {
                Write-Host "[push-telemetry] CASAN snapshot unchanged since last send -- skipped"
                $Body.casan_files = @{}
                $Body.casan_manifest = @()
                $Body.casan_skipped = @()
            }
        }
    } catch { }
}

# A value counts as content only if it actually carries data. PS 5.1 treats any
# non-null object as $true, so `Where-Object { $_ }` passed the always-present
# (and usually empty) bundles hashtable and this guard could never fire.
$HasContent = $false
foreach ($v in $Body.Values) {
    if ($v -is [string]) { if ($v.Trim()) { $HasContent = $true; break } }
    elseif ($v -is [System.Collections.ICollection]) { if ($v.Count -gt 0) { $HasContent = $true; break } }
    elseif ($v) { $HasContent = $true; break }
}
if (-not $HasContent) {
    Write-Output "[push-telemetry] Nothing to push (no telemetry files yet)."
    exit 0
}

# Claims about this machine ride along only once we know there is something to
# push: they are metadata, and must not turn "nothing new" into a push.
Add-CheckoutFacts $Body
if ($Body.ContainsKey('worktree')) {
    # A worktree pushes into its parent checkout but its chain is its own; the
    # parent anchors the parent's chain.
    $Body.ledger_anchor = ""
}

$Url = "$($Config.portal_url.TrimEnd('/'))/api/ingest/$($Config.project_id)"
try {
    # TLS 1.2 for PS 5.1 boxes that still default to 1.0
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # -Depth 6 is margin, not a fix: casan_manifest and casan_skipped are both
    # arrays of flat objects, which lands at depth 3 (body -> array -> object ->
    # scalar) — past the default of 2, where ConvertTo-Json would silently
    # render an entry as the string "@{path=...; size=...}". Data-shaped enough
    # that the server would store it and nobody would notice.
    $Json = $Body | ConvertTo-Json -Depth 6 -Compress
    # Cloudflare's bot rules 403 generic client UAs; identify as the harness client.
    $Resp = Invoke-RestMethod -Uri $Url -Method Post -ContentType "application/json; charset=utf-8" `
        -Headers $AuthHeaders -UserAgent "harness-push-telemetry/1.0" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($Json)) -TimeoutSec 30
    if ($Resp.quarantined) {
        # Nothing was ingested: do NOT advance the cursors, or the lines in this
        # push would be skipped forever once the cause is fixed.
        Write-Warning "[push-telemetry] QUARANTINED by the Portal -- $($Resp.note)"
        exit 0
    }
    foreach ($w in @($Resp.warnings)) { if ($w) { Write-Warning "[push-telemetry] $w" } }
    Write-Output ("[push-telemetry] OK: actions={0} incidents={1} usage={2} tool_calls={3}" -f `
        $Resp.action_log_ingested, $Resp.security_incidents_ingested, $Resp.usage_events_ingested, $Resp.tool_calls_ingested)

    # Advance the cursors ONLY now. Committing them before the request would mean
    # a failed push permanently skipped those lines -- the ledger would develop a
    # hole no later run could fill, which is the opposite of what an append-only
    # audit trail is for. Re-sending after a failure costs nothing because every
    # ingest dedupes.
    try {
        if ($PushCursorsNew.Count -gt 0) {
            $merged = @{}
            foreach ($k in $PushCursors.Keys)    { $merged[$k] = $PushCursors[$k] }
            foreach ($k in $PushCursorsNew.Keys) { $merged[$k] = $PushCursorsNew[$k] }
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($PushCursorFile, ($merged | ConvertTo-Json -Compress), $enc)
        }
        # S-3: same rule as the cursors -- persisted only AFTER the server
        # accepted the push. Recording a hash for content the server never
        # received would skip it on every later run until the weekly deadline,
        # i.e. lose a snapshot for a week over one failed request.
        if ($ContentStateNew.Count -gt 0) {
            $cmerged = @{}
            foreach ($k in $ContentState.Keys)    { $cmerged[$k] = $ContentState[$k] }
            foreach ($k in $ContentStateNew.Keys) { $cmerged[$k] = $ContentStateNew[$k] }
            $enc2 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($ContentStateFile, ($cmerged | ConvertTo-Json -Depth 4 -Compress), $enc2)
        }
    } catch {
        # A cursor we failed to persist just means the next run re-sends. Warn, but
        # never turn a successful push into a failure over it.
        Write-Warning "[push-telemetry] could not save push cursor: $($_.Exception.Message)"
    }
} catch {
    # Never fail the calling hook on a network error; the next push retries
    # everything anyway (server-side dedupe makes it idempotent).
    #
    # But DO print the server's response body. .Exception.Message is only the
    # status line, so a 422 that names the offending field read as an empty,
    # undiagnosable error — a consuming project lost days to exactly that.
    # On Windows PowerShell 5.1 the body is in $_.ErrorDetails.Message:
    # Invoke-RestMethod has ALREADY drained the response stream by the time it
    # throws, so GetResponseStream() hands back an empty reader (measured — the
    # obvious-looking stream read returns ''). Keep the stream as a fallback for
    # hosts where ErrorDetails is not populated.
    $detail = ""
    try { $detail = "$($_.ErrorDetails.Message)" } catch { }
    if (-not $detail) {
        try {
            $r = $_.Exception.Response
            if ($r) {
                $sr = New-Object System.IO.StreamReader($r.GetResponseStream())
                $detail = $sr.ReadToEnd()
                $sr.Close()
            }
        } catch { }
    }
    if ($detail) {
        if ($detail.Length -gt 800) { $detail = $detail.Substring(0, 800) + "…" }
        Write-Warning "[push-telemetry] Push failed: $($_.Exception.Message)`n  server said: $detail"
    } else {
        Write-Warning "[push-telemetry] Push failed: $($_.Exception.Message)"
    }
}
exit 0
