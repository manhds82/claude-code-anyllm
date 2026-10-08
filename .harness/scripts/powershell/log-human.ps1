#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Ghi mot khoi cong suc CUA NGUOI vao telemetry (F4).

.DESCRIPTION
  Moi truong telemetry hien co deu do MAY (latency_ms, duration_s, tokens,
  tool_calls). Khong truong nao do nguoi. Khong co so nay thi khong tinh duoc
  don bay -- chi co ve TON, khong co ve DUOC.

  -Minutes la so phut nguoi that su ngoi lam. KHONG BAO GIO suy tu thoi luong
  phien, tu latency_ms hay tu token. Agent co the chay 40 phut trong luc nguoi
  di an trua.

  -Edits dem so lan BAN sua lai thu AI lam ra vi no sai / thieu / lech huong.
  Nhan nguyen output khong tinh la edit. Doi dinh dang khong tinh la edit.
  Mot doan lam viec dai ma edits = 0 la dieu dang xem lai, khong phai dang mung.

.USAGE
  .\log-human.ps1 -Minutes 95 -Edits 6 -Task "F4 telemetry"
  .\log-human.ps1 -Minutes 40 -Edits 0 -Unplanned -Note "doc lai spec"
#>
param(
    [Parameter(Mandatory = $true)][int]$Minutes,
    [Parameter(Mandatory = $true)][int]$Edits,
    [string]$Task = "",
    [string]$SessionId = $env:CLAUDE_SESSION_ID,
    [string]$Date = "",
    [switch]$Rework,
    [switch]$Unplanned,
    [string]$Note = "",
    # F5: id trong .harness/control/baseline-w0.json. Thieu no thi dong nay
    # KHONG duoc tinh vao Nen -- van ghi cong suc, chi la khong co tu so.
    [string]$BaselineRef = "",
    [string]$HarnessRoot = ""
)

$ErrorActionPreference = "Stop"

if ($HarnessRoot -eq "") {
    $HarnessRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

$lib = Join-Path $PSScriptRoot "..\lib\harness_human_log.py"
if (-not (Test-Path $lib)) { throw "Khong thay harness_human_log.py tai: $lib" }

$py = "python"
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = "python3" }
if (-not (Get-Command $py -ErrorAction SilentlyContinue)) {
    throw "Khong tim thay python tren PATH. Can Python 3 (chi dung thu vien chuan)."
}

$a = @($lib, $HarnessRoot, "--minutes", $Minutes, "--edits", $Edits)
if ($Task      -ne "") { $a += @("--task", $Task) }
if ($SessionId -ne "" -and $null -ne $SessionId) { $a += @("--session-id", $SessionId) }
if ($Date      -ne "") { $a += @("--date", $Date) }
if ($Note      -ne "") { $a += @("--note", $Note) }
if ($BaselineRef -ne "") { $a += @("--baseline-ref", $BaselineRef) }
if ($Rework)           { $a += "--rework" }
if ($Unplanned)        { $a += "--unplanned" }

& $py @a
# Loi tra ve chuoi rong khong phai la "khong sao" -- kiem exit code that
# (AVOID/empty-is-not-ok).
if ($LASTEXITCODE -ne 0) {
    throw "Ghi human-effort that bai (exit $LASTEXITCODE). Khong co dong nao duoc ghi."
}
