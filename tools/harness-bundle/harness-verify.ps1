#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Harness "doctor" -- verifies a project has the governance bundle applied
  correctly and completely. Reads the install receipt
  (.harness/.bundle-manifest.json) and checks every file is present and matches
  its recorded hash, that .claude/settings.json uses the current hook schema,
  and that the hook scripts it points at exist.

.EXIT CODE
  0 = healthy (all present + hooks wired). 1 = problems (missing files, no
  receipt, or hooks not wired). "modified" files are reported but not fatal
  (you may have intentionally edited project.yaml / CLAUDE.md / risk-policy).

.USAGE
  .\harness-verify.ps1 -TargetDir <project>        # default: current dir
#>
param([string]$TargetDir = ".")

$ErrorActionPreference = "Stop"
if (-not (Test-Path $TargetDir)) { throw "Target not found: $TargetDir" }
$TargetDir = (Resolve-Path $TargetDir).Path

function Sha256Hex([byte[]]$Bytes) {
    $s = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($s.ComputeHash($Bytes)) -replace '-', '').ToLower()
}

# BOM and CRLF stripped: a core.autocrlf checkout or a Windows editor changes these
# and nothing else, and that is not drift. install.* does exactly the same.
# Latin-1 maps bytes 1:1, so the round trip is byte-exact.
function Get-NormBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return ,([byte[]]@()) }
    $start = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $start = 3 }
    $lat = [System.Text.Encoding]::GetEncoding(28591)
    $text = $lat.GetString($Bytes, $start, $Bytes.Length - $start)
    return ,($lat.GetBytes($text.Replace("`r`n", "`n")))
}

Write-Output "== Harness verify: $TargetDir"

$receiptPath = Join-Path $TargetDir ".harness\.bundle-manifest.json"
if (-not (Test-Path $receiptPath)) {
    Write-Output "  [X] NOT INSTALLED -- no receipt (.harness/.bundle-manifest.json)."
    Write-Output "      Install first: install.ps1 -BundleFile <x.bundle.json> -TargetDir $TargetDir"
    exit 1
}
$r = Get-Content $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
Write-Output "  bundle: $($r.name) v$($r.version)  installed_at=$($r.installed_at)"

# --- File integrity vs receipt ---
$ok = 0; $missing = @(); $modified = @(); $unverifiable = @()
$conflictFiles = @(); $skippedFiles = @(); $keptFiles = @()
foreach ($f in $r.files) {
    # Receipts older than per-file states carry none: every file was claimed installed.
    $st = if ($f.PSObject.Properties.Name -contains 'state' -and $f.state) { "$($f.state)" } else { "installed" }
    if ($st -eq "conflict") { $conflictFiles += $f.path; continue }
    if ($st -eq "skipped")  { $skippedFiles += $f.path; continue }
    if ($st -eq "kept")     { $keptFiles += $f.path; continue }
    $dest = Join-Path $TargetDir ($f.path -replace '/', '\')
    if (-not (Test-Path $dest)) { $missing += $f.path; continue }
    $want = @()
    foreach ($h in @("$($f.sha256)", $(if ($f.PSObject.Properties.Name -contains 'installed_sha256') { "$($f.installed_sha256)" } else { "" }))) {
        if ($h -and $h -ne "unknown") { $want += $h }
    }
    if ($want.Count -eq 0) { $unverifiable += $f.path; continue }
    $bytes = [System.IO.File]::ReadAllBytes($dest)
    $cur = Sha256Hex $bytes
    $curNorm = Sha256Hex (Get-NormBytes $bytes)
    # LF with the BOM KEPT: the receipt hashes the shipped bytes (LF, BOM on most .ps1),
    # so a BOM'd .ps1 checked out as CRLF matches only this form (B-77).
    $lat = [System.Text.Encoding]::GetEncoding(28591)
    $curLf = Sha256Hex ($lat.GetBytes($lat.GetString($bytes).Replace("`r`n", "`n")))
    if (($want -contains $cur) -or ($want -contains $curNorm) -or ($want -contains $curLf)) { $ok++ } else { $modified += $f.path }
}
Write-Output "  files: $ok OK / $($modified.Count) modified / $($missing.Count) missing  (of $(@($r.files).Count))"
if ($r.PSObject.Properties.Name -contains 'status' -and $r.status -eq 'partial') {
    Write-Output "  receipt status: PARTIAL -- the last install did not apply every file"
}
if ($missing.Count) { $missing | ForEach-Object { Write-Output "     [MISSING] $_" } }
if ($modified.Count) { $modified | ForEach-Object { Write-Output "     [modified] $_" } }
$conflictFiles | ForEach-Object { Write-Output "     [conflict] $_" }
$skippedFiles | ForEach-Object { Write-Output "     [skipped] $_" }
$keptFiles | ForEach-Object { Write-Output "     [kept] $_" }
if ($unverifiable.Count) { Write-Output "  $($unverifiable.Count) file(s) carry no hash to compare (empty file or unknown): $($unverifiable -join ', ')" }

# --- Hook wiring (current Claude Code schema = array of command objects) ---
$hooksWired = $false; $hookMsg = ""
$settingsPath = Join-Path $TargetDir ".claude\settings.json"
if (-not (Test-Path $settingsPath)) {
    $hookMsg = "no .claude/settings.json"
} else {
    $s = Get-Content $settingsPath -Raw -Encoding utf8 | ConvertFrom-Json
    $pre = $s.hooks.PreToolUse
    if ($null -eq $pre) { $hookMsg = "no PreToolUse hook" }
    elseif ($pre -is [string]) { $hookMsg = "OLD bare-path format -> hooks will NOT fire (re-install settings.json)" }
    else {
        # Check the referenced script exists (resolve ${CLAUDE_PROJECT_DIR}).
        $cmd = $pre[0].hooks[0]
        $arg = @($cmd.args) | Where-Object { $_ -notlike '-*' } | Select-Object -Last 1
        $scriptRel = ($arg -replace '\$\{CLAUDE_PROJECT_DIR\}', '.') -replace '/', '\'
        $scriptPath = Join-Path $TargetDir ($scriptRel -replace '^\.\\', '')
        $hooksWired = $true
        $exists = Test-Path $scriptPath
        $hookMsg = "array schema OK; interpreter='$($cmd.command)'; guard script $(if($exists){'found'}else{'MISSING: ' + $scriptRel})"
        if (-not $exists) { $hooksWired = $false }
    }
}
Write-Output "  hooks: $(if($hooksWired){'[OK] '}else{'[!] '})$hookMsg"

# --- PM lock status ---
$policyPath = Join-Path $TargetDir ".harness\uninstall-policy.json"
if (Test-Path $policyPath) {
    $p = Get-Content $policyPath -Raw -Encoding utf8 | ConvertFrom-Json
    Write-Output "  uninstall lock: LOCKED (pm='$($p.pm)')"
} else {
    Write-Output "  uninstall lock: none"
}

# --- Verdict ---
$unresolved = $conflictFiles.Count + $skippedFiles.Count
$healthy = ($missing.Count -eq 0) -and $hooksWired -and ($unresolved -eq 0)
if ($healthy) {
    Write-Output "== RESULT: APPLIED OK$(if($modified.Count){' (with ' + $modified.Count + ' locally-modified file(s) -- fine if intentional)'}else{''})$(if($keptFiles.Count){' (' + $keptFiles.Count + ' kept: yours, not overwritten)'}else{''})"
    exit 0
} else {
    Write-Output "== RESULT: NOT FULLY APPLIED"
    if ($unresolved) { Write-Output "   -> $unresolved file(s) the last install did NOT apply (conflict/skipped): resolve the .new copy by hand, or re-run install.ps1 -Force for skipped ones" }
    if ($missing.Count) { Write-Output "   -> $($missing.Count) file(s) missing: re-run install.ps1" }
    if (-not $hooksWired) { Write-Output "   -> hooks not wired: delete .claude/settings.json then re-run install (or install.ps1 -Force)" }
    exit 1
}
