#!/usr/bin/env pwsh
<#
.SYNOPSIS
  SessionEnd hook — finalises session state, flushes ledger and telemetry.
.DESCRIPTION
  - Flushes any buffered ledger entries
  - Archives session telemetry
  - Cleans up session temp workspace
.NOTES
  Part of Harness Runtime Plane (PEP). Runs at session termination.
#>

$InputJson = $input | Out-String

$HarnessRoot = $env:HARNESS_ROOT
$SessionId = $env:HARNESS_SESSION_ID

if (-not $HarnessRoot) {
    $HarnessRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

# H6: sample the whole session's real token usage from the transcript.
# SubagentStop only covers subagents; this covers the main agent.
try {
    $Sampler = Join-Path $PSScriptRoot "agentops-sampler.ps1"
    if ($InputJson.Trim() -and (Test-Path $Sampler)) {
        $InputJson | & $Sampler *>$null
    }
} catch {
    # Sampling is best-effort; never fail session end on it.
}

# C9 — seal the session: append one ledger entry recording that the session ended
# and the chain head it ended at. Written BEFORE push so the seal ships in the
# same telemetry run. A chain that only grows on tool calls has no per-session
# boundary; the seal gives an auditor one. Best-effort (parity with the .sh).
try {
    $LedgerScript = Join-Path $PSScriptRoot "evidence-ledger.ps1"
    $ChainFile = "$HarnessRoot\.harness\ledger\chain.jsonl"
    if ((Test-Path $LedgerScript) -and (Test-Path $ChainFile)) {
        $headHash = ""
        try { $headHash = ((Get-Content $ChainFile -Tail 1 -Encoding utf8 | ConvertFrom-Json | Select-Object -Last 1).entry_hash) } catch { }
        $seal = @{
            actor = @{ agent = "harness"; user = "$env:HARNESS_USER"; session_id = "$SessionId"; role = "system" }
            action = @{ type = "pipeline_event"; tool = "session-end"; description = "session sealed; chain head $($headHash.Substring(0,[Math]::Min(16,$headHash.Length)))" }
            decision = @{ result = "allow"; reason = "session end"; risk_level = "none" }
        } | ConvertTo-Json -Compress -Depth 4
        & $LedgerScript append -EntryJson $seal *>$null
    }
} catch { }

# Codex collection is NOT called here. It lives inside push-telemetry.ps1, which
# this block invokes a few lines down, so it runs on this path anyway -- and on
# the fleet driver's timer, which needs no Claude session at all. Calling it in
# both places would be a second copy to keep in step, which is how three copies
# of the release classifier ended up disagreeing (B-13/B-14).

# Push telemetry to the Control Portal if this checkout is configured for it
# (.harness/portal-sync.json) — the sync path for machines the backend can't
# read (e.g. Windows checkouts). Best-effort, never fails the hook.
try {
    $Pusher = Join-Path $PSScriptRoot "push-telemetry.ps1"
    if (Test-Path $Pusher) { & $Pusher -HarnessRoot $HarnessRoot *>$null }
} catch { }

# Archive session telemetry
$TelemetryDir = "$HarnessRoot\.harness\telemetry"
$SessionLog = "$TelemetryDir\tool-calls.log"
if (Test-Path $SessionLog) {
    $ArchiveFile = "$TelemetryDir\session-$SessionId-$(Get-Date -Format 'yyyyMMddHHmmss').log"
    Copy-Item $SessionLog $ArchiveFile -Force
}

# Cleanup session temp
$SessionTemp = "$HarnessRoot\.harness\tmp\$SessionId"
if (Test-Path $SessionTemp) {
    Remove-Item -Recurse -Force $SessionTemp -ErrorAction SilentlyContinue
}

# F4 - nhac ghi cong suc nguoi neu hom nay chua co dong nao.
# CHI IN, khong hoi: hook chay phi tuong tac, mot lenh doc stdin se treo.
# Best-effort tuyet doi - mot loi o day khong duoc lam hong session-end.
try {
    $HumanLog = "$HarnessRoot\.harness\telemetry\human-effort.jsonl"
    $Today    = Get-Date -Format 'yyyy-MM-dd'
    $HasToday = $false
    if (Test-Path $HumanLog) {
        # -Tail: chi doc duoi file, khong nap ca file vao RAM khi no lon dan.
        foreach ($l in (Get-Content $HumanLog -Tail 50 -ErrorAction SilentlyContinue)) {
            if ($l -like "*`"date`": `"$Today`"*") { $HasToday = $true; break }
        }
    }
    if (-not $HasToday) {
        Write-Output "[harness] F4: chua ghi cong suc nguoi cho $Today. Gio that + so lan ban sua AI la hai so khong may nao do ho duoc:"
        Write-Output "[harness]   powershell -File `"$PSScriptRoot\log-human.ps1`" -Minutes <phut> -Edits <so lan sua> -Task `"<viec>`""
    }
} catch { }

Write-Output "[harness] Session $SessionId ended at $(Get-Date -Format 'o')"
exit 0
