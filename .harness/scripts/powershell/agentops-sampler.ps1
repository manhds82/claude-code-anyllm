#!/usr/bin/env pwsh
<#
.SYNOPSIS
  AgentOps Sampler (H6) — records token/cost/latency per agent run.
  Designed to run as SubagentStop hook and Stop hook.
.DESCRIPTION
  Reads agent stop event from stdin JSON, extracts metrics,
  appends to .harness/telemetry/agentops.log as JSONL.

  Fields recorded:
    - agent_name, model, session_id
    - tokens_in, tokens_out, total_tokens
    - estimated_cost_usd (using ~$3/M input, ~$15/M output for Opus)
    - latency_ms, start_time, end_time
    - tool_calls_count, status (success/error/interrupted)
.NOTES
  H6: This is the foundation for cost metering and drift detection.
  D10: Cost measured per-agent-run at the gateway in production.
#>

$InputJson = $input | Out-String
if (-not $InputJson -or $InputJson.Trim() -eq "") {
    exit 0
}

try {
    $Event = $InputJson | ConvertFrom-Json
} catch {
    exit 0
}

$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) { $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.." }

$TelemetryDir = "$HarnessRoot\.harness\telemetry"
if (-not (Test-Path $TelemetryDir)) { New-Item -ItemType Directory -Path $TelemetryDir -Force | Out-Null }

# Append one JSONL line WITHOUT a BOM. `Add-Content -Encoding utf8` on Windows
# PowerShell 5.1 always writes EF BB BF when it creates the file, so the FIRST
# line of a .jsonl becomes unparseable to any reader doing json.loads per line
# (od -c shows 357 273 277 before the opening brace). Reported from a consuming
# project whose test-reports.jsonl could not be read back.
#
# Was previously DEFINED NESTED inside Coalesce's body below -- a nested
# `function` statement only materializes into the interpreter's function table
# when its parent function actually EXECUTES that line, scoped to that single
# invocation, and is gone once the parent returns. That meant Add-JsonLine was
# never callable from script scope where it's actually used further down --
# every call failed "term not recognized" and agentops.log/daily-*.jsonl were
# NEVER written, silently (a non-terminating error, so the script kept going).
# Moved to top-level/script scope, unchanged otherwise, so it's actually callable.
function Add-JsonLine([string]$Path, [string]$Line) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, $enc)
}

# PS5.1-compatible null-coalescing helper.
# PowerShell's -or operator always returns a boolean ($true/$false), NEVER the operand
# value — so $x -or "default" produces $true, not $x. Use this helper instead.
function Coalesce {
    param([object[]]$Values)
    foreach ($v in $Values) {
        if ($null -ne $v -and "$v".Trim() -ne '') { return $v }
    }
    return $null
}

# Extract agent info
$DefaultAgent = if ($Event.hook_event_name -eq "SubagentStop") { "subagent" } else { "main" }
$AgentName = Coalesce @($Event.agent_name, $Event.agent_type, $Event.agent, $DefaultAgent)
$ModelName  = Coalesce @($Event.model, "unknown")
$SessionId  = Coalesce @($Event.session_id, $env:HARNESS_SESSION_ID, "unknown")
$Status     = Coalesce @($Event.status, "completed")

# --- Real usage: sum the transcript JSONL. The hook payload does NOT carry
# token counts — assistant messages inside the transcript do (message.usage).
# Same message id can repeat (streamed chunks) — last usage per id wins.
$TokensIn = 0; $TokensOut = 0; $ToolCalls = 0
$FirstTs = $null; $LastTs = $null
$TranscriptPath = Coalesce @($Event.agent_transcript_path, $Event.transcript_path)
# Fallback: some third-party launchers don't pass transcript_path
# in the hook payload. Locate the transcript by session id under the standard
# Claude Code projects dir so token sampling still works.
if ((-not $TranscriptPath) -or (-not (Test-Path $TranscriptPath))) {
    $projRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".claude\projects"
    if ($SessionId -and $SessionId -ne "unknown" -and (Test-Path $projRoot)) {
        $found = Get-ChildItem -Path $projRoot -Recurse -Filter "$SessionId.jsonl" -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { $TranscriptPath = $found.FullName }
    }
}
if ($TranscriptPath -and (Test-Path $TranscriptPath)) {
    # [long] accumulators: a heavy resumed session can exceed Int32.
    [long]$TokensIn = 0; [long]$TokensOut = 0
    $UsageByMsg = @{}
    foreach ($line in [System.IO.File]::ReadLines($TranscriptPath)) {
        if (-not $line.Trim()) { continue }
        try { $rec = $line | ConvertFrom-Json } catch { continue }
        if ($rec.timestamp) {
            if (-not $FirstTs) { $FirstTs = $rec.timestamp }
            $LastTs = $rec.timestamp
        }
        if ($rec.type -ne "assistant" -or -not $rec.message) { continue }
        $msg = $rec.message
        if ($msg.usage -and $msg.id) {
            # Dedupe by message id (streamed chunks repeat the same id). Only
            # real message ids -- never fall back to a positional key, which
            # would count every message separately and multi-count.
            $UsageByMsg[$msg.id] = $msg.usage
        }
        if ($msg.model -and $msg.model -ne "<synthetic>") { $ModelName = $msg.model }
        foreach ($block in @($msg.content)) {
            if ($block -and $block.type -eq "tool_use") { $ToolCalls++ }
        }
    }
    # tokens_in = NEW input only (uncached input + newly-created cache).
    # cache_read_input_tokens is DELIBERATELY excluded: it's the same context
    # re-read every turn, so summing it over N turns multi-counts the same
    # tokens (a 7000-turn session showed 1.6B phantom tokens). Cache reads are
    # cheap re-reads, not new work.
    foreach ($u in $UsageByMsg.Values) {
        $TokensIn += [long](Coalesce @($u.input_tokens, 0)) + [long](Coalesce @($u.cache_creation_input_tokens, 0))
        $TokensOut += [long](Coalesce @($u.output_tokens, 0))
    }
}

# Legacy fallback: explicit numeric fields on the event itself
if ($TokensIn -eq 0 -and $TokensOut -eq 0) {
    $UsageIn  = if ($Event.usage) { $Event.usage.input_tokens  } else { $null }
    $UsageOut = if ($Event.usage) { $Event.usage.output_tokens } else { $null }
    $TokensIn  = [int](Coalesce @($Event.tokens_in,  $Event.input_tokens,  $UsageIn,  0))
    $TokensOut = [int](Coalesce @($Event.tokens_out, $Event.output_tokens, $UsageOut, 0))
    if ($ToolCalls -eq 0) { $ToolCalls = [int](Coalesce @($Event.tool_calls, $Event.tool_calls_count, 0)) }
}
$TotalTokens = $TokensIn + $TokensOut

# Timing (prefer transcript timestamps — the honest wall-clock of the run)
$StartTime = Coalesce @($FirstTs, $Event.start_time, $Event.timestamp, (Get-Date -Format 'o'))
$EndTime = Coalesce @($LastTs, (Get-Date -Format 'o'))
$LatencyMs = 0
try {
    $Start = [datetime]::Parse($StartTime)
    $End = [datetime]::Parse($EndTime)
    $span = [long]($End - $Start).TotalMilliseconds
    # A resumed session's transcript spans days; that wall-clock isn't a
    # meaningful "latency". Cap at 6h; anything larger is a resume, report 0.
    $LatencyMs = if ($span -ge 0 -and $span -le 21600000) { $span } else { 0 }
} catch {
    $LatencyMs = 0
}

# Cost estimation (rough: ~$3/M input, ~$15/M output for mid-tier models)
$InputCostPerM = 3.0
$OutputCostPerM = 15.0
$EstimatedCost = ($TokensIn / 1000000.0 * $InputCostPerM) + ($TokensOut / 1000000.0 * $OutputCostPerM)

# --- Attribution stamps: WHICH Claude account, WHICH human. Two independent axes --
# one human can hold two accounts; two humans can in principle share a machine -- so
# neither is inferred from the other. Read fresh every run: each SubagentStop firing
# is already a brand-new process, so "fresh" is automatic, not something to engineer.
# Absent/unreadable -> empty string, NEVER throw: this hook fires on every SubagentStop
# and must not break a developer's session over a missing/stale pointer file (C10).
$ActiveAccount = ""
$AccountPointerFile = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".harness\active-account.local.json"
if (Test-Path $AccountPointerFile) {
    try {
        $Pointer = Get-Content -Path $AccountPointerFile -Raw -Encoding utf8 | ConvertFrom-Json
        if ($Pointer.active_account) { $ActiveAccount = "$($Pointer.active_account)" }
    } catch {
        # Corrupted/unreadable pointer -- fail OPEN to empty string.
    }
}
$ActiveMember = if ($env:HARNESS_USER) { "$env:HARNESS_USER" } else { "" }

# Build record
$Record = @{
    timestamp = (Get-Date -Format 'o')
    agent_name = $AgentName
    model = $ModelName
    session_id = $SessionId
    status = $Status
    tokens_in = $TokensIn
    tokens_out = $TokensOut
    total_tokens = $TotalTokens
    estimated_cost_usd = [math]::Round($EstimatedCost, 6)
    latency_ms = $LatencyMs
    tool_calls = $ToolCalls
    start_time = $StartTime
    end_time = $EndTime
    active_account = $ActiveAccount
    active_member = $ActiveMember
    # WHICH assistant produced this line (B9a). A literal, not config: this
    # script IS the Claude Code sampler -- it runs from a Claude Code hook and
    # reads a Claude Code transcript, so the value is a fact about the writer,
    # not a rule to be looked up (C2 governs policy, not self-identification).
    # A collector for another assistant stamps its own value; the ingest
    # defaults a MISSING stamp to claude-code, so an un-upgraded machine still
    # lands in the right bucket.
    assistant = "claude-code"
}

# Append to agentops log
$LogFile = "$TelemetryDir\agentops.log"
Add-JsonLine $LogFile ($Record | ConvertTo-Json -Compress)

# Also update daily aggregate
$DateKey = (Get-Date -Format 'yyyy-MM-dd')
$AggFile = "$TelemetryDir\daily-$DateKey.jsonl"
Add-JsonLine $AggFile ($Record | ConvertTo-Json -Compress)

# Check for anomaly thresholds (simple spike detection)
$RecentRecords = Get-Content -Path $LogFile -Tail 10 -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json }
$AvgTokens = if ($RecentRecords.Count -gt 1) {
    ($RecentRecords | Measure-Object -Property total_tokens -Average).Average
} else { 0 }

if ($AvgTokens -gt 0 -and $TotalTokens -gt ($AvgTokens * 3)) {
    Write-Warning "[agentops-sampler] SPIKE DETECTED: $AgentName used ${TotalTokens}tokens (3x avg ${AvgTokens}tokens)"
}

exit 0
