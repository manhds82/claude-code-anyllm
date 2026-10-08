#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Budget Meter (H6) — measures cost/token consumption per project/user/agent.
  Reads budget from project.yaml, compares against actuals from telemetry.
.DESCRIPTION
  Commands:
    check     - Check current budget status (reads from telemetry)
    record    - Record a cost entry (reads JSON from -EntryJson)
    alert     - Check thresholds and trigger alerts if exceeded

  Thresholds:
    - 80% of budget → alert (warning)
    - 100% of budget → hard-stop (exit 2)
    - 3× baseline spike → alert (warning)
.PARAMETER Command
  "check", "record", or "alert"
.PARAMETER EntryJson
  JSON input for record command.
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("check", "record", "alert")]
    [string]$Command = "check",

    [string]$EntryJson = ""
)

$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) { $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.." }

$TelemetryDir = "$HarnessRoot\.harness\telemetry"
$BudgetFile = "$TelemetryDir\budget-state.json"

# Read budget from project.yaml
function Get-BudgetConfig {
    $ProjectYaml = "$HarnessRoot\contracts\project.yaml"
    if (-not (Test-Path $ProjectYaml)) {
        return @{
            max_tokens_per_session = 500000
            max_cost_per_session_usd = 10.0
            alert_at_percent = 80
        }
    }
    $Content = Get-Content -Path $ProjectYaml -Raw -Encoding utf8
    $MaxTokens = 500000
    $MaxCost = 10.0
    $AlertPct = 80

    if ($Content -match 'max_tokens_per_session:\s*(\d+)') { $MaxTokens = [int]$matches[1] }
    if ($Content -match 'max_cost_per_session_usd:\s*([\d.]+)') { $MaxCost = [double]$matches[1] }
    if ($Content -match 'alert_at_percent:\s*(\d+)') { $AlertPct = [int]$matches[1] }

    return @{
        max_tokens = $MaxTokens
        max_cost = $MaxCost
        alert_at_percent = $AlertPct
    }
}

# Read actuals from telemetry
function Get-Actuals {
    $AgentOpsLog = "$TelemetryDir\agentops.log"
    $SessionId = $env:HARNESS_SESSION_ID

    $TotalTokens = 0
    $TotalCost = 0.0
    $RunCount = 0

    if (Test-Path $AgentOpsLog) {
        $Lines = Get-Content -Path $AgentOpsLog -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' }
        foreach ($line in $Lines) {
            try {
                $r = $line | ConvertFrom-Json
                $TotalTokens += [int]$r.total_tokens
                $TotalCost += [double]$r.estimated_cost_usd
                $RunCount++
            } catch {}
        }
    }

    return @{
        total_tokens = $TotalTokens
        total_cost = [math]::Round($TotalCost, 4)
        run_count = $RunCount
        session_id = $SessionId
    }
}

switch ($Command) {
    "check" {
        $Budget = Get-BudgetConfig
        $Actuals = Get-Actuals

        $TokenPct = if ($Budget.max_tokens -gt 0) { [math]::Round($Actuals.total_tokens / $Budget.max_tokens * 100, 1) } else { 0 }
        $CostPct = if ($Budget.max_cost -gt 0) { [math]::Round($Actuals.total_cost / $Budget.max_cost * 100, 1) } else { 0 }

        $Alerts = @()
        if ($TokenPct -ge 100) { $Alerts += "HARD-STOP: Token budget exhausted ($TokenPct%)" }
        elseif ($TokenPct -ge $Budget.alert_at_percent) { $Alerts += "WARNING: Token budget at $TokenPct%" }

        if ($CostPct -ge 100) { $Alerts += "HARD-STOP: Cost budget exhausted ($CostPct%)" }
        elseif ($CostPct -ge $Budget.alert_at_percent) { $Alerts += "WARNING: Cost budget at $CostPct%" }

        $Result = @{
            budget = $Budget
            actuals = $Actuals
            token_percent = $TokenPct
            cost_percent = $CostPct
            alerts = $Alerts
            timestamp = (Get-Date -Format 'o')
        }

        Write-Output "[budget-meter] Tokens: $($Actuals.total_tokens)/$($Budget.max_tokens) ($TokenPct%)"
        Write-Output "[budget-meter] Cost: `$$($Actuals.total_cost)/`$$($Budget.max_cost) ($CostPct%)"

        foreach ($alert in $Alerts) {
            if ($alert -match "HARD-STOP") {
                Write-Error "[budget-meter] $alert"
            } else {
                Write-Warning "[budget-meter] $alert"
            }
        }

        Write-Output ($Result | ConvertTo-Json -Compress)

        # Exit 2 if hard-stop
        if ($TokenPct -ge 100 -or $CostPct -ge 100) { exit 2 }
        exit 0
    }

    "record" {
        $InputJson = if ($EntryJson) { $EntryJson } else { $input | Out-String }
        if (-not $InputJson -or $InputJson.Trim() -eq "") {
            Write-Error "[budget-meter] No input"
            exit 1
        }

        $Input = $InputJson | ConvertFrom-Json
        $AgentName = if ($Input.agent_name) { $Input.agent_name } else { "unknown" }
        $Tokens = if ($Input.tokens) { [int]$Input.tokens } else { 0 }
        $Cost = if ($Input.cost_usd) { [double]$Input.cost_usd } else { 0.0 }

        # Update budget state
        $State = @{}
        if (Test-Path $BudgetFile) {
            try { $State = Get-Content -Path $BudgetFile -Raw -Encoding utf8 | ConvertFrom-Json } catch {}
        }

        if (-not $State.agents) { $State = @{ agents = @{}; total_tokens = 0; total_cost = 0.0 } }
        if (-not $State.agents.$AgentName) { $State.agents.$AgentName = @{ tokens = 0; cost = 0.0 } }

        $State.total_tokens += $Tokens
        $State.total_cost += $Cost
        $State.agents.$AgentName.tokens += $Tokens
        $State.agents.$AgentName.cost += $Cost
        $State.last_updated = (Get-Date -Format 'o')

        $State | ConvertTo-Json -Depth 10 | Set-Content -Path $BudgetFile -Encoding utf8

        Write-Output "[budget-meter] Recorded: $AgentName +${Tokens}tokens/+`$$Cost"
        break
    }

    "alert" {
        $Budget = Get-BudgetConfig
        $Actuals = Get-Actuals

        $TokenPct = if ($Budget.max_tokens -gt 0) { $Actuals.total_tokens / $Budget.max_tokens } else { 0 }
        $CostPct = if ($Budget.max_cost -gt 0) { $Actuals.total_cost / $Budget.max_cost } else { 0 }

        $AnyAlert = $false

        # Threshold alerts
        if ($TokenPct -ge ($Budget.alert_at_percent / 100.0)) {
            Write-Warning "[budget-meter] ALERT: Token usage at $([math]::Round($TokenPct * 100, 1))% of budget"
            $AnyAlert = $true
        }
        if ($CostPct -ge ($Budget.alert_at_percent / 100.0)) {
            Write-Warning "[budget-meter] ALERT: Cost at $([math]::Round($CostPct * 100, 1))% of budget"
            $AnyAlert = $true
        }

        # Spike detection: compare last run vs average
        $AgentOpsLog = "$TelemetryDir\agentops.log"
        if (Test-Path $AgentOpsLog) {
            $AllRuns = Get-Content -Path $AgentOpsLog -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json }
            if ($AllRuns.Count -ge 3) {
                $LastRun = $AllRuns[$AllRuns.Count - 1]
                $PrevRuns = $AllRuns[0..($AllRuns.Count - 2)]
                $AvgTokens = ($PrevRuns | Measure-Object -Property total_tokens -Average).Average
                if ($AvgTokens -gt 0 -and $LastRun.total_tokens -gt ($AvgTokens * 3)) {
                    Write-Warning "[budget-meter] SPIKE ALERT: $($LastRun.agent_name) used $($LastRun.total_tokens)tokens (3x avg ${AvgTokens}tokens)"
                    $AnyAlert = $true
                }
            }
        }

        if (-not $AnyAlert) {
            Write-Output "[budget-meter] No alerts — within budget thresholds"
        }

        # Hard-stop check
        if ($TokenPct -ge 1.0 -or $CostPct -ge 1.0) {
            Write-Error "[budget-meter] HARD-STOP: Budget exhausted"
            exit 2
        }
        break
    }
}
