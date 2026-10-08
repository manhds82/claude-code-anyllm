#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Domain Firewall — checks if an agent is allowed to read/write a given path (H4).
.DESCRIPTION
  Reads guard-zones.json (SSOT) and evaluates:
    - Which zone the target path falls into
    - Whether the agent is in the allowed list
    - Whether the operation (read/write) is permitted
  Returns exit 0 (allowed) or exit 2 (blocked).
.PARAMETER AgentName
  Name of the agent requesting access (e.g. "developer", "analyst", "boss").
.PARAMETER TargetPath
  Absolute or relative path the agent wants to access.
.PARAMETER Operation
  "read" or "write".
.NOTES
  C2: Reads config from guard-zones.json — never hardcode zones in script.
  C10: Local hook is defense-in-depth; high-risk paths need server-side PDP.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AgentName,

    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("read", "write")]
    [string]$Operation
)

# Resolve harness root
$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) {
    $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.."
}

# Load guard zones
$ZonesPath = "$HarnessRoot\.harness\control\guard-zones.json"
if (-not (Test-Path $ZonesPath)) {
    # No zones = permissive
    exit 0
}

try {
    $ZonesConfig = Get-Content -Path $ZonesPath -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
    Write-Warning "[domain-firewall] Cannot read guard-zones.json: $_"
    exit 0
}

# Normalise path separators and resolve relative paths
$NormalisedPath = $TargetPath.Replace('/', '\').Replace($HarnessRoot + '\', '')

$DefaultAction = $ZonesConfig.default_action  # "deny" or "allow"

# Find matching zone(s)
$MatchingZones = @()
foreach ($zone in $ZonesConfig.zones) {
    foreach ($pattern in $zone.paths) {
        $pattern = $pattern.Replace('/', '\')
        # Convert glob-like patterns to regex
        $regex = '^' + [regex]::Escape($pattern).Replace('\*\*', '.*').Replace('\*', '[^\\]*') + '$'
        if ($NormalisedPath -match $regex) {
            $MatchingZones += $zone
            break
        }
    }
}

if ($MatchingZones.Count -eq 0) {
    # No zone matches
    if ($DefaultAction -eq "deny") {
        Write-Warning "[domain-firewall] BLOCKED: '$NormalisedPath' matches no zone (default: deny)"
        exit 2
    }
    exit 0
}

# Evaluate each matching zone
foreach ($zone in $MatchingZones) {
    # Check agent is allowed (wildcard "*" means any)
    $AgentAllowed = ($zone.allowed_agents -contains '*') -or ($zone.allowed_agents -contains $AgentName)
    if (-not $AgentAllowed) {
        Write-Warning "[domain-firewall] BLOCKED: Agent '$AgentName' not allowed in zone '$($zone.name)'"
        exit 2
    }

    # Check operation allowed
    $OpAllowed = $zone.allowed_operations -contains $Operation
    if (-not $OpAllowed) {
        # Check exceptions
        $Exception = $zone.exceptions | Where-Object { $_.agent -eq $AgentName -and $_.operation -eq $Operation }
        if (-not $Exception) {
            Write-Warning "[domain-firewall] BLOCKED: Operation '$Operation' not allowed in zone '$($zone.name)' for agent '$AgentName'"
            exit 2
        }
    }
}

# All checks passed
exit 0
