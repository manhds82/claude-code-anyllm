# Shared helper (dot-sourced by the H4 guard scripts) that appends a
# structured security event to .harness/telemetry/security-events.jsonl.
# Closes the gap where guard scripts only Write-Warning'd to the console, so
# the Portal had to *infer* security incidents from ledger denies (approximation).
# Now they persist their own authoritative log the Portal ingests directly.
#
# CONTRACT: this function must NEVER throw and NEVER write to stdout -- hooks
# read stdout for their JSON decision, and a logging failure must not change a
# block/allow verdict (C10: logging is evidence, not enforcement).

function Write-SecurityEvent {
    param(
        [string]$HarnessRoot,
        [string]$Type,        # injection | secret | guard_block
        [string]$Severity,    # low | medium | high | critical
        [string]$Category,
        [string]$DetectedBy,  # script name
        [string]$Excerpt      # already-redacted / truncated
    )
    try {
        if (-not $HarnessRoot) { return }
        $dir = Join-Path $HarnessRoot ".harness\telemetry"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir "security-events.jsonl"

        $event = [ordered]@{
            event_id    = [guid]::NewGuid().ToString()
            timestamp   = (Get-Date -Format 'o')
            type        = $Type
            severity    = $Severity
            category    = $Category
            detected_by = $DetectedBy
            excerpt     = $Excerpt
            session_id  = $env:HARNESS_SESSION_ID
            actor_user  = $env:HARNESS_USER
        }
        $line = ($event | ConvertTo-Json -Compress)

        # UTF-8 no BOM append (PS 5.1's -Encoding utf8 emits a BOM per line).
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($file, $line + "`n", $utf8NoBom)
    } catch {
        # Swallow — a logging failure must never affect the guard's verdict.
    }
}
