#!/usr/bin/env pwsh
<#
.SYNOPSIS
  harness doctor — local self-check for a project's evidence pipeline.
.DESCRIPTION
  Thin wrapper over .harness/scripts/lib/harness_doctor.py so PowerShell and bash
  emit identical output (C7). Read-only diagnostic; prints OK/WARN/FAIL per check.
.USAGE
  pwsh -File .harness/scripts/powershell/harness-doctor.ps1 [-Root <dir>] [-Strict] [-Ci]
  -Ci: on a CI runner, report machine-local checks (ledger, telemetry, context)
       as not checkable instead of FAIL; bundle integrity stays graded (B-78).
#>
param(
    [string]$Root = "",
    [switch]$Strict,
    [switch]$Ci
)

# Resolve the project root the same worktree-aware way the hooks do, so doctor
# reports on the .harness the hooks actually write to, not an empty worktree copy.
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }
if (-not (Test-Path "$Root\.harness")) {
    try {
        $commonDir = (& git -C $Root rev-parse --git-common-dir 2>$null)
        if ($commonDir) {
            if (-not [System.IO.Path]::IsPathRooted($commonDir)) { $commonDir = Join-Path $Root $commonDir }
            $mainRepo = Split-Path -Parent $commonDir
            if ($mainRepo -and (Test-Path "$mainRepo\.harness")) { $Root = $mainRepo }
        }
    } catch { }
}

# PS 5.1-compatible: no null-coalescing operator here.
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error "python required for harness doctor"; exit 3 }

$Lib = Join-Path $PSScriptRoot "..\lib\harness_doctor.py"
$args = @($Lib, $Root)
if ($Strict) { $args += "--strict" }
if ($Ci) { $args += "--ci" }
& $py.Source @args
exit $LASTEXITCODE
