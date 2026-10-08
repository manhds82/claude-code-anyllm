#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Stop hook (C15) -- remind once to update Handoff.md when this session changed files.
.DESCRIPTION
  Thin wrapper over .harness/scripts/lib/harness_handoff.py so PowerShell and bash
  decide identically (C7). Reads the Stop-hook JSON on stdin; prints
  {"decision":"block","reason":...} or nothing. Always exits 0 (fail-open, C14):
  a reminder that errors must never trap a session.
  Defense-in-depth, bypassable locally (C10).
#>
try {
    $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) { exit 0 }
    $Lib = Join-Path $PSScriptRoot "..\lib\harness_handoff.py"
    if (-not (Test-Path $Lib)) { exit 0 }

    # Read stdin as raw UTF-8 bytes (the console codepage would mangle non-ASCII paths).
    $ms = New-Object System.IO.MemoryStream
    $in = [Console]::OpenStandardInput()
    $in.CopyTo($ms)
    $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())

    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $raw | & $py.Source $Lib $Root
} catch { }
exit 0
