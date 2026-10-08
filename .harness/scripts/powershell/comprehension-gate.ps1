#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Cong hieu (F6) -- cong duy nhat may khong dung thay nguoi duoc.

.DESCRIPTION
  Moi cong hien co deu do may hoac AI cham: gatekeeper, qa-gate, judge
  min_overall_score. Voi 15 agent + max_fix_retries 5, he nay co the sinh ra mot
  thay doi duoc duyet, test xanh, deploy xong ma nguoi khong he hieu -- va no se
  sach se theo moi policy. Rubber-stamp va hieu that phat ra CUNG mot artefact:
  mot chu "approve". Khong gi tu dong phan biet duoc, vi khac biet khong nam o
  dau ra.

  Ship TAT (enabled=false) va CHUA WIRE vao dau ca. Wire cung luc voi quyet dinh
  B0 (approval-gate / domain-firewall).

.USAGE
  .\comprehension-gate.ps1 -Check
  .\comprehension-gate.ps1 -Tier high -Ref chg-12 `
      -Restate "..." -AiError "..."
#>
param(
    [switch]$Check,
    [string]$Tier = "",
    [string]$Restate = "",
    [string]$AiError = "",
    [string]$Ref = "",
    [string]$HarnessRoot = ""
)

$ErrorActionPreference = "Stop"

if ($HarnessRoot -eq "") {
    $HarnessRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

$lib = Join-Path $PSScriptRoot "..\lib\harness_comprehension.py"
if (-not (Test-Path $lib)) { throw "Khong thay harness_comprehension.py tai: $lib" }

$py = "python"
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = "python3" }
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) {
    throw "Khong tim thay python tren PATH. Can Python 3 (chi dung thu vien chuan)."
}

$a = @($lib, $HarnessRoot)
if ($Check)          { $a += "--check" }
if ($Tier    -ne "") { $a += @("--tier", $Tier) }
if ($Restate -ne "") { $a += @("--restate", $Restate) }
if ($AiError -ne "") { $a += @("--ai-error", $AiError) }
if ($Ref     -ne "") { $a += @("--ref", $Ref) }

& $py @a
$code = $LASTEXITCODE
# exit 1 la KET QUA (chua qua cong), khong phai loi script -- dung throw.
if ($code -gt 1) { throw "comprehension-gate that bai (exit $code)." }
exit $code
