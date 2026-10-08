#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Secret scanner — detects API keys, DB passwords, tokens in text input.
  Designed to run as a PreToolUse hook or standalone scanner.
.DESCRIPTION
  Reads content from stdin or a file path argument.
  Scans for patterns matching common secret formats.
  Returns exit code:
    0 — no secrets found
    1 — low/medium severity found (warning)
    2 — high/critical severity found (hard stop)
.PARAMETER Path
  Optional: scan a specific file instead of stdin.
.PARAMETER Stdin
  Scan text piped via stdin (default).
.NOTES
  C5: Never hardcode secrets — this scanner detects them.
  Part of Harness H4 Security layer. Defense-in-depth.
#>

param(
    [string]$Path = "",
    [switch]$Stdin = $false
)

# --- Load deny patterns from config (C2) ---
$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) {
    $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.."
}

$SecretPatternsPath = "$HarnessRoot\.harness\control\secret-patterns.json"
if (-not (Test-Path $SecretPatternsPath)) {
    # Use built-in defaults if no config exists
    $SecretPatterns = @(
        @{ pattern = '(?i)(?:api[_-]?key|apikey)\s*[:=]\s*["'']?[A-Za-z0-9_\-]{16,}["'']?'; severity = 'high'; name = 'API Key' },
        @{ pattern = '(?i)(?:sk-[A-Za-z0-9]{32,}|sk-[A-Za-z0-9]{16,})'; severity = 'critical'; name = 'OpenAI/SDK Secret Key' },
        @{ pattern = '(?i)AKIA[0-9A-Z]{16}'; severity = 'critical'; name = 'AWS Access Key ID' },
        @{ pattern = '(?i)(?:password|pwd|passwd)\s*[:=]\s*["'']?.{8,}["'']?'; severity = 'high'; name = 'Password' },
        @{ pattern = '(?i)(?:connection[_-]?string|conn[_-]?str)\s*[:=]\s*["'']?.+["'']?'; severity = 'high'; name = 'Connection String' },
        @{ pattern = '(?i)gh[pousr]_[A-Za-z0-9_]{12,}'; severity = 'critical'; name = 'GitHub Token' },
        @{ pattern = '(?i)-----BEGIN (?:RSA |EC )?PRIVATE KEY-----'; severity = 'critical'; name = 'Private Key' },
        @{ pattern = '(?i)(?:jwt|bearer)\s+[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}'; severity = 'critical'; name = 'JWT/Bearer Token' },
        @{ pattern = '(?i)mongodb(?:\+srv)?://[^/\s]+:[^@\s]+@'; severity = 'critical'; name = 'MongoDB Connection String' },
        @{ pattern = '(?i)postgresql?://[^:]+:[^@]+@'; severity = 'critical'; name = 'PostgreSQL Connection String' },
        @{ pattern = '(?i)redis://[^:]+:[^@]+@'; severity = 'critical'; name = 'Redis Connection String' },
        @{ pattern = '(?i)-----BEGIN CERTIFICATE-----'; severity = 'medium'; name = 'Certificate' }
    )
} else {
    try {
        $SecretPatterns = Get-Content -Path $SecretPatternsPath -Raw -Encoding utf8 | ConvertFrom-Json
        # CRIT-1: $SecretPatterns is { $schema, description, patterns: [...] } — iterate .patterns
        $SecretPatterns = @($SecretPatterns.patterns)
    } catch {
        Write-Warning "[secret-scan] Cannot read secret-patterns.json, using defaults"
        $SecretPatterns = @()
    }
}

# --- Read input ---
$Content = ""
if ($Path -and (Test-Path $Path)) {
    $Content = Get-Content -Path $Path -Raw -Encoding utf8 -ErrorAction SilentlyContinue
} elseif ($Stdin -or (-not $Path)) {
    $Content = $input | Out-String
}

if (-not $Content) {
    exit 0
}

# --- Scan ---
$Findings = @()
foreach ($entry in $SecretPatterns) {
    if ($null -eq $entry.pattern) { continue }
    $matches = [regex]::Matches($Content, $entry.pattern)
    foreach ($match in $matches) {
        # Mask the actual secret in output
        $masked = if ($match.Value.Length -gt 8) {
            $match.Value.Substring(0, 4) + "..." + $match.Value.Substring($match.Value.Length - 4)
        } else {
            "****"
        }
        $Findings += [PSCustomObject]@{
            Severity  = $entry.severity
            Name      = $entry.name
            Match     = $masked
            Line      = if ($match.Line) { $match.Line } else { "unknown" }
            Position  = if ($match.Index) { $match.Index } else { 0 }
        }
    }
}

# --- Report ---
$Findings = @($Findings)
if ($Findings.Count -eq 0) {
    exit 0
}

$HighCount = @($Findings | Where-Object { $_.Severity -eq 'high' -or $_.Severity -eq 'critical' }).Count
$TotalCount = $Findings.Count

# Persist authoritative security events (H4) -- see lib-security-log.ps1.
$LibPath = Join-Path $PSScriptRoot "lib-security-log.ps1"
if (Test-Path $LibPath) {
    . $LibPath
    foreach ($f in $Findings) {
        Write-SecurityEvent -HarnessRoot $HarnessRoot -Type "secret" -Severity $f.Severity `
            -Category $f.Name -DetectedBy "secret-scan" -Excerpt $f.Match
    }
}

Write-Warning "[secret-scan] Found $TotalCount potential secret(s) ($HighCount high/critical)"
foreach ($f in $Findings) {
    if ($null -eq $f.Severity) { continue }
    Write-Warning "[secret-scan] [$($f.Severity.ToUpper())] $($f.Name): $($f.Match)"
}

# Output JSON for hook integration
$Report = @{
    scanner = "secret-scan"
    total = $TotalCount
    high_critical = $HighCount
    findings = $Findings
} | ConvertTo-Json -Compress
Write-Output $Report

if ($HighCount -gt 0) {
    # Hard stop for high/critical severity
    exit 2
}

exit 1
