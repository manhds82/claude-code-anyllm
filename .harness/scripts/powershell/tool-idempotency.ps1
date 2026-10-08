#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Idempotency Executor — ensures side-effect tools run at most once per unique key (H2).
.DESCRIPTION
  Reads the tool-registry.json to determine idempotency_key_pattern for the given tool.
  Computes the key from input parameters, checks a file-based lock store.
  If key exists → skip (return cached result).
  If key new → acquire lock, execute, record result.
.PARAMETER ToolName
  Name of the tool being called (e.g. "codeprovider-mcp.deploy").
.PARAMETER ToolInput
  JSON string of the tool's input parameters (used to compute the idempotency key).
.PARAMETER ExecuteCommand
  Script block or command to execute if this is a first-time call.
.OUTPUTS
  JSON with { status: "executed"|"skipped"|"error", key, result }
.NOTES
  Uses file-based lock store at .harness/ledger/idempotency/
  C9: Every execution is logged to the ledger.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ToolName,

    [Parameter(Mandatory = $true)]
    [string]$ToolInput,

    [ScriptBlock]$ExecuteCommand = $null
)

# Resolve harness root
$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) {
    $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.."
}

# Lock store directory
$LockDir = "$HarnessRoot\.harness\ledger\idempotency"
if (-not (Test-Path $LockDir)) {
    New-Item -ItemType Directory -Path $LockDir -Force | Out-Null
}

# --- Resolve idempotency key pattern from tool-registry ---
$RegistryPath = "$HarnessRoot\.harness\control\tool-registry.json"
$IdempotencyPattern = $null
$SideEffect = $false

if (Test-Path $RegistryPath) {
    try {
        $Registry = Get-Content -Path $RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
        $ToolEntry = $Registry.tools.$ToolName
        if ($ToolEntry) {
            $IdempotencyPattern = $ToolEntry.idempotency_key_pattern
            $SideEffect = $ToolEntry.side_effect
        }
    } catch {
        Write-Warning "[tool-idempotency] Cannot read registry: $_"
    }
}

# If no idempotency pattern or not side-effect, just execute directly
if (-not $IdempotencyPattern -or -not $SideEffect) {
    if ($ExecuteCommand) {
        $result = & $ExecuteCommand
        return @{ status = "executed"; key = $null; result = $result } | ConvertTo-Json -Compress
    }
    return @{ status = "executed"; key = $null } | ConvertTo-Json -Compress
}

# --- Compute idempotency key from pattern and input ---
$InputObj = $ToolInput | ConvertFrom-Json
$IdKey = $IdempotencyPattern

# Replace {placeholders} with actual values from input
$IdKey = $IdKey -replace '{tool}', $ToolName
foreach ($prop in $InputObj.PSObject.Properties) {
    $val = if ($prop.Value -is [string]) { $prop.Value } else { $prop.Value | ConvertTo-Json -Compress }
    $hash = Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($val))) -Algorithm SHA256
    $shortHash = $hash.Hash.Substring(0, 16).ToLower()

    $IdKey = $IdKey -replace "{${$($prop.Name)}}", $prop.Value
    $IdKey = $IdKey -replace "{${$($prop.Name)}_hash}", $shortHash
}

# Hash the final key for filesystem safety
$KeyBytes = [System.Text.Encoding]::UTF8.GetBytes($IdKey)
$KeyHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($KeyBytes)) -Algorithm SHA256).Hash.Substring(0, 32).ToLower()
$LockFile = "$LockDir\$KeyHash.json"

# --- Check if already executed ---
if (Test-Path $LockFile) {
    try {
        $CachedResult = Get-Content -Path $LockFile -Raw -Encoding utf8 | ConvertFrom-Json
        Write-Warning "[tool-idempotency] SKIPPED: Tool '$ToolName' already executed with key '$IdKey'"
        return @{
            status = "skipped"
            key = $IdKey
            key_hash = $KeyHash
            previous_result = $CachedResult.result
            executed_at = $CachedResult.executed_at
        } | ConvertTo-Json -Compress
    } catch {
        # Corrupted lock file — treat as new
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    }
}

# --- Acquire lock and execute ---
try {
    # Write lock file first (atomic create)
    $LockContent = @{
        tool = $ToolName
        key = $IdKey
        key_hash = $KeyHash
        input_hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($ToolInput))) -Algorithm SHA256).Hash
        executed_at = (Get-Date -Format 'o')
        status = "executing"
    } | ConvertTo-Json -Compress
    Set-Content -Path $LockFile -Value $LockContent -Encoding utf8 -NoNewline

    # Execute
    $Result = $null
    if ($ExecuteCommand) {
        $Result = & $ExecuteCommand
    }

    # Update lock file with result
    $LockContent = @{
        tool = $ToolName
        key = $IdKey
        key_hash = $KeyHash
        input_hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($ToolInput))) -Algorithm SHA256).Hash
        executed_at = (Get-Date -Format 'o')
        status = "completed"
        result = $Result
    } | ConvertTo-Json -Compress
    Set-Content -Path $LockFile -Value $LockContent -Encoding utf8 -NoNewline

    return @{
        status = "executed"
        key = $IdKey
        key_hash = $KeyHash
        result = $Result
    } | ConvertTo-Json -Compress

} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Error "[tool-idempotency] ERROR: $ErrorMsg"
    return @{ status = "error"; key = $IdKey; error = $ErrorMsg } | ConvertTo-Json -Compress
}
