<#
================================================================
  open-with-claude.ps1  — per-project Claude Code launcher
  Drop this file into any project folder.

  Usage:
    .\open-with-claude.ps1                  # interactive provider menu
    .\open-with-claude.ps1 -Provider fpt    # skip the menu
    .\open-with-claude.ps1 -Provider nvidia -Key "nvapi-..."

  All flags are forwarded to start-claude.ps1.
  Edit $ClaudeSetup below to point at your claude-code-anyllm folder.
================================================================
#>

# ---- EDIT THIS: path to your claude-code-anyllm installation ----
$ClaudeSetup = Join-Path $env:USERPROFILE "claude-code-anyllm"
# -----------------------------------------------------------------

$launcher = Join-Path $ClaudeSetup "start-claude.ps1"
if (-not (Test-Path $launcher)) {
    Write-Host "[X] start-claude.ps1 not found at: $ClaudeSetup" -ForegroundColor Red
    Write-Host "    Edit the `$ClaudeSetup variable in this file to point at your claude-code-anyllm folder." -ForegroundColor Yellow
    exit 1
}

& $launcher -OpenDir $PSScriptRoot @args
