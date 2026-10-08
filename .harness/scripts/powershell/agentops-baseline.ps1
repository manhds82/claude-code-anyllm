#!/usr/bin/env pwsh
<#
.SYNOPSIS
  AgentOps Baseline (H6) — computes baseline metrics from historical telemetry.
.DESCRIPTION
  Reads agentops.log and computes per-agent baselines:
    - Average tokens per run
    - Average cost per run
    - Average latency per run
    - P50/P95/P99 latencies
  Writes baseline to .harness/telemetry/baseline.json

  Run periodically (e.g. daily via cron) to update baselines.
#>

$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) { $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.." }

$LogFile = "$HarnessRoot\.harness\telemetry\agentops.log"
$BaselineFile = "$HarnessRoot\.harness\telemetry\baseline.json"

if (-not (Test-Path $LogFile)) {
    Write-Output "[agentops-baseline] No telemetry data found at $LogFile"
    exit 0
}

$Records = Get-Content -Path $LogFile -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json }

if ($Records.Count -eq 0) {
    Write-Output "[agentops-baseline] No records to analyze"
    exit 0
}

# Group by agent
$AgentGroups = $Records | Group-Object -Property agent_name

$Baseline = @{
    computed_at = (Get-Date -Format 'o')
    total_runs = $Records.Count
    total_tokens = ($Records | Measure-Object -Property total_tokens -Sum).Sum
    total_cost = [math]::Round(($Records | Measure-Object -Property estimated_cost_usd -Sum).Sum, 4)
    agents = @{}
}

foreach ($group in $AgentGroups) {
    $AgentName = $group.Name
    $AgentRecords = $group.Group

    $TokensValues = $AgentRecords | ForEach-Object { $_.total_tokens }
    $CostValues = $AgentRecords | ForEach-Object { $_.estimated_cost_usd }
    $LatencyValues = $AgentRecords | ForEach-Object { $_.latency_ms }
    $SortedLatency = $LatencyValues | Sort-Object

    $P50 = if ($SortedLatency.Count -gt 0) { $SortedLatency[[math]::Floor($SortedLatency.Count * 0.5)] } else { 0 }
    $P95 = if ($SortedLatency.Count -gt 0) { $SortedLatency[[math]::Floor($SortedLatency.Count * 0.95)] } else { 0 }
    $P99 = if ($SortedLatency.Count -gt 0) { $SortedLatency[[math]::Floor($SortedLatency.Count * 0.99)] } else { 0 }

    $Baseline.agents[$AgentName] = @{
        runs = $AgentRecords.Count
        avg_tokens = [math]::Round(($TokensValues | Measure-Object -Average).Average, 0)
        avg_cost_usd = [math]::Round(($CostValues | Measure-Object -Average).Average, 6)
        avg_latency_ms = [math]::Round(($LatencyValues | Measure-Object -Average).Average, 0)
        p50_latency_ms = $P50
        p95_latency_ms = $P95
        p99_latency_ms = $P99
        min_tokens = ($TokensValues | Measure-Object -Minimum).Minimum
        max_tokens = ($TokensValues | Measure-Object -Maximum).Maximum
    }
}

$Baseline | ConvertTo-Json -Depth 10 | Set-Content -Path $BaselineFile -Encoding utf8

Write-Output "[agentops-baseline] Baseline computed: $($Records.Count) runs across $($AgentGroups.Count) agents"
Write-Output "[agentops-baseline] Total tokens: $($Baseline.total_tokens) | Total cost: $$($Baseline.total_cost)"
Write-Output "[agentops-baseline] Saved to $BaselineFile"
