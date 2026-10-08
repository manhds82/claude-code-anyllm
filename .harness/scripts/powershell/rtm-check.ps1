#!/usr/bin/env pwsh
<#
.SYNOPSIS
  RTM (F7): story nao trong spec khong co test nao nhac toi?

.DESCRIPTION
  qa-gate cham tren test DA CO, nen mot story khong test nao phu van qua cong
  xanh. Cong khong noi doi -- no chi khong duoc hoi. Script nay hoi cau do.

  Spec lay tu contracts/project.yaml -> domain_refs.srs. Neu duong dan do tro
  toi file khong ton tai, script noi thang -- day dung la bay "installer ghi de
  domain_refs" da ghi trong AVOID.

.USAGE
  .\rtm-check.ps1
  .\rtm-check.ps1 -Spec docs\SRS.md -Tests tests -Tests portal\backend\tests
  .\rtm-check.ps1 -FailOnGap        # exit 1 khi con GAP (dung trong CI)
#>
param(
    [string]$Spec = "",
    [string[]]$Tests = @(),
    [switch]$AsJson,
    [switch]$FailOnGap,
    [string]$HarnessRoot = ""
)

$ErrorActionPreference = "Stop"

if ($HarnessRoot -eq "") {
    $HarnessRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

$lib = Join-Path $PSScriptRoot "..\lib\harness_rtm.py"
if (-not (Test-Path $lib)) { throw "Khong thay harness_rtm.py tai: $lib" }

$py = "python"
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = "python3" }
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) {
    throw "Khong tim thay python tren PATH. Can Python 3 (chi dung thu vien chuan)."
}

$a = @($lib, $HarnessRoot)
if ($Spec -ne "") { $a += @("--spec", $Spec) }
foreach ($t in $Tests) { $a += @("--tests", $t) }
if ($AsJson)    { $a += "--json" }
if ($FailOnGap) { $a += "--fail-on-gap" }

& $py @a
$code = $LASTEXITCODE
# exit 1 o day la KET QUA (con GAP), khong phai loi script -- dung throw.
if ($code -gt 1) { throw "rtm-check that bai (exit $code)." }
exit $code
