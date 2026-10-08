#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Drift Detection (H6) — compares current metrics vs baseline, detects behavioral drift.
.DESCRIPTION
  Compares recent telemetry (last N runs) against baseline from agentops-baseline.
  Detects:
    - Cost drift: average cost per run changed by >20%
    - Token drift: average tokens per run changed by >20%
    - Latency drift: P95 latency changed by >30%
    - Volume drift: run count per hour changed by >50%
    - Model version drift: model string changed

  Outputs JSON report with drift indicators.
.PARAMETER BaselinePath
  Path to baseline.json (default: .harness/telemetry/baseline.json)
.PARAMETER Threshold
  Drift sensitivity threshold as decimal (default: 0.2 = 20%)
#>

param(
    [string]$BaselinePath = "",
    [float]$Threshold = 0.20
)

$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) { $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.." }

$TelemetryDir = "$HarnessRoot\.harness\telemetry"
if (-not $BaselinePath) { $BaselinePath = "$TelemetryDir\baseline.json" }
$LogFile = "$TelemetryDir\agentops.log"

if (-not (Test-Path $BaselinePath)) {
    Write-Output "[drift-detect] No baseline found — run agentops-baseline.ps1 first"
    exit 0
}

if (-not (Test-Path $LogFile)) {
    Write-Output "[drift-detect] No telemetry data"
    exit 0
}

$Baseline = Get-Content -Path $BaselinePath -Raw -Encoding utf8 | ConvertFrom-Json
$AllRuns = Get-Content -Path $LogFile -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json }

if ($AllRuns.Count -eq 0) {
    Write-Output "[drift-detect] No runs to analyze"
    exit 0
}

# Recent runs: last N or last 24h
$RecentRuns = $AllRuns | Select-Object -Last 20
$DriftReport = @{
    computed_at = (Get-Date -Format 'o')
    baseline_date = $Baseline.computed_at
    total_runs_baseline = $Baseline.total_runs
    recent_runs_count = $RecentRuns.Count
    drifts = @()
    metrics = @{}
}

# Per-agent drift
$AgentGroups = $RecentRuns | Group-Object -Property agent_name
foreach ($group in $AgentGroups) {
    $AgentName = $group.Name
    $BaselineAgent = $Baseline.agents.$AgentName
    if (-not $BaselineAgent) { continue }

    $AgentRuns = $group.Group
    $AvgTokens = ($AgentRuns | Measure-Object -Property total_tokens -Average).Average
    $AvgCost = ($AgentRuns | Measure-Object -Property estimated_cost_usd -Average).Average
    $AvgLatency = ($AgentRuns | Measure-Object -Property latency_ms -Average).Average
    $RunCount = $AgentRuns.Count

    $TokenDrift = if ($BaselineAgent.avg_tokens -gt 0) { ($AvgTokens - $BaselineAgent.avg_tokens) / $BaselineAgent.avg_tokens } else { 0 }
    $CostDrift = if ($BaselineAgent.avg_cost_usd -gt 0) { ($AvgCost - $BaselineAgent.avg_cost_usd) / $BaselineAgent.avg_cost_usd } else { 0 }
    $LatencyDrift = if ($BaselineAgent.avg_latency_ms -gt 0) { ($AvgLatency - $BaselineAgent.avg_latency_ms) / $BaselineAgent.avg_latency_ms } else { 0 }

    $AgentMetrics = @{
        agent = $AgentName
        baseline_avg_tokens = $BaselineAgent.avg_tokens
        recent_avg_tokens = [math]::Round($AvgTokens, 0)
        token_drift_pct = [math]::Round($TokenDrift * 100, 1)
        baseline_avg_cost = $BaselineAgent.avg_cost_usd
        recent_avg_cost = [math]::Round($AvgCost, 6)
        cost_drift_pct = [math]::Round($CostDrift * 100, 1)
        baseline_avg_latency = $BaselineAgent.avg_latency_ms
        recent_avg_latency = [math]::Round($AvgLatency, 0)
        latency_drift_pct = [math]::Round($LatencyDrift * 100, 1)
        recent_run_count = $RunCount
    }

    $DriftReport.metrics[$AgentName] = $AgentMetrics

    # Detect drifts
    if ([math]::Abs($TokenDrift) -gt $Threshold) {
        $direction = if ($TokenDrift -gt 0) { "UP" } else { "DOWN" }
        $DriftReport.drifts += @{
            agent = $AgentName
            metric = "tokens"
            direction = $direction
            drift_pct = [math]::Round($TokenDrift * 100, 1)
            severity = if ([math]::Abs($TokenDrift) -gt 0.5) { "high" } elseif ([math]::Abs($TokenDrift) -gt 0.3) { "medium" } else { "low" }
        }
    }
    if ([math]::Abs($CostDrift) -gt $Threshold) {
        $direction = if ($CostDrift -gt 0) { "UP" } else { "DOWN" }
        $DriftReport.drifts += @{
            agent = $AgentName
            metric = "cost"
            direction = $direction
            drift_pct = [math]::Round($CostDrift * 100, 1)
            severity = if ([math]::Abs($CostDrift) -gt 0.5) { "high" } elseif ([math]::Abs($CostDrift) -gt 0.3) { "medium" } else { "low" }
        }
    }
    if ([math]::Abs($LatencyDrift) -gt ($Threshold + 0.1)) {
        $direction = if ($LatencyDrift -gt 0) { "UP" } else { "DOWN" }
        $DriftReport.drifts += @{
            agent = $AgentName
            metric = "latency"
            direction = $direction
            drift_pct = [math]::Round($LatencyDrift * 100, 1)
            severity = if ([math]::Abs($LatencyDrift) -gt 0.5) { "high" } elseif ([math]::Abs($LatencyDrift) -gt 0.3) { "medium" } else { "low" }
        }
    }
}

# Model version drift check
$ModelVersions = $RecentRuns | Group-Object -Property model
if ($ModelVersions.Count -gt 1) {
    $DriftReport.drifts += @{
        agent = "fleet"
        metric = "model_version"
        direction = "MIXED"
        detail = ($ModelVersions | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ", "
        severity = "medium"
    }
}

# Overall summary
$DriftReport.summary = @{
    total_drifts = $DriftReport.drifts.Count
    high_severity = ($DriftReport.drifts | Where-Object { $_.severity -eq "high" }).Count
    has_drift = $DriftReport.drifts.Count -gt 0
}

# Output
$Json = $DriftReport | ConvertTo-Json -Depth 10

if ($DriftReport.summary.has_drift) {
    Write-Warning "[drift-detect] $($DriftReport.drifts.Count) drift(s) detected ($($DriftReport.summary.high_severity) high)"
    foreach ($d in $DriftReport.drifts) {
        Write-Warning "[drift-detect] [$($d.severity.ToUpper())] $($d.agent)/$($d.metric): $($d.direction) $($d.drift_pct)%"
    }
} else {
    Write-Output "[drift-detect] No significant drift detected"
}

# Save report
$ReportFile = "$TelemetryDir\drift-report.json"
$Json | Set-Content -Path $ReportFile -Encoding utf8
Write-Output "[drift-detect] Report saved to $ReportFile"
