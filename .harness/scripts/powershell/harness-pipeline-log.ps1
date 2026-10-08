#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Record one Agent Pack pipeline run (P-7). Thin wrapper over
  .harness/scripts/lib/harness_pipeline_log.py so PowerShell and bash behave
  identically (C7).

.DESCRIPTION
  The record is a SELF-REPORT by the agent that ran the loop, not proof it ran.
  The library rejects internally inconsistent counts -- more fixed than
  confirmed, more confirmed than found -- rather than writing a row a dashboard
  would then present as measurement.

.USAGE
  powershell -File .harness\scripts\powershell\harness-pipeline-log.ps1 `
      -Skill impact-review -Verdict APPROVED -Found 7 -Confirmed 3 -Dropped 4 -Fixed 3

.NOTES
  Windows PowerShell 5.1 compatible.
#>
param(
    [string]$Root = "",
    [Parameter(Mandatory)][string]$Skill,
    [Parameter(Mandatory)][ValidateSet("APPROVED","CHANGES_REQUIRED","REJECTED","ESCALATED","ABORTED")]
    [string]$Verdict,
    [string]$PipelineId = "",
    [int]$Found = 0,
    [int]$Confirmed = 0,
    [int]$Dropped = 0,
    [int]$Fixed = 0,
    [int]$Retries = 0,
    [int]$Files = 0,
    [switch]$ForceFull,
    [int]$TestsPassed = 0,
    [int]$TestsFailed = 0,
    [int]$DurationS = 0,
    [string]$Base = "",
    [string]$Head = ""
)

$ErrorActionPreference = "Stop"

if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path }

# Worktree-aware, same as the hooks: write to the .harness the hooks write to,
# or a run made in a worktree lands in a telemetry directory nothing ships.
if (-not (Test-Path (Join-Path $Root ".harness"))) {
    try {
        $common = (& git -C $Root rev-parse --git-common-dir 2>$null)
        if ($common) {
            if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $Root $common }
            $main = (Resolve-Path (Join-Path $common "..") -ErrorAction SilentlyContinue)
            if ($main -and (Test-Path (Join-Path $main.Path ".harness"))) { $Root = $main.Path }
        }
    } catch { }
}

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error "python required for harness pipeline-log"; exit 3 }

$lib = Join-Path $Root ".harness\scripts\lib\harness_pipeline_log.py"
if (-not (Test-Path $lib)) { Write-Error "not found: $lib"; exit 3 }

# Built as a flat array of already-separated tokens. An array splat would bind
# POSITIONALLY here (the defect v1.5.2 fixed in update-all-projects, where every
# project got stamped with the literal string "-ProjectName"); passing the list
# straight to a native exe is argument-by-argument and safe.
$a = @(
    $lib, $Root,
    "--skill", $Skill, "--verdict", $Verdict,
    "--found", $Found, "--confirmed", $Confirmed, "--dropped", $Dropped,
    "--fixed", $Fixed, "--retries", $Retries, "--files", $Files,
    "--force-full", $(if ($ForceFull) { "true" } else { "false" }),
    "--tests-passed", $TestsPassed, "--tests-failed", $TestsFailed,
    "--duration-s", $DurationS
)
# Only when set: PS 5.1 drops an EMPTY string argument on the way to a native
# exe, so `--head ""` arrived as a bare `--head` and argparse rejected the whole
# record ("expected one argument") -- a run with no head commit was not loggable.
if ($PipelineId) { $a += @("--pipeline-id", $PipelineId) }
if ($Base) { $a += @("--base", $Base) }
if ($Head) { $a += @("--head", $Head) }
& $py.Source @a
exit $LASTEXITCODE
