#!/usr/bin/env pwsh
<#
.SYNOPSIS
  In KPI don bay: Nen, hieu qua token, so lan nguoi sua AI (F5).

.DESCRIPTION
  Doc .harness/telemetry/human-effort.jsonl (F4), .harness/control/baseline-w0.json
  va daily-*.jsonl, roi tinh theo cong thuc khai trong .harness/control/kpi.yaml.

  Bao cao CO TINH tu choi in so khi do phu baseline thap hon nguong: mot ti so
  tinh tren ba phan tu trong bon muoi khong phai la Nen cua du an, nhung nhin
  thi giong het -- va no se duoc trich dan nhu the.

.USAGE
  .\kpi-report.ps1
  .\kpi-report.ps1 -Since 2026-09-01 -Until 2026-09-30
  .\kpi-report.ps1 -AsJson
#>
param(
    [string]$Since = "",
    [string]$Until = "",
    [switch]$AsJson,
    [string]$HarnessRoot = ""
)

$ErrorActionPreference = "Stop"

if ($HarnessRoot -eq "") {
    $HarnessRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

$lib = Join-Path $PSScriptRoot "..\lib\harness_kpi.py"
if (-not (Test-Path $lib)) { throw "Khong thay harness_kpi.py tai: $lib" }

$py = "python"
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = "python3" }
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) {
    throw "Khong tim thay python tren PATH. Can Python 3 (chi dung thu vien chuan)."
}

$a = @($lib, $HarnessRoot)
if ($Since -ne "") { $a += @("--since", $Since) }
if ($Until -ne "") { $a += @("--until", $Until) }
if ($AsJson)       { $a += "--json" }

& $py @a
if ($LASTEXITCODE -ne 0) {
    throw "kpi-report that bai (exit $LASTEXITCODE)."
}
