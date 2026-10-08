#!/usr/bin/env pwsh
<#
.SYNOPSIS
  H7 Orchestration — transaction boundary for risky workflows (deploy).
.DESCRIPTION
  A real, git-based restore point so a deploy/migration workflow can roll back
  if a later step fails (casan-policies orchestration.transaction.rollback_on_failure).

    snapshot  -> tag current HEAD as a restore point (records SHA)
    restore   -> stash any uncommitted work (named, recoverable) then reset the
                 working tree back to the restore point
    list      -> show restore points

  Usage:
    harness-rollback.ps1 -Action snapshot
    harness-rollback.ps1 -Action restore
.NOTES
  Client-side helper shipped in the bundle; a workflow calls snapshot before and
  restore on failure. Uncommitted work is stashed (never silently dropped).
#>
param(
    [ValidateSet("snapshot", "restore", "list")]
    [string]$Action = "snapshot",
    [string]$Tag = "harness-restore-point",
    [string]$RepoDir = ""
)

if (-not $RepoDir) { $RepoDir = (Get-Location).Path }
Push-Location $RepoDir
try {
    & git rev-parse --is-inside-work-tree *>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning "[rollback] not a git repo: $RepoDir"; exit 0 }

    switch ($Action) {
        "snapshot" {
            $sha = (& git rev-parse HEAD).Trim()
            & git tag -f $Tag $sha *>$null
            Write-Output "[rollback] restore point '$Tag' -> $($sha.Substring(0,10))"
        }
        "list" {
            $sha = (& git rev-parse -q --verify "refs/tags/$Tag" 2>$null)
            if ($sha) { Write-Output "[rollback] $Tag -> $($sha.Substring(0,10))" }
            else { Write-Output "[rollback] no restore point '$Tag' yet" }
        }
        "restore" {
            $sha = (& git rev-parse -q --verify "refs/tags/$Tag" 2>$null)
            if (-not $sha) { Write-Warning "[rollback] no restore point '$Tag' — run snapshot first"; exit 1 }
            # Preserve uncommitted work first (named stash, recoverable).
            $dirty = (& git status --porcelain)
            if ($dirty) {
                & git stash push -u -m "harness-rollback-autostash" *>$null
                Write-Output "[rollback] uncommitted work stashed as 'harness-rollback-autostash' (git stash list)"
            }
            & git reset --hard $Tag *>$null
            Write-Output "[rollback] restored working tree to '$Tag' ($($sha.Substring(0,10)))"
        }
    }
} finally {
    Pop-Location
}
exit 0
