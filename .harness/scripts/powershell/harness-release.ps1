#!/usr/bin/env pwsh
<#
.SYNOPSIS
  H3 Evaluation — auto-run regression suites BEFORE a release, then gate it.
.DESCRIPTION
  1. Runs each suite in casan-policies evaluation.suite_commands (only the ones
     listed in regression_suites_required).
  2. Writes a fresh test report line per suite to
     .harness/telemetry/test-reports.jsonl (passed/failed + timestamp).
  3. Pushes telemetry so the Portal ingests the reports.
  4. Asks the Portal PDP whether a release (deploy) is allowed — the server-side
     release gate DENIES if any required suite is red or the judge REJECTED.
  5. Only if the gate returns "allow" does it run -DeployCommand (if given).

  So a release cannot proceed on stale/red tests. Honest (C10): enforcement is
  the same opt-in PDP; without portal_url/key configured this just runs+reports.

.EXAMPLE
  harness-release.ps1                               # run suites, push, check gate
  harness-release.ps1 -DeployCommand "npm run deploy"   # + deploy only if gate passes
#>
param(
    [string]$HarnessRoot = "",
    [string]$DeployCommand = ""
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

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if (-not $HarnessRoot) {
    $HarnessRoot = $env:HARNESS_ROOT
    if (-not $HarnessRoot) { $HarnessRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path }
}
$Policy = "$HarnessRoot\.harness\control\casan-policies.yaml"
$Tel = "$HarnessRoot\.harness\telemetry"
$ReportFile = "$Tel\test-reports.jsonl"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path $Tel)) { New-Item -ItemType Directory -Path $Tel -Force | Out-Null }

# --- read required suites + their commands from policy (python for robust YAML) ---
$py = (Get-Command python3 -ErrorAction SilentlyContinue); if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
$suitesJson = "{}"
if ($py -and (Test-Path $Policy)) {
    $suitesJson = @"
import json,yaml
e=(yaml.safe_load(open(r'$Policy',encoding='utf-8-sig')) or {}).get('evaluation') or {}
req=e.get('regression_suites_required') or []
cmds=e.get('suite_commands') or {}
print(json.dumps({s:cmds.get(s,'') for s in req}))
"@ | & $py.Source -
}
$suites = $suitesJson | ConvertFrom-Json
$names = @($suites.PSObject.Properties.Name)
if ($names.Count -eq 0) { Write-Warning "[release] No regression_suites_required in casan-policies -- nothing to run."; }

$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$allGreen = $true
foreach ($s in $names) {
    $cmd = $suites.$s
    if (-not $cmd) { Write-Warning "[release] suite '$s' has no command in evaluation.suite_commands -- SKIP (gate will mark missing)"; continue }
    Write-Host "[release] running suite '$s': $cmd" -ForegroundColor Cyan
    $out = ""
    try { $out = (& cmd /c $cmd 2>&1 | Out-String) } catch { $out = "$_" }
    $code = $LASTEXITCODE
    # Same parser as harness-eval.ps1: the labelled form FIRST, and the pytest
    # fallback anchored to a single line. `\s` matches a newline, so the loose
    # '(\d+)\s+failed' read the harness suites' own output
    #     Passed : 25
    #     Failed : 0
    # as "25 failed" -- the PASSED count became the FAILED count and the gate
    # could never open. Reported from a consuming project, where 25/0 green was
    # recorded as 1 passed / 25 failed.
    $passed = $null; $failed = $null
    if ($out -match '(?im)^\s*Passed\s*:\s*(\d+)') { $passed = [int]$matches[1] }
    elseif ($out -match '(?m)(\d+)[ \t]+passed') { $passed = [int]$matches[1] }
    if ($out -match '(?im)^\s*Failed\s*:\s*(\d+)') { $failed = [int]$matches[1] }
    elseif ($out -match '(?m)(\d+)[ \t]+failed') { $failed = [int]$matches[1] }
    # Nothing parseable is NOT a pass. The old default of passed=1/failed=0 meant
    # an unreadable suite recorded a green built from numbers no suite reported.
    if ($null -eq $passed -and $null -eq $failed) {
        $passed = 0; $failed = 1
        Write-Warning "[release] suite '$s': output not parseable -- counted as FAILED"
    }
    if ($null -eq $passed) { $passed = 0 }
    if ($null -eq $failed) { $failed = 0 }
    if ($code -ne 0 -and $failed -eq 0) { $failed = 1; $passed = 0 }
    if ($failed -gt 0) { $allGreen = $false }
    $line = @{ suite_name = $s; passed = $passed; failed = $failed; skipped = 0; coverage_percent = 0; ts = $now; triggered_by = "harness-release" } | ConvertTo-Json -Compress
    Add-JsonLine $ReportFile $line
    Write-Host ("[release] suite '{0}': passed={1} failed={2} (exit {3})" -f $s, $passed, $failed, $code) -ForegroundColor $(if ($failed) { "Red" } else { "Green" })
}

# --- push reports so the Portal ingests them ---
$push = "$PSScriptRoot\push-telemetry.ps1"
if (Test-Path $push) { & $push -HarnessRoot $HarnessRoot | Out-Null; Write-Host "[release] pushed test reports to Portal" -ForegroundColor Gray }

# --- ask the PDP release gate ---
$decision = "allow"; $reason = "(gate not consulted)"
$cfgFile = "$HarnessRoot\.harness\portal-sync.json"
if ((Test-Path $cfgFile)) {
    $cfg = Get-Content $cfgFile -Raw -Encoding utf8 | ConvertFrom-Json
    # Portal v2 P1 1.2b: the CHECKOUT credential (X-Checkout-Id + X-Checkout-Credential)
    # when this machine holds one -- read by the shared reader, headers only (C5) -- else the
    # legacy shared key (X-Ingest-Key), with a once-a-day notice. Never both.
    $AuthHeaders = $null; $AuthSource = ""
    $AuthLib = Join-Path $PSScriptRoot "..\lib\harness_checkout_facts.py"
    $pyc = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pyc) { $pyc = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($pyc -and (Test-Path $AuthLib)) {
        try {
            $aj = (& $pyc.Source $AuthLib --auth $HarnessRoot 2>$null) -join ""
            if ($aj) {
                $Au = $aj | ConvertFrom-Json
                if ($Au.checkout_id -and $Au.checkout_credential) {
                    $AuthHeaders = @{ "X-Checkout-Id" = "$($Au.checkout_id)"; "X-Checkout-Credential" = "$($Au.checkout_credential)" }
                    $AuthSource = "checkout"
                }
            }
        } catch { }
    }
    if (-not $AuthHeaders) {
        $key = $env:HARNESS_PORTAL_INGEST_KEY
        if (-not $key -and (Test-Path "$HarnessRoot\.harness\portal-sync.key")) { $key = (Get-Content "$HarnessRoot\.harness\portal-sync.key" -Raw).Trim() }
        if ($key) {
            $AuthHeaders = @{ "X-Ingest-Key" = $key }; $AuthSource = "legacy-key"
            if ($pyc -and (Test-Path $AuthLib)) {
                try { $lw = (& $pyc.Source $AuthLib --legacy-warning harness-release 2>$null) -join ""; if ($lw) { Write-Warning $lw } } catch { }
            }
        }
    }
    if ($cfg.portal_url -and $cfg.project_id -and $AuthHeaders) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            # The REAL requester: HARNESS_USER, else git user.email. With neither, actor stays
            # empty and the server uses the member bound to the credential. The script's own name
            # is never an actor -- it travels as requested_via.
            $actor = "$env:HARNESS_USER"
            if (-not $actor) { try { $actor = ((& git -C $HarnessRoot config user.email 2>$null) -join "").Trim() } catch { $actor = "" } }
            $b = @{ tool = "deploy"; command = "release"; actor = "$actor"; requested_via = "harness-release" } | ConvertTo-Json -Compress
            $r = Invoke-RestMethod -Uri "$($cfg.portal_url.TrimEnd('/'))/api/pdp/$($cfg.project_id)/decide" -Method Post `
                -ContentType "application/json; charset=utf-8" -Headers $AuthHeaders `
                -UserAgent "harness-release/1.0" -Body ([System.Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec 15
            $decision = $r.decision; $reason = $r.reason
        } catch {
            # Tell "the PDP answered no" from "the PDP could not be reached". An explicit 403 is a
            # server refusal and must never fall back to allow; 401 and network errors keep the
            # local-suite fallback (documented design, C10) but are named for what they are.
            $RejCode = 0
            try { $RejCode = [int]$_.Exception.Response.StatusCode } catch { $RejCode = 0 }
            if ($RejCode -eq 403) {
                Write-Warning "[release] PDP rejected this credential (HTTP 403: revoked / disabled / not permitted) -- release refused"
                $decision = "deny"; $reason = "PDP rejected this credential (HTTP 403)"
            } elseif ($RejCode -eq 401) {
                Write-Warning "[release] PDP rejected this credential (HTTP 401: revoked / expired) -- server-side enforcement is NOT active; using local suite result"
                $decision = if ($allGreen) { "allow" } else { "deny" }; $reason = "local suites $(if($allGreen){'green'}else{'red'})"
            } else {
                Write-Warning "[release] PDP not reachable ($($_.Exception.Message)) -- using local suite result"
                $decision = if ($allGreen) { "allow" } else { "deny" }; $reason = "local suites $(if($allGreen){'green'}else{'red'})"
            }
        }
    }
}

Write-Host "==================================================================" -ForegroundColor Green
Write-Host " Release gate: $decision -- $reason" -ForegroundColor $(if ($decision -eq "allow") { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Green
if ($decision -ne "allow") { Write-Host "[release] BLOCKED. Fix tests / get approval, then re-run." -ForegroundColor Red; exit 1 }

if ($DeployCommand) {
    Write-Host "[release] gate passed -- deploying: $DeployCommand" -ForegroundColor Cyan
    & cmd /c $DeployCommand
    exit $LASTEXITCODE
}
Write-Host "[release] gate passed -- safe to release." -ForegroundColor Green
exit 0
