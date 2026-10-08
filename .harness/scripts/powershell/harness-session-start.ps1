#!/usr/bin/env pwsh
<#
.SYNOPSIS
  SessionStart hook — initialises per-session state.
  Called once when Claude Code session begins.
.DESCRIPTION
  - Sources harness environment
  - Verifies .harness/ directory integrity
  - Creates session-scoped temp workspace
.NOTES
  Part of Harness Runtime Plane (PEP). Defense-in-depth, bypassable locally.
#>

$HarnessRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

# Worktree-aware root resolution. When Claude Code runs a session inside a git
# worktree, that worktree has its own working directory but shares the main
# repo's .git -- and usually does NOT carry its own .harness/. A hook that
# resolves purely by $PSScriptRoot..\..\.. then points at a directory with no
# .harness, so every ledger/telemetry write lands nowhere and is lost SILENTLY.
# One consuming project reported exactly this: two weeks of zero H2/H5 evidence
# with no error. If .harness is missing where we think it is, ask git where the
# common dir lives and use its parent -- the main checkout, where .harness is.
if (-not (Test-Path "$HarnessRoot\.harness")) {
    try {
        $commonDir = (& git -C $HarnessRoot rev-parse --git-common-dir 2>$null)
        if ($commonDir) {
            if (-not [System.IO.Path]::IsPathRooted($commonDir)) { $commonDir = Join-Path $HarnessRoot $commonDir }
            $mainRepo = Split-Path -Parent $commonDir
            if ($mainRepo -and (Test-Path "$mainRepo\.harness")) {
                Write-Output "[harness] worktree detected -- ledger/telemetry -> main checkout $mainRepo"
                $HarnessRoot = $mainRepo
            }
        }
    } catch { }
}

$SessionId = [guid]::NewGuid().ToString()

# Record a hook failure to a durable log instead of swallowing it. The hooks are
# best-effort by design -- a ledger or telemetry write must never break a
# session -- but "best-effort" had meant "swallow forever", so a project whose
# evidence pipeline was dead had no way to know except watching its Portal score
# fall. One line here, read back by `harness doctor`, turns a silent 0 into a
# diagnosable one. Writing the error log itself is wrapped so it can never throw.
function Write-HookError([string]$Hook, [string]$Message) {
    try {
        $log = "$HarnessRoot\.harness\telemetry\hook-errors.log"
        $dir = Split-Path -Parent $log
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = (@{ timestamp = (Get-Date -Format 'o'); hook = $Hook; error = $Message; session_id = $SessionId } | ConvertTo-Json -Compress)
        [System.IO.File]::AppendAllText($log, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# Verify essential directories exist
$requiredDirs = @(
    "$HarnessRoot\.harness\control",
    "$HarnessRoot\.harness\scripts\powershell",
    "$HarnessRoot\.harness\ledger",
    "$HarnessRoot\.harness\telemetry",
    "$HarnessRoot\contracts"
)
foreach ($dir in $requiredDirs) {
    if (-not (Test-Path $dir)) {
        Write-Warning "[harness-session-start] Missing directory: $dir"
    }
}

# Create session temp workspace
$SessionTemp = "$HarnessRoot\.harness\tmp\$SessionId"
New-Item -ItemType Directory -Path $SessionTemp -Force | Out-Null

# Set session env vars for downstream hooks
$env:HARNESS_SESSION_ID = $SessionId
$env:HARNESS_ROOT = $HarnessRoot
$env:HARNESS_SESSION_START = (Get-Date -Format 'o')

# Issue identity token for the session (D9)
$RolesFile = "$HarnessRoot\.harness\control\session-roles.json"
$GatewayIssuer = "$HarnessRoot\gateway\src\oidc-issuer.py"
# Each Test-Path MUST be parenthesised on its own. Written as
# `Test-Path $RolesFile -and (Test-Path $GatewayIssuer)`, PowerShell binds
# `-and` as a PARAMETER of Test-Path and throws ParameterBindingException --
# which, with $ErrorActionPreference = "Stop" and a hook that swallows output,
# kills the whole SessionStart hook right here. Everything below (including the
# context-build that refreshes pipeline-context.yaml) then never runs, H1-2
# starts failing on staleness, and the CASAN score drifts down with no error
# anyone can see. Found by a consuming project that hit it, debugged it, and
# fixed their own copy; the bundle kept shipping the broken line to everyone
# else. Verified in a real PowerShell 5.1: the old form throws, this one does not.
if ((Test-Path $RolesFile) -and (Test-Path $GatewayIssuer)) {
    $DefaultRole = (Get-Content $RolesFile -Raw -Encoding utf8 | ConvertFrom-Json).default_role
    if (-not $DefaultRole) { $DefaultRole = "developer" }
    $TokenJson = & python $GatewayIssuer --agent "session-init" --user "local" --project "harness" --role $DefaultRole --session-id $SessionId 2>$null
    if ($TokenJson) {
        $TokenObj = $TokenJson | ConvertFrom-Json
        $env:HARNESS_AGENT_TOKEN = $TokenObj.token
        Write-Output "[harness] Identity token issued: $($TokenObj.token_id) role=$DefaultRole"
    }
} else {
    Write-Output "[harness] No identity config — running without JWT (D9 bypassed)"
}

# H1 — build/refresh the pipeline-context pointer store (best-effort).
$ContextBuild = "$PSScriptRoot\harness-context-build.ps1"
if (Test-Path $ContextBuild) {
    try { & $ContextBuild -HarnessRoot $HarnessRoot } catch { Write-Warning "[harness] context build skipped: $_" }
}

# C9 — genesis the immutable ledger if it has never been written. Without this,
# chain.jsonl is created LAZILY on the first side-effect call, so a project that
# has made none has no chain at all -- and a chain with no genesis cannot prove
# it is intact from the start, which is the whole point of a hash chain. Three
# consuming projects were found with no chain.jsonl despite identical hooks.
# Best-effort: a ledger failure must never break the developer's session.
$ChainFile = "$HarnessRoot\.harness\ledger\chain.jsonl"
if (-not (Test-Path $ChainFile)) {
    try {
        $LedgerScript = "$PSScriptRoot\evidence-ledger.ps1"
        if (Test-Path $LedgerScript) {
            & $LedgerScript init *>$null
            if (Test-Path $ChainFile) { Write-Output "[harness] ledger genesis written -> $ChainFile" }
        }
    } catch {
        Write-HookError "session-start" "ledger genesis failed: $($_.Exception.Message)"
    }
}

Write-Output "[harness] Session $SessionId started at $env:HARNESS_SESSION_START"
