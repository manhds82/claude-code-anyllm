#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Bat / tat cuong che F2 (sensitivity) o hook PreToolUse cho MOT du an.

.DESCRIPTION
  Doi mot co duy nhat: enforce_at_pretooluse trong sensitive-paths.json.
  Khi BAT, hook PreToolUse chan moi lenh GHI vao file khop rule nhay cam
  (migration, SQL, auth, phan quyen, secret, tien) va doi nguoi duyet.

  Ton tai vi mot ly do cu the: lam viec nay bang one-liner rat de hong.
    - `powershell -c "...$p..."` chay TU BEN TRONG mot PowerShell session thi
      shell NGOAI an mat $p va $d truoc khi truyen vao -> lenh toi noi rong ruot.
    - `Set-Content -Encoding utf8` tren PS 5.1 them BOM vao file JSON
      (AVOID/commit-bom). Script nay ghi UTF-8 KHONG BOM.
    - Duong dan tuong doi phu thuoc cwd; script nay nhan -Project tuyet doi.

.USAGE
  .\sensitivity-enforce.ps1 -Project E:\SourceCode\<TenDuAn> -Status
  .\sensitivity-enforce.ps1 -Project E:\SourceCode\<TenDuAn> -On
  .\sensitivity-enforce.ps1 -Project E:\SourceCode\<TenDuAn> -Off
#>
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [switch]$On,
    [switch]$Off,
    [switch]$Status
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$Cfg = Join-Path $Project ".harness\control\sensitive-paths.json"

if (-not (Test-Path $Project)) { throw "Khong thay thu muc du an: $Project" }
if (-not (Test-Path $Cfg)) {
    Write-Host "Du an nay CHUA co $Cfg" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Nghia la harness chua duoc cai, hoac bundle cai vao con cu hon F2." -ForegroundColor Yellow
    Write-Host "Cai bundle truoc:" -ForegroundColor Yellow
    Write-Host "  powershell -File E:\SourceCode\HarnessAI-ToolKIT\tools\harness-bundle\install.ps1 ``"
    Write-Host "    -TargetDir `"$Project`" -MergeGuides"
    Write-Host ""
    Write-Host "Luu y: bundle moi nhat (1.7.1) co TRUOC F2, nen cai xong van chua co" -ForegroundColor Yellow
    Write-Host "file nay. Phai dong goi bundle moi truoc." -ForegroundColor Yellow
    exit 1
}

$json = [System.IO.File]::ReadAllText($Cfg)
try { $d = $json | ConvertFrom-Json } catch { throw "sensitive-paths.json khong phai JSON hop le: $Cfg" }

$cur = [bool]$d.enforce_at_pretooluse

if ($Status -or (-not $On -and -not $Off)) {
    Write-Host ""
    Write-Host "  Du an   : $Project"
    Write-Host "  Cuong che F2 o PreToolUse : " -NoNewline
    if ($cur) { Write-Host "BAT" -ForegroundColor Red } else { Write-Host "TAT" -ForegroundColor Green }
    Write-Host "  So rule : $($d.rules.Count)"
    Write-Host ""
    Write-Host "  Xem truoc file nao se bi chan:"
    Write-Host "    python E:\SourceCode\HarnessAI-ToolKIT\.harness\scripts\lib\harness_sensitivity.py `"$Project`" --scan"
    Write-Host ""
    exit 0
}

$new = if ($On) { $true } else { $false }
if ($new -eq $cur) {
    Write-Host "Da o trang thai do roi (enforce_at_pretooluse = $cur). Khong doi gi." -ForegroundColor DarkGray
    exit 0
}

# Sua DONG chua co, khong serialize lai ca file: ConvertTo-Json sap xep lai
# thu tu khoa, bo comment JSON-style va doi indent, khien diff cua mot thay doi
# mot-bit tro thanh diff toan file.
$pattern = '("enforce_at_pretooluse"\s*:\s*)(true|false)'
if ($json -notmatch $pattern) { throw "Khong tim thay khoa enforce_at_pretooluse trong $Cfg" }
$out = [regex]::Replace($json, $pattern, ('${1}' + $new.ToString().ToLower()), 1)

[System.IO.File]::WriteAllText($Cfg, $out, $Utf8NoBom)

# Doc lai va kiem: mot file config hong vi chinh script bat cong la kieu that bai
# te nhat - cong trong nhu dang chay ma thuc te hook fail-open cho qua tat ca.
$check = ([System.IO.File]::ReadAllText($Cfg) | ConvertFrom-Json)
if ([bool]$check.enforce_at_pretooluse -ne $new) { throw "Ghi xong nhung doc lai khong khop. Kiem tay: $Cfg" }

Write-Host ""
if ($new) {
    Write-Host "  BAT cuong che F2 cho $Project" -ForegroundColor Red
    Write-Host "  Tu gio moi lenh GHI vao file nhay cam se bi chan, doi nguoi duyet."
    Write-Host "  Xem truoc pham vi: harness_sensitivity.py `"$Project`" --scan"
} else {
    Write-Host "  TAT cuong che F2 cho $Project" -ForegroundColor Green
    Write-Host "  gatekeeper van doc rule de nang bac rui ro (advisory), nhung hook khong chan."
}
Write-Host ""
