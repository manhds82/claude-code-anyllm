#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Collect Codex token usage into this project's telemetry (B9b).
.DESCRIPTION
  Codex has NO hook mechanism, so nothing stamps usage as it happens the way
  the Claude SubagentStop hook does. Instead Codex writes a transcript per
  session under ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, and this script
  reads those directly. That makes the Codex path MORE robust than the Claude
  one, which collects nothing at all when its hook is not wired.

  Only sessions whose `cwd` is THIS project are collected; records are appended
  to .harness/telemetry/agentops.log in the existing format with
  assistant="codex", so the Portal ingest needs no Codex-specific branch.

  The arithmetic lives in ..\lib\codex_collect.py, shared with the bash twin --
  this script decides WHERE things are, never WHAT the numbers are. Two hand
  written copies of a token calculation drift, and the drift surfaces as a cost
  figure that differs by machine.
.USAGE
  powershell -File <project>\.harness\scripts\powershell\collect-codex.ps1
  # or with an explicit project root:
  powershell -File ...\collect-codex.ps1 -HarnessRoot E:\SourceCode\MyProject
.NOTES
  C10: this is measurement, not enforcement. Nothing here constrains Codex.
  Windows PowerShell 5.1 compatible.
#>
param(
    [string]$HarnessRoot = "",
    [string]$CodexSessionsDir = "",
    [string]$PricingPath = ""
)

# NOT "Stop": this runs from session end, best-effort. A collector must never be
# the reason someone's session errors out.
$ErrorActionPreference = "Continue"

if (-not $HarnessRoot) {
    $HarnessRoot = $env:HARNESS_ROOT
    if (-not $HarnessRoot) { $HarnessRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path }
}
if (-not $CodexSessionsDir) {
    $CodexSessionsDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".codex\sessions"
}
if (-not $PricingPath) {
    $PricingPath = Join-Path $HarnessRoot ".harness\control\token-pricing.json"
}

$Lib = Join-Path $PSScriptRoot "..\lib\codex_collect.py"
if (-not (Test-Path $Lib)) {
    Write-Warning "[collect-codex] missing shared collector: $Lib"
    exit 0
}

if (-not (Test-Path $CodexSessionsDir)) {
    # Not a warning. A machine that does not run Codex is the normal case, and a
    # warning channel that fires on the normal case stops being read (C14).
    Write-Output "[collect-codex] no Codex sessions dir ($CodexSessionsDir) -- nothing to collect."
    exit 0
}

# Resolve python the same way the rest of the harness does. `py -3` first on
# Windows: a machine with the Store alias stub for `python` answers Test-Path
# but fails on execution.
$Py = $null
foreach ($cand in @("py", "python3", "python")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $Py = $cand; break }
}
if (-not $Py) {
    Write-Warning "[collect-codex] python not found -- Codex usage NOT collected."
    exit 0
}
$PyArgs = @()
if ($Py -eq "py") { $PyArgs += "-3" }

$Member = ""
if ($env:HARNESS_USER) { $Member = "$env:HARNESS_USER" }
if (-not $Member) {
    # Same source the Claude path uses for attribution, so a Codex row lands on
    # the same member as a Claude row from the same machine.
    #
    # Portal v2 P1 1.7: member_email lives in .harness/local/checkout.json now; the shared
    # reader falls back to the old portal-sync.json and reports where the value came from.
    $StateLib = Join-Path $HarnessRoot ".harness\scripts\lib\harness_local_state.py"
    if (Test-Path $StateLib) {
        try {
            $me = ((& $Py @PyArgs $StateLib member-email $HarnessRoot 2>$null) -join "") | ConvertFrom-Json
            if ($me.value) { $Member = "$($me.value)" }
            if ($me.warning -and $me.value) { Write-Warning "[collect-codex] $($me.warning)" }
        } catch { }
    }
}

& $Py @PyArgs $Lib $HarnessRoot $CodexSessionsDir $PricingPath $Member
exit 0
