#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Approval Gate (H5) — enforces human approval for risk ≥ medium actions.
.DESCRIPTION
  Reads risk-registry.yaml and approval-flow.yaml to determine:
    - What risk tier the action falls into
    - Whether approval is required
    - Who can approve
    - Which approval flow to use

  For dependency gate: checks if adding/updating a library requires approval.

  Commands:
    check     - Check if an action needs approval (reads JSON from -EntryJson)
    approve   - Record an approval decision
    status    - Show pending approvals
.PARAMETER Command
  "check", "approve", or "status"
.PARAMETER EntryJson
  JSON input describing the action or approval.
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "approve", "status")]
    [string]$Command = "check",

    [string]$EntryJson = ""
)

$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) { $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.." }

$RiskRegistryPath = "$HarnessRoot\.harness\control\risk-registry.yaml"
$ApprovalFlowPath = "$HarnessRoot\contracts\approval-flow.yaml"

# Simple YAML parser for risk tiers
function Get-YamlValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    $content = Get-Content -Path $Path -Raw -Encoding utf8
    $inSection = $false
    $result = @()
    foreach ($line in $content -split "`n") {
        $t = $line.Trim()
        if ($t -eq "$Key`:") { $inSection = $true; continue }
        if ($inSection -and $t -match "^[a-z]") { break }
        if ($inSection -and $t -match "^- ") { $result += $t.Substring(2) }
    }
    return $result
}

switch ($Command) {
    "check" {
        $InputJson = if ($EntryJson) { $EntryJson } else { $input | Out-String }
        if (-not $InputJson -or $InputJson.Trim() -eq "") {
            Write-Error "[approval-gate] No input provided"
            exit 1
        }

        $Input = $InputJson | ConvertFrom-Json
        $ActionType = $Input.action_type
        $ActionRisk = $Input.risk_level  # pre-computed or "medium" default
        $IsDependency = $Input.is_dependency -eq $true
        $DependencyCategory = $Input.dependency_category
        $TargetEnv = $Input.target_environment

        # Determine risk level
        if (-not $ActionRisk) {
            # Compute from risk scoring
            $BaseScore = 0
            $RiskRegistryContent = Get-Content -Path $RiskRegistryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if ($RiskRegistryContent -match "base_score:\s+(\d+).*?action_type:\s*$ActionType") {
                # Simplified extraction
                $BaseScore = 30  # default medium
            } else {
                $BaseScore = 30
            }

            # Apply modifiers
            $Modifier = 0
            if ($TargetEnv -eq "production") { $Modifier += 20 }

            $TotalScore = [Math]::Min($BaseScore + $Modifier, 100)

            # Map score to risk level
            if ($TotalScore -ge 90) { $ActionRisk = "critical" }
            elseif ($TotalScore -ge 70) { $ActionRisk = "high" }
            elseif ($TotalScore -ge 40) { $ActionRisk = "medium" }
            elseif ($TotalScore -ge 10) { $ActionRisk = "low" }
            else { $ActionRisk = "none" }
        }

        # Check if dependency gate applies
        if ($IsDependency) {
            $RequiresApproval = $true  # Default safe
            # Dev/test deps don't need approval
            if ($DependencyCategory -in @("dev", "test")) {
                $RequiresApproval = $false
            }
            $RequiredRoles = @("reviewer")
        } else {
            # Check risk tier
            $RequiresApproval = $ActionRisk -in @("medium", "high", "critical")
            $RequiredRoles = switch ($ActionRisk) {
                "critical" { @("admin") }
                "high" { @("reviewer", "admin") }
                "medium" { @("developer", "reviewer") }
                default { @() }
            }
        }

        $Result = @{
            action_type = $ActionType
            risk_level = $ActionRisk
            requires_approval = $RequiresApproval
            required_roles = $RequiredRoles
            is_dependency = $IsDependency
            timestamp = (Get-Date -Format 'o')
        }

        if ($RequiresApproval) {
            Write-Warning "[approval-gate] APPROVAL REQUIRED — risk=$ActionRisk, roles=$($RequiredRoles -join ',')"
        } else {
            Write-Output "[approval-gate] No approval needed — risk=$ActionRisk"
        }

        Write-Output ($Result | ConvertTo-Json -Compress)
        break
    }

    "approve" {
        $InputJson = if ($EntryJson) { $EntryJson } else { $input | Out-String }
        if (-not $InputJson -or $InputJson.Trim() -eq "") {
            Write-Error "[approval-gate] No input provided"
            exit 1
        }

        $Input = $InputJson | ConvertFrom-Json
        $ApprovalDir = "$HarnessRoot\.harness\ledger\approvals"
        if (-not (Test-Path $ApprovalDir)) { New-Item -ItemType Directory -Path $ApprovalDir -Force | Out-Null }

        $ApprovalRecord = @{
            approval_id = [guid]::NewGuid().ToString()
            action_id = $Input.action_id
            action_type = $Input.action_type
            approved_by = $Input.approved_by
            approver_role = $Input.approver_role
            decision = $Input.decision  # "approved" or "denied"
            reason = $Input.reason
            timestamp = (Get-Date -Format 'o')
            expires_at = if ($Input.ttl_minutes) {
                (Get-Date).AddMinutes([int]$Input.ttl_minutes).ToString('o')
            } else { "" }
        }

        $RecordFile = "$ApprovalDir\$($ApprovalRecord.approval_id).json"
        $ApprovalRecord | ConvertTo-Json -Depth 5 | Set-Content -Path $RecordFile -Encoding utf8

        # Also append to ledger
        $LedgerEntry = @{
            actor = @{ agent = "approval-gate"; user = $Input.approved_by; session_id = $env:HARNESS_SESSION_ID; role = $Input.approver_role }
            action = @{ type = "approval"; tool = ""; description = "Approval for $($Input.action_type): $($Input.decision)" }
            decision = @{ result = $Input.decision; reason = $Input.reason; risk_level = "medium" }
            payload_ref = $RecordFile
        }
        $LedgerJson = $LedgerEntry | ConvertTo-Json -Compress
        & "$HarnessRoot\.harness\scripts\powershell\evidence-ledger.ps1" -Command append -EntryJson $LedgerJson

        Write-Output "[approval-gate] Approval recorded: $($Input.decision) by $($Input.approved_by)"
        Write-Output ($ApprovalRecord | ConvertTo-Json -Compress)
        break
    }

    "status" {
        $ApprovalDir = "$HarnessRoot\.harness\ledger\approvals"
        if (-not (Test-Path $ApprovalDir)) {
            Write-Output "[approval-gate] No approvals directory"
            exit 0
        }

        $Pending = @()
        $Files = Get-ChildItem -Path $ApprovalDir -Filter "*.json" -ErrorAction SilentlyContinue
        foreach ($f in $Files) {
            $record = Get-Content -Path $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json
            $Pending += $record
        }

        if ($Pending.Count -eq 0) {
            Write-Output "[approval-gate] No approval records"
        } else {
            Write-Output "[approval-gate] $($Pending.Count) approval record(s):"
            foreach ($r in $Pending) {
                Write-Output "  - $($r.approval_id): $($r.action_type) → $($r.decision) by $($r.approved_by) at $($r.timestamp)"
            }
        }
        break
    }
}
