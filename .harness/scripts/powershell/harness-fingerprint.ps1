#!/usr/bin/env pwsh
<#
.SYNOPSIS
  harness fingerprint -- which bundle version does this checkout REALLY match?
.DESCRIPTION
  Thin wrapper over .harness/scripts/lib/harness_fingerprint.py so PowerShell and
  bash emit identical output (C7). Read-only. Hashes the project's bundle files
  normalised (BOM stripped, CRLF -> LF), compares them with the version index and
  prints the best-matching version range. The install receipt is only a claim.
  Exit: 0 identified, 1 receipt disagrees, 2 could not identify (unproven).
.USAGE
  powershell -File .harness/scripts/powershell/harness-fingerprint.ps1 [-Root <dir>] [-Json] [-Index <file>]
#>
param(
    [string]$Root = "",
    [switch]$Json,
    [string]$Index = ""
)

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }

# PS 5.1-compatible: no null-coalescing operator here.
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error "python required for harness fingerprint"; exit 3 }

$Lib = Join-Path $PSScriptRoot "..\lib\harness_fingerprint.py"
$pyArgs = @($Lib, $Root)
if ($Json) { $pyArgs += "--json" }
if ($Index) { $pyArgs += @("--index", $Index) }
& $py.Source @pyArgs
exit $LASTEXITCODE
