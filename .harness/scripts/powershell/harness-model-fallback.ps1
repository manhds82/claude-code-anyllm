#!/usr/bin/env pwsh
<#
.SYNOPSIS
  H7 Orchestration — resolve the next model in the fallback ladder (C4).
.DESCRIPTION
  Reads casan-policies orchestration.model_fallback[profile] and returns the
  next model to try. With no -Failed, returns the primary; with -Failed set to
  the model that just errored, returns the following fallback (empty when the
  ladder is exhausted). A workflow/agent calls this to pick a fallback model
  instead of hardcoding it.

  Usage:
    harness-model-fallback.ps1 -Profile coding
    harness-model-fallback.ps1 -Profile coding -Failed claude-sonnet-5-5
.OUTPUTS
  The chosen model id on stdout (empty string if none left).
#>
param(
    [Parameter(Mandatory)][string]$Profile,
    [string]$Failed = "",
    [string]$HarnessRoot = ""
)

if (-not $HarnessRoot) {
    $HarnessRoot = $env:HARNESS_ROOT
    if (-not $HarnessRoot) { $HarnessRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path }
}
$Policy = "$HarnessRoot\.harness\control\casan-policies.yaml"

$py = @'
import os, sys, yaml
pol_path = os.environ["POL"]; profile = os.environ["PROFILE"]; failed = os.environ.get("FAILED", "")
try:
    pol = yaml.safe_load(open(pol_path, encoding="utf-8-sig")) or {}
except Exception:
    print(""); sys.exit(0)
ladder = ((pol.get("orchestration") or {}).get("model_fallback") or {}).get(profile) or []
if not ladder:
    print(""); sys.exit(0)
if not failed:
    print(ladder[0]); sys.exit(0)
if failed in ladder:
    i = ladder.index(failed)
    print(ladder[i + 1] if i + 1 < len(ladder) else "")
else:
    print(ladder[0])
'@

$pyExe = (Get-Command python3 -ErrorAction SilentlyContinue); if (-not $pyExe) { $pyExe = Get-Command python -ErrorAction SilentlyContinue }
if (-not $pyExe) { Write-Warning "[model-fallback] python not found"; exit 0 }
$env:POL = $Policy; $env:PROFILE = $Profile; $env:FAILED = $Failed
$next = ($py | & $pyExe.Source -).Trim()
Write-Output $next
exit 0
