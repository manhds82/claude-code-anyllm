#!/usr/bin/env pwsh
<#
.SYNOPSIS
  PM lock for the governance harness (L5). Sets/clears an approval requirement
  that uninstall.ps1 enforces: once locked, uninstall refuses without the PM's
  approval code.

.HOW IT STORES THE CODE
  The code is never stored in clear text. .harness/uninstall-policy.json holds
  { require_approval, pm, created_at, salt, hash } where hash = SHA-256(salt +
  code). Verification re-derives the hash from the code you pass to uninstall.

.HONESTY (C10)
  This is a deterrent + audit gate on the uninstall SCRIPT, not an OS lock. A
  user with write access can delete .harness/ by hand. Pair it with CODEOWNERS
  + branch protection on .harness/** for enforcement that holds at merge time.

.USAGE
  .\harness-lock.ps1 -TargetDir <project> -Action Set   -PM "Dau Sy Manh <manhds@>"
  .\harness-lock.ps1 -TargetDir <project> -Action Status
  .\harness-lock.ps1 -TargetDir <project> -Action Clear -ApprovalCode <code>
#>
param(
    [Parameter(Mandatory)][string]$TargetDir,
    [ValidateSet("Set", "Clear", "Status")][string]$Action = "Status",
    [string]$PM = "",
    [string]$ApprovalCode = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $TargetDir)) { throw "Target not found: $TargetDir" }
$TargetDir = (Resolve-Path $TargetDir).Path
$harnessDir = Join-Path $TargetDir ".harness"
if (-not (Test-Path $harnessDir)) { throw "No .harness/ in target -- is the bundle installed there?" }
$policyPath = Join-Path $harnessDir "uninstall-policy.json"

function Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLower()
}
function Read-PlainSecret([string]$Prompt) {
    $sec = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

switch ($Action) {
    "Status" {
        if (Test-Path $policyPath) {
            $p = Get-Content $policyPath -Raw -Encoding utf8 | ConvertFrom-Json
            Write-Output "[lock] LOCKED. require_approval=$($p.require_approval) pm='$($p.pm)' since=$($p.created_at)"
        } else {
            Write-Output "[lock] not locked (uninstall needs only interactive confirmation)."
        }
    }
    "Set" {
        if (-not $PM) { throw "Set requires -PM '<name/email>' (recorded as the lock owner)." }
        $code = Read-PlainSecret "Set uninstall approval code (hidden)"
        if (-not $code) { throw "Empty code." }
        $confirm = Read-PlainSecret "Re-enter the code"
        if ($code -ne $confirm) { throw "Codes do not match." }

        $saltBytes = New-Object byte[] 16
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
        $hash = Sha256Hex ($saltBytes + [Text.Encoding]::UTF8.GetBytes($code))

        $policy = [ordered]@{
            require_approval = $true
            pm               = $PM
            created_at       = (Get-Date -Format 'o')
            salt             = [Convert]::ToBase64String($saltBytes)
            hash             = $hash
        } | ConvertTo-Json
        [System.IO.File]::WriteAllText($policyPath, $policy, $Utf8NoBom)
        $code = $null; $confirm = $null
        Write-Output "[lock] LOCKED for '$PM'. uninstall.ps1 now needs -ApprovalCode."
        Write-Output "[lock] Tip: also add CODEOWNERS + branch protection on .harness/** for merge-time enforcement."
    }
    "Clear" {
        if (-not (Test-Path $policyPath)) { Write-Output "[lock] already not locked."; break }
        $p = Get-Content $policyPath -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not $ApprovalCode) { $ApprovalCode = Read-PlainSecret "Approval code to clear the lock" }
        $salt = [Convert]::FromBase64String($p.salt)
        $computed = Sha256Hex ($salt + [Text.Encoding]::UTF8.GetBytes($ApprovalCode))
        if ($computed -ne $p.hash) { throw "Approval code does not match. Lock NOT cleared." }
        Remove-Item $policyPath -Force
        Write-Output "[lock] cleared. uninstall now needs only interactive confirmation."
    }
}
