#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Hard Gate (H3) - evaluates judge verdict and decides pipeline continuation.
.DESCRIPTION
  Reads judge verdict JSON from stdin, applies rubric scoring rules.
  Returns:
    exit 0 - APPROVED, continue pipeline
    exit 1 - CHANGES_REQUIRED, back to implementation
    exit 2 - REJECTED, hard stop (requires human intervention)
.PARAMETER JudgeVerdictPath
  Path to a JSON file containing the judge verdict.
.PARAMETER RetryCount
  Current retry cycle count (from pipeline context).
.PARAMETER MaxRetries
  Maximum allowed retry cycles (default: 3 from workflow.yaml).
#>

param(
    [string]$JudgeVerdictPath = "",
    [int]$RetryCount = 0,
    [int]$MaxRetries = 3
)

# Read verdict
$VerdictJson = ""
if ($JudgeVerdictPath -and (Test-Path $JudgeVerdictPath)) {
    $VerdictJson = Get-Content -Path $JudgeVerdictPath -Raw -Encoding utf8
} else {
    $VerdictJson = $input | Out-String
}

if (-not $VerdictJson) {
    Write-Error "[hard-gate] No verdict provided"
    exit 2
}

try {
    $Verdict = $VerdictJson | ConvertFrom-Json
} catch {
    Write-Error "[hard-gate] Invalid verdict JSON: $_"
    exit 2
}

$Score = $Verdict.score
$VerdictText = $Verdict.verdict  # APPROVED / CHANGES_REQUIRED / REJECTED
$Feedback = $Verdict.feedback

# --- H3 depth: ENFORCE the rubric rule, do not merely trust the judge's label ---
# Contract (see .claude/skills/verify-implementation/SKILL.md):
#   APPROVED requires overall >= 80 AND every rubric dimension >= 60
#   overall < 60 is REJECTED regardless of the label
# The judge supplies data; this gate decides. No rubric present = label used as-is.
$MinOverallApprove = 80
$MinDimension      = 60
$RejectBelow       = 60

$LowDims = @()
$DimValues = @()
if ($null -ne $Verdict.rubric_scores) {
    foreach ($p in $Verdict.rubric_scores.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
            $DimValues += [double]$v
            if ([double]$v -lt $MinDimension) { $LowDims += ("{0}={1}" -f $p.Name, $v) }
        }
    }
}

# Overall = explicit score when given, else the average of the rubric dimensions.
$Overall = $null
if ($null -ne $Score -and "$Score" -ne "") {
    $Overall = [double]$Score
} elseif ($DimValues.Count -gt 0) {
    $Overall = [math]::Round((($DimValues | Measure-Object -Average).Average), 1)
}

$RubricNote = "no rubric"
if ($DimValues.Count -gt 0) { $RubricNote = "$($DimValues.Count) dims" }

Write-Output "[hard-gate] Score: $Overall/100 | Verdict: $VerdictText | Rubric: $RubricNote | Retry: $RetryCount/$MaxRetries"

if ($null -ne $Overall -and $Overall -lt $RejectBelow) {
    if ($VerdictText -ne "REJECTED") {
        Write-Output "[hard-gate] OVERRIDE -> REJECTED (overall $Overall < $RejectBelow)"
    }
    $VerdictText = "REJECTED"
} elseif ($VerdictText -eq "APPROVED") {
    if ($null -ne $Overall -and $Overall -lt $MinOverallApprove) {
        Write-Output "[hard-gate] OVERRIDE -> CHANGES_REQUIRED (overall $Overall < $MinOverallApprove)"
        $VerdictText = "CHANGES_REQUIRED"
    } elseif ($LowDims.Count -gt 0) {
        Write-Output "[hard-gate] OVERRIDE -> CHANGES_REQUIRED (dimension below $MinDimension : $($LowDims -join ', '))"
        $VerdictText = "CHANGES_REQUIRED"
    }
}

switch ($VerdictText) {
    "APPROVED" {
        Write-Output "[hard-gate] GATE PASSED - pipeline continues"
        exit 0
    }
    "CHANGES_REQUIRED" {
        if ($RetryCount -ge $MaxRetries) {
            Write-Error "[hard-gate] GATE HALTED - max retries ($MaxRetries) exceeded. Human intervention required."
            exit 2
        }
        Write-Output "[hard-gate] GATE FEEDBACK - back to implementation (cycle $RetryCount/$MaxRetries)"
        exit 1
    }
    "REJECTED" {
        Write-Error "[hard-gate] GATE REJECTED - hard stop. Human intervention required."
        exit 2
    }
    default {
        Write-Error "[hard-gate] Unknown verdict: $VerdictText"
        exit 2
    }
}
