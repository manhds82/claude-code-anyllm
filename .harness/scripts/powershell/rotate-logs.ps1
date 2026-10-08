# D9: size-based rotation for the security-events telemetry log so it can't
# grow without bound on a long-lived checkout. When the JSONL exceeds
# -MaxSizeMB, it is gzip-archived with a timestamp and a fresh empty file is
# started; the newest -Retain archives are kept.
#
# SCOPE: this rotates ONLY .harness/telemetry/security-events.jsonl. It does
# NOT touch .harness/ledger/chain.jsonl -- that file is an append-only SHA-256
# hash chain whose verification walks every line from genesis, so truncating it
# would break tamper-evidence. Archive the ledger with a sealed checkpoint
# instead (see docs/portal-spec.md), not with this script.
#
# PS 5.1 safe: ASCII-only source, UTF-8-no-BOM writes, absolute paths (C7).
param(
    [string]$HarnessRoot = $env:HARNESS_ROOT,
    [int]$MaxSizeMB = 50,
    [int]$Retain = 10
)

$ErrorActionPreference = "Stop"

if (-not $HarnessRoot) {
    # Default: repo root = two levels up from this script's dir.
    $HarnessRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
}

$log = Join-Path $HarnessRoot ".harness\telemetry\security-events.jsonl"
if (-not (Test-Path $log)) {
    Write-Host "[rotate] no log at $log (nothing to do)"
    exit 0
}

$sizeMB = ((Get-Item $log).Length) / 1MB
if ($sizeMB -lt $MaxSizeMB) {
    Write-Host ("[rotate] {0:N1} MB < {1} MB threshold, skip" -f $sizeMB, $MaxSizeMB)
    exit 0
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$archive = Join-Path (Split-Path $log) ("security-events-$stamp.jsonl.gz")

# gzip the current log via .NET (no external gzip on Windows).
$in = [System.IO.File]::OpenRead($log)
try {
    $out = [System.IO.File]::Create($archive)
    try {
        $gz = New-Object System.IO.Compression.GzipStream($out, [System.IO.Compression.CompressionMode]::Compress)
        try { $in.CopyTo($gz) } finally { $gz.Dispose() }
    } finally { $out.Dispose() }
} finally { $in.Dispose() }

# Truncate the live log to empty (UTF-8 no BOM), preserving the same inode/path
# so appenders keep writing to it.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($log, "", $utf8NoBom)
Write-Host "[rotate] archived -> $archive and truncated live log"

# Retention: keep newest $Retain archives.
$archives = Get-ChildItem (Split-Path $log) -Filter "security-events-*.jsonl.gz" |
    Sort-Object LastWriteTime -Descending
if ($archives.Count -gt $Retain) {
    $archives | Select-Object -Skip $Retain | ForEach-Object {
        Write-Host "[rotate] prune $($_.Name)"
        Remove-Item $_.FullName -Force
    }
}
Write-Host "[rotate] done (retain=$Retain)"
