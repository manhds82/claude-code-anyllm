#!/usr/bin/env pwsh

# Append one JSONL line WITHOUT a BOM. `Add-Content -Encoding utf8` on Windows
# PowerShell 5.1 always writes EF BB BF when it creates the file, so the FIRST
# line of a .jsonl becomes unparseable to any reader doing json.loads per line
# (od -c shows 357 273 277 before the opening brace). Reported from a consuming
# project whose test-reports.jsonl could not be read back.
function Add-JsonLine([string]$Path, [string]$Line) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, $enc)
}

# One line per swallowed failure, into hook-errors.log (W1-4). A hook must never
# fail the tool call, but "never fail" had rotted into "never tell anyone":
# this repo's ledger was dead for 14 days with zero trace because every error
# path here ended in $null. Best-effort with a record beats best-effort blind.
function Write-HookError([string]$Msg) {
    try {
        $line = @{ timestamp = (Get-Date -Format 'o'); hook = "post-tool-use"; error = $Msg } | ConvertTo-Json -Compress
        Add-JsonLine "$_HarnessRoot\.harness\telemetry\hook-errors.log" $line
    } catch { }  # the error log failing must not take the hook down with it
}

<#
.SYNOPSIS
  PostToolUse hook — records tool call outcomes and updates pipeline context.
.DESCRIPTION
  - Logs completed tool calls to telemetry
  - For side-effect tools, updates the pipeline context file
  - Future: stale context detection via artifact hash comparison
.NOTES
  Part of Harness Runtime Plane (PEP). Reads decision from stdin JSON.
#>

$InputJson = $input | Out-String
if (-not $InputJson) {
    exit 0
}

try {
    $CallRecord = $InputJson | ConvertFrom-Json
} catch {
    # Non-JSON input or empty — silently pass
    exit 0
}

# Extract tool info. Claude Code's PostToolUse payload uses tool_name /
# tool_input / tool_response; accept the older tool/input/result shape too.
$ToolName = if ($CallRecord.tool_name) { $CallRecord.tool_name } else { $CallRecord.tool }
$ToolInput = if ($CallRecord.tool_input) { $CallRecord.tool_input } else { $CallRecord.input }
$ToolResult = if ($CallRecord.tool_response) { $CallRecord.tool_response } else { $CallRecord.result }
$ToolSuccess = $CallRecord.success
$AgentName = if ($CallRecord.agent) { $CallRecord.agent } else { "claude-code" }
$Timestamp = (Get-Date -Format 'o')

# Log to telemetry — resolve path independently (env var not persisted across hook processes)
$_HarnessRoot = $env:HARNESS_ROOT
if (-not $_HarnessRoot) { $_HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.." }
$TelemetryDir = "$_HarnessRoot\.harness\telemetry"
if (-not (Test-Path $TelemetryDir)) { New-Item -ItemType Directory -Path $TelemetryDir -Force | Out-Null }
$LogFile = "$TelemetryDir\tool-calls.log"

$LogEntry = @{
    timestamp  = $Timestamp
    agent      = $AgentName
    tool       = $ToolName
    success    = $ToolSuccess
    session_id = $env:HARNESS_SESSION_ID
} | ConvertTo-Json -Compress

Add-JsonLine $LogFile $LogEntry

# C9: every side-effect tool call appends one line to the evidence ledger
# (identity + input/output hash). Best-effort — never fail the hook on it.
#
# "Best-effort" used to mean `*>$null` around the call and an empty catch, which
# is not best-effort, it is blind. This repo's own ledger stopped growing on
# 2026-07-23 and nobody found out for 14 days: the append was being killed by the
# hook timeout every single time, and every trace of that was thrown away here.
# Failures now land in hook-errors.log. The hook still never fails the tool call --
# that part was right -- but a silent subsystem is one nobody can operate.
try {
    $LedgerScript = Join-Path $PSScriptRoot "evidence-ledger.ps1"
    if (Test-Path $LedgerScript) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $tin  = if ($ToolInput)  { $ToolInput  | ConvertTo-Json -Compress -Depth 6 } else { "{}" }
        $tout = if ($ToolResult) { $ToolResult | ConvertTo-Json -Compress -Depth 6 } else { "{}" }
        $inputHash  = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($tin)))  -replace '-', '').ToLower()
        $outputHash = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($tout))) -replace '-', '').ToLower()
        $entry = @{
            actor = @{ agent = "$AgentName"; user = "$env:HARNESS_USER"; session_id = "$env:HARNESS_SESSION_ID"; role = "member" }
            action = @{ type = "tool_call"; tool = "$ToolName"; description = "completed tool call"; input_hash = $inputHash; output_hash = $outputHash }
            decision = @{ result = "allow"; reason = "completed"; risk_level = "none" }
        } | ConvertTo-Json -Compress -Depth 4
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # Reset before the call. `& script.ps1` does NOT set $LASTEXITCODE unless
        # the script calls `exit` explicitly, so on a successful append the
        # variable kept whatever a previous native command left -- or $null on
        # first use. `$null -ne 0` is TRUE, so every SUCCESSFUL append was logged
        # as a failure: 266 lines of "ledger append exited  for tool=..." whose
        # own payload reads "Appended entry 201". A log that cries wolf on every
        # success trains the reader to ignore it, which costs more than having no
        # log at all -- the exact failure this log exists to prevent.
        $global:LASTEXITCODE = 0
        $ledgerOut = & $LedgerScript append -EntryJson $entry 2>&1
        $ok = $?
        $sw.Stop()
        if (-not $ok -or $LASTEXITCODE -ne 0) {
            Write-HookError "ledger append exited $LASTEXITCODE for tool=$ToolName :: $($ledgerOut -join ' | ')"
        } elseif ($sw.ElapsedMilliseconds -gt 2000) {
            # An append is a tail-read plus one AppendAllText; seconds means the
            # chain holds something pathological. Warn while the hook still
            # completes, so the next person sees it coming instead of finding a
            # frozen ledger weeks later.
            Write-HookError "ledger append took $($sw.ElapsedMilliseconds)ms (expected <100ms) -- chain may hold an oversized entry"
        }
    }
} catch {
    # Never fail the tool call on evidence capture -- but record why it failed.
    Write-HookError "ledger append threw for tool=$ToolName :: $($_.Exception.Message)"
}

# --- H3/H5: qa-gate verdict gates the release-affecting tools (C2/C10) --------
# Runs LAST, after telemetry and the ledger entry are written: a denied call is
# still a call that happened, and dropping it from the evidence trail to keep the
# deny path tidy would hide exactly the events an auditor came for.
#
# Both the enable flag and the tool list come from casan-policies.yaml, never
# from this script. Default off, because a project on the legacy 3-stage DAG has
# no qa-gate stage and so no verdict -- blocking every commit there would be a
# breaking change shipped as a bugfix. Once ENABLED, a missing or unreadable
# verdict fails CLOSED and says so.
try {
    $PolicyFile = Join-Path $_HarnessRoot ".harness\control\casan-policies.yaml"
    $ContextFile = Join-Path $_HarnessRoot ".harness\context\pipeline-context.yaml"
    $gateEnabled = $false; $blocking = @()
    if (Test-Path $PolicyFile) {
        # Deliberately a narrow line scan rather than a YAML parser: this hook
        # runs on EVERY tool call and must not depend on a module being present
        # (PS 5.1 ships no YAML support) nor pay a parse cost per call.
        $inQaGate = $false
        foreach ($line in (Get-Content -Path $PolicyFile -Encoding utf8)) {
            if ($line -match '^\s{2}qa_gate:\s*$') { $inQaGate = $true; continue }
            if ($inQaGate) {
                if ($line.Trim() -ne '' -and $line -notmatch '^\s{4}') { $inQaGate = $false; continue }
                if ($line -match '^\s{4}enabled:\s*(\S+)') { $gateEnabled = ($matches[1] -match '^(true|yes|1)$') }
                if ($line -match '^\s{6}-\s*"?([A-Za-z0-9_.\-]+)"?') { $blocking += $matches[1] }
            }
        }
    }

    if ($gateEnabled -and $ToolName -and ($blocking -contains $ToolName)) {
        $verdict = ""; $vpath = "artifacts/qa-gate/<pipeline_id>-verdict.md"
        if (Test-Path $ContextFile) {
            foreach ($line in (Get-Content -Path $ContextFile -Encoding utf8)) {
                if (-not $verdict -and $line -match '^\s*qa_gate_verdict:\s*"?([A-Za-z_]+)"?') { $verdict = $matches[1] }
                if ($line -match '^\s*qa_gate_verdict_path:\s*"?([^"\r\n]+)"?') { $vpath = $matches[1].Trim() }
            }
        }
        if ($verdict -ne "APPROVED") {
            if (-not $verdict) {
                Write-Error "qa-gate block: verdict missing -- fail-closed. The gate is enabled in casan-policies.yaml but pipeline-context.yaml carries no qa_gate_verdict. Run the qa-gate stage, or set governance.qa_gate.enabled: false."
            } else {
                Write-Error "qa-gate block: verdict=$verdict (needs APPROVED) for tool '$ToolName'. Resolve at $vpath."
            }
            Write-Error "This is a LOCAL hook -- defense-in-depth, not a boundary. Release actions need server-side enforcement at the gateway (C10)."
            exit 2
        }
    }
} catch {
    # A crash in the gate must not become a silent ALLOW: failing open here would
    # make an unreadable policy file the easiest way to bypass the gate. But only
    # deny if the gate was actually meant to be on -- a project that never
    # enabled it must not start failing because this block threw.
    if ($gateEnabled) {
        Write-Error "qa-gate block: gate check failed to run ($($_.Exception.Message)) -- fail-closed."
        exit 2
    }
}

exit 0
