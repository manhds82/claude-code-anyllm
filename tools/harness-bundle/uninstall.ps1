#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Harness Bundle uninstaller (L5). Removes exactly the files a bundle installed
  into a project -- precise (reads the manifest), safe (keeps user-modified
  files unless -Force), gated (confirm or PM approval code), and audited.

.HOW THE GATE WORKS
  - If the project has a PM lock (.harness/uninstall-policy.json, created by
    harness-lock.ps1), uninstall REFUSES unless -ApprovalCode matches.
  - Otherwise it asks for an interactive confirmation (type the project folder
    name), which -Force skips.
  Every attempt (allowed/denied/completed) is appended to
  .harness/telemetry/security-events.jsonl and to a receipt file at the project
  root that -Purge does NOT delete.

.HONESTY (C10)
  This is a soft gate + audit trail, NOT an OS-level lock. Anyone with write
  access can delete the files by hand. For enforcement that cannot be bypassed
  locally, protect .harness/** .claude/** contracts/** with CODEOWNERS +
  branch protection so removal needs PM approval at merge time (see README).

.USAGE
  .\uninstall.ps1 -TargetDir <project> [-BundleFile <x.bundle.json>]
                  [-ApprovalCode <code>] [-Purge] [-Force]
#>
param(
    [Parameter(Mandatory)][string]$TargetDir,
    [string]$BundleFile = "",
    [string]$ApprovalCode = "",
    [switch]$Purge = $false,
    [switch]$Force = $false
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-NoBom([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::AppendAllText($Path, $Text, $Utf8NoBom)
}

function Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLower()
}

if (-not (Test-Path $TargetDir)) { throw "Target not found: $TargetDir" }
$TargetDir = (Resolve-Path $TargetDir).Path
$leaf = Split-Path -Leaf $TargetDir

# --- Resolve what to remove. Priority:
#   1) explicit -BundleFile (path + b64 -> original sha256)
#   2) the install receipt .harness/.bundle-manifest.json (path + sha256)
#   3) newest *.bundle.json next to this script
# $meta = {name, version}; $fileList = [{path, sha256}]. ---
$receiptPath = Join-Path $TargetDir ".harness\.bundle-manifest.json"
$meta = $null; $fileList = @()
if ($BundleFile) {
    if (-not (Test-Path $BundleFile)) { throw "Bundle file not found: $BundleFile" }
    $bundle = Get-Content -Path $BundleFile -Raw -Encoding utf8 | ConvertFrom-Json
    $meta = @{ name = $bundle.name; version = $bundle.version }
    $fileList = foreach ($f in $bundle.files) { @{ path = $f.path; sha256 = (Sha256Hex ([Convert]::FromBase64String($f.b64))) } }
} elseif (Test-Path $receiptPath) {
    $r = Get-Content -Path $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
    $meta = @{ name = $r.name; version = $r.version }
    $fileList = foreach ($f in $r.files) { @{ path = $f.path; sha256 = $f.sha256 } }
} else {
    $cand = Get-ChildItem -Path $PSScriptRoot -Filter "*.bundle.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $cand) { throw "No -BundleFile, no install receipt (.harness/.bundle-manifest.json), and no *.bundle.json next to this script." }
    $bundle = Get-Content -Path $cand.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    $meta = @{ name = $bundle.name; version = $bundle.version }
    $fileList = foreach ($f in $bundle.files) { @{ path = $f.path; sha256 = (Sha256Hex ([Convert]::FromBase64String($f.b64))) } }
}

# --- Audit helper (writes to both the telemetry log and a purge-proof receipt) ---
$stamp = Get-Date -Format 'o'
$receipt = Join-Path $TargetDir ("harness-uninstall-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
$secLog = Join-Path $TargetDir ".harness\telemetry\security-events.jsonl"
function Audit([string]$Event, [string]$Detail) {
    $rec = [ordered]@{
        event_id = [guid]::NewGuid().ToString(); timestamp = $stamp
        type = "bundle_uninstall"; event = $Event; bundle = $meta.name
        version = $meta.version; target = $TargetDir; actor = $env:USERNAME
        detail = $Detail
    } | ConvertTo-Json -Compress
    try { if (Test-Path (Split-Path $secLog)) { Write-NoBom $secLog ($rec + "`n") } } catch {}
    Write-NoBom $receipt ($rec + "`n")
}

# --- Gate: PM lock OR interactive confirm ---
$policyPath = Join-Path $TargetDir ".harness\uninstall-policy.json"
if (Test-Path $policyPath) {
    $policy = Get-Content $policyPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($policy.require_approval) {
        if (-not $ApprovalCode) {
            Audit "denied" "PM lock set by $($policy.pm); no ApprovalCode provided"
            throw "This project is PM-locked ($($policy.pm)). Re-run with -ApprovalCode <code>."
        }
        $salt = [Convert]::FromBase64String($policy.salt)
        $codeBytes = [Text.Encoding]::UTF8.GetBytes($ApprovalCode)
        $computed = Sha256Hex ($salt + $codeBytes)
        if ($computed -ne $policy.hash) {
            Audit "denied" "wrong ApprovalCode against PM lock ($($policy.pm))"
            throw "ApprovalCode does not match the PM lock. Uninstall refused."
        }
        Write-Output "[uninstall] PM approval OK (lock owner: $($policy.pm))."
    }
} elseif (-not $Force) {
    if ([Console]::IsInputRedirected) {
        throw "No PM lock and no interactive console. Re-run with -Force (or in a real terminal to confirm)."
    }
    $answer = Read-Host "Type the project folder name '$leaf' to confirm uninstall"
    if ($answer -ne $leaf) { Audit "aborted" "confirmation mismatch"; throw "Confirmation failed. Aborted." }
}

Audit "started" "purge=$Purge force=$Force"
Write-Output "[uninstall] $($meta.name) v$($meta.version) from $TargetDir"

# --- Remove exactly the files the bundle installed ---
$removed = 0; $keptModified = 0; $absent = 0
$backupDir = Join-Path $TargetDir ".harness-uninstall-backup"
foreach ($f in $fileList) {
    $rel = $f.path.Replace("/", [char]92)
    $dest = Join-Path $TargetDir $rel
    if (-not (Test-Path $dest)) { $absent++; continue }

    $curHash = Sha256Hex ([System.IO.File]::ReadAllBytes($dest))
    $origHash = $f.sha256
    if ($curHash -eq $origHash) {
        Remove-Item $dest -Force; $removed++
    } elseif ($Force) {
        # user-modified: back up before deleting
        $bkp = Join-Path $backupDir $rel
        $bkpDir = Split-Path -Parent $bkp
        if (-not (Test-Path $bkpDir)) { New-Item -ItemType Directory -Path $bkpDir -Force | Out-Null }
        Copy-Item $dest $bkp -Force
        Remove-Item $dest -Force; $removed++
    } else {
        Write-Output "  [KEPT] $($f.path) (modified since install; use -Force to back up + remove)"
        $keptModified++
    }
}

# --- Optional purge of runtime data (not part of the bundle) ---
if ($Purge) {
    foreach ($rt in @(".harness\ledger", ".harness\telemetry")) {
        $p = Join-Path $TargetDir $rt
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Output "  [PURGE] $rt" }
    }
}

# --- Remove policy + install receipt last (only reached if approved) + prune empty dirs ---
if (Test-Path $policyPath) { Remove-Item $policyPath -Force }
if (Test-Path $receiptPath) { Remove-Item $receiptPath -Force }
foreach ($d in @("contracts", ".claude", ".harness")) {
    $p = Join-Path $TargetDir $d
    if ((Test-Path $p) -and -not (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue)) {
        Remove-Item $p -Recurse -Force
    }
}

Audit "completed" "removed=$removed keptModified=$keptModified absent=$absent purge=$Purge"
Write-Output "[uninstall] done: $removed removed, $keptModified kept (modified), $absent already absent."
if ($keptModified -gt 0) { Write-Output "[uninstall] $keptModified modified file(s) left in place; re-run with -Force to remove (backed up to .harness-uninstall-backup)." }
Write-Output "[uninstall] audit receipt: $receipt"
