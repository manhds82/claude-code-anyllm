#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Flip the "which Claude account is active on this machine" pointer (H6 attribution).
.DESCRIPTION
  Run this THE INSTANT you finish re-authenticating Claude Code to a different account.
  Overwrites a GLOBAL (not per-project) pointer file at ~\.harness\active-account.local.json
  -- global because Claude Code's login is a singleton per OS user, and this maintainer runs
  ~11 project checkouts on one machine: a per-project pointer would mean repeating the switch
  in every checkout, defeating the "one command, sub-second" goal.

  agentops-sampler.ps1 reads this file fresh on every SubagentStop and stamps its value onto
  each telemetry record as "active_account", so the Portal can attribute Tier-2 token usage to
  the account that actually produced it -- agentops.log itself never needs an account field.

  No network call. Nothing to roll back: worst case is stamping the wrong label on samples
  taken between the real switch and running this command.
.PARAMETER Account
  The account identifier now active (e.g. an email). Stored verbatim (trimmed) -- this script
  has no way to validate what accounts exist; it records what the human says is now current.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Account
)

$HarnessUserDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".harness"
if (-not (Test-Path $HarnessUserDir)) { New-Item -ItemType Directory -Path $HarnessUserDir -Force | Out-Null }

$PointerFile = Join-Path $HarnessUserDir "active-account.local.json"

# Read the CURRENT value first so the echo can report what we're switching FROM.
# A corrupted/unreadable pointer is treated as "no prior value" -- it must never
# block the switch itself.
$OldAccount = "(none)"
if (Test-Path $PointerFile) {
    try {
        $Prev = Get-Content -Path $PointerFile -Raw -Encoding utf8 | ConvertFrom-Json
        if ($Prev.active_account) { $OldAccount = "$($Prev.active_account)" }
    } catch {
        # Corrupted pointer -- fall through with "(none)".
    }
}

$NewAccount = $Account.Trim()
$Record = @{
    active_account = $NewAccount
    set_at         = (Get-Date -Format 'o')
} | ConvertTo-Json -Compress

# Atomic overwrite: write to a temp file in the SAME directory (so the rename is
# same-volume/atomic on NTFS), then Move-Item -Force onto the real path -- a sampler
# hook reading concurrently from another process never observes a half-written file.
# UTF8 with NO BOM (repo convention -- see Add-JsonLine in agentops-sampler.ps1): a
# leading EF BB BF makes the first line unparseable to a plain json.loads reader.
$TempFile = Join-Path $HarnessUserDir ("active-account.local.json.tmp." + [Guid]::NewGuid().ToString("N"))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($TempFile, $Record, $Utf8NoBom)
Move-Item -Path $TempFile -Destination $PointerFile -Force

Write-Output "$OldAccount -> $NewAccount"
exit 0
