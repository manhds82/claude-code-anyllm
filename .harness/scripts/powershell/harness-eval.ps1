#!/usr/bin/env pwsh
<#
.SYNOPSIS
  H3 evaluation runner: run a project's REAL test suites and append honest
  results to .harness/telemetry/test-reports.jsonl (which push-telemetry sends
  to the Portal → test_reports → H3 "test report"/"tests passing" signals).

.DESCRIPTION
  Sources of suites, in order:
    1. casan-policies.yaml evaluation.suite_commands (declared per project) —
       run each non-empty "<name>: <command>".
    2. If none declared, auto-detect: pytest (when it collects >0), npm test.
  Output is PARSED for real pass/fail/skip counts (PowerShell "Passed : N",
  pytest "N passed, N failed, N skipped", jest "Tests: ..."). A suite that
  produces no parseable counts is reported as skipped and writes NO report —
  we never fabricate a green run (C10).

.EXAMPLE
  powershell -File .harness\scripts\powershell\harness-eval.ps1
  powershell -File ...\harness-eval.ps1 -HarnessRoot E:\SourceCode\MyProject
#>
param(
    [string]$HarnessRoot = "",
    [switch]$Quiet
)

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

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if (-not $HarnessRoot) { $HarnessRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path }
$Tel = Join-Path $HarnessRoot ".harness\telemetry"
$Policy = Join-Path $HarnessRoot ".harness\control\casan-policies.yaml"
if (-not (Test-Path $Tel)) { New-Item -ItemType Directory -Path $Tel -Force | Out-Null }
$ReportFile = Join-Path $Tel "test-reports.jsonl"
$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Parse-Counts([string]$text) {
    # Try PowerShell Pester-style / harness format first, then pytest, then jest.
    $p = $f = $s = $null
    if ($text -match '(?im)^\s*Passed\s*:\s*(\d+)') { $p = [int]$matches[1] }
    if ($text -match '(?im)^\s*Failed\s*:\s*(\d+)') { $f = [int]$matches[1] }
    if ($text -match '(?im)^\s*Skipped\s*:\s*(\d+)') { $s = [int]$matches[1] }
    # Anchored to ONE line: `\s` matches a newline, so an unanchored
    # '(\d+)\s+failed' reads "Passed : 25`nFailed : 0" as "25 failed". Harmless
    # here because the labelled form above already matched, but the same regex
    # copied into harness-release.ps1 inverted its whole gate.
    if ($null -eq $p) { if ($text -match '(?m)(\d+)[ \t]+passed') { $p = [int]$matches[1] } }
    if ($null -eq $f) { if ($text -match '(?m)(\d+)[ \t]+failed') { $f = [int]$matches[1] } }
    if ($null -eq $s) { if ($text -match '(?m)(\d+)[ \t]+skipped') { $s = [int]$matches[1] } }
    if ($null -eq $p -and $null -eq $f) { return $null }   # nothing parseable
    [pscustomobject]@{ passed = [int]$p; failed = [int]$f; skipped = [int]$s }
}

function Get-Coverage([string]$text) {
    if ($text -match '(?im)TOTAL.*?(\d+)%') { return [int]$matches[1] }
    if ($text -match '(?im)All files.*?(\d+(?:\.\d+)?)') { return [int][math]::Round([double]$matches[1]) }
    return 0
}

# --- 1. Declared suite_commands (naive YAML line parse under suite_commands:) ---
$suites = @()
if (Test-Path $Policy) {
    $inBlock = $false
    $blockIndent = 0
    foreach ($line in Get-Content $Policy -Encoding utf8) {
        if ($line -match '^(\s*)suite_commands:\s*$') {
            $inBlock = $true; $blockIndent = $matches[1].Length; continue
        }
        if ($inBlock) {
            if ($line -match '^\s*$') { continue }                    # blank line inside the block
            $indent = ($line -replace '^(\s*).*$', '$1').Length
            # ANY line indented at or above the block key ends the block. Comparing
            # against the block's own indent (not just column 0) is what stops the
            # sibling keys under `evaluation:` from being picked up as suites and
            # executed as shell commands.
            if ($indent -le $blockIndent) { $inBlock = $false; continue }
            # Either quote style. A project whose Prettier runs with singleQuote
            # rewrote every command to 'python ...' (ScreenRecord, 2026-09-30); the
            # quotes then reached cmd.exe, which ran nothing, and all three suites
            # were skipped without a word about why.
            if ($line -match '^\s+([A-Za-z0-9_\-]+):\s*(?:"([^"]*)"|''([^'']*)''|([^#]*?))\s*(#.*)?$') {
                $name = $matches[1]
                $cmd = ("" + $matches[2] + $matches[3] + $matches[4]).Trim()
                if ($cmd) { $suites += [pscustomobject]@{ name = $name; cmd = $cmd } }
            }
        }
    }
}

# --- 2. Auto-detect if nothing declared ---
if (-not $suites) {
    $py = (Get-Command python3 -ErrorAction SilentlyContinue); if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) {
        Push-Location $HarnessRoot
        $co = & $py.Source -m pytest --co -q 2>&1 | Out-String
        Pop-Location
        if ($LASTEXITCODE -eq 0 -and $co -notmatch 'no tests collected') {
            $suites += [pscustomobject]@{ name = "pytest"; cmd = "$($py.Source) -m pytest -q -p no:cacheprovider" }
        }
    }
    $pkg = Join-Path $HarnessRoot "package.json"
    if ((Test-Path $pkg) -and ((Get-Content $pkg -Raw) -match '"test"\s*:')) {
        $suites += [pscustomobject]@{ name = "npm-test"; cmd = "npm test --silent" }
    }
}

if (-not $suites) {
    if (-not $Quiet) { Write-Host "[harness-eval] No declared or auto-detected test suite — nothing to report (honest)." -ForegroundColor Yellow }
    exit 0
}

# --- 3. Run + parse + append ---
$written = 0
foreach ($suite in $suites) {
    if (-not $Quiet) { Write-Host ("[harness-eval] running {0}: {1}" -f $suite.name, $suite.cmd) -ForegroundColor Cyan }
    Push-Location $HarnessRoot
    $out = (& cmd /c $suite.cmd 2>&1 | Out-String)
    Pop-Location
    $counts = Parse-Counts $out
    if ($null -eq $counts) {
        if (-not $Quiet) {
            Write-Host ("  ~ {0}: no parseable result -> skipped (no report written)" -f $suite.name) -ForegroundColor Yellow
            # Say what the suite actually printed. "no parseable result" alone hid
            # "'python' is not recognized" behind a line that reads like a quiet suite.
            $first = @($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2)
            if ($first.Count) { Write-Host ("    output began: {0}" -f ($first -join ' | ')) -ForegroundColor DarkYellow }
            else { Write-Host "    (the command printed nothing)" -ForegroundColor DarkYellow }
        }
        continue
    }
    $rec = [ordered]@{
        suite_name       = $suite.name
        passed           = $counts.passed
        failed           = $counts.failed
        skipped          = $counts.skipped
        coverage_percent = (Get-Coverage $out)
        ts               = $ts
        triggered_by     = "harness-eval"
    }
    Add-JsonLine $ReportFile ($rec | ConvertTo-Json -Compress)
    $written++
    if (-not $Quiet) { Write-Host ("  > {0}: passed={1} failed={2} skipped={3}" -f $suite.name, $counts.passed, $counts.failed, $counts.skipped) -ForegroundColor Green }
}
if (-not $Quiet) { Write-Host ("[harness-eval] wrote {0} report(s) -> {1}" -f $written, $ReportFile) -ForegroundColor Gray }
exit 0
