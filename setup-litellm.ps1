<#
================================================================
  setup-litellm.ps1  (claude-code-anyllm)
  Install the LiteLLM proxy environment -- RUN THIS ONCE.

  Replaces these 3 manual, error-prone commands:
      py -3.12 -m venv ...
      ...\Activate.ps1
      pip install "litellm[proxy]"

  USAGE:
      .\setup-litellm.ps1                # create .venv inside the project (recommended)
      .\setup-litellm.ps1 -Force         # delete the old venv and reinstall from scratch
      .\setup-litellm.ps1 -VenvPath C:\path\to\venv   # use a different location
      .\setup-litellm.ps1 -PyVersion 3.11             # force a different Python

  When done: run  .\start-claude.ps1  to start the proxy + open VS Code.
================================================================
#>

param(
    [string]$VenvPath  = "",        # empty = .venv inside this script's folder
    [string]$PyVersion = "3.12",    # preferred Python version (via the 'py' launcher)
    [switch]$Force                  # delete the old venv, then reinstall
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    [!] $msg"  -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    [X] $msg"  -ForegroundColor Red }

# ---------- 0. Resolve paths ----------
if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

if ([string]::IsNullOrWhiteSpace($VenvPath)) {
    $VenvPath = Join-Path $ScriptDir ".venv"
}
$LitellmExe = Join-Path $VenvPath "Scripts\litellm.exe"

Write-Step "Installing LiteLLM into: $VenvPath"

# ---------- 1. Already installed? ----------
if ((Test-Path $LitellmExe) -and (-not $Force)) {
    Write-Ok "LiteLLM is already present at $LitellmExe"
    Write-Host "    To reinstall from scratch: .\setup-litellm.ps1 -Force" -ForegroundColor Yellow
    Write-Host "`n    Next step: .\start-claude.ps1" -ForegroundColor Cyan
    return
}

# ---------- 2. Find Python ----------
Write-Step "Looking for Python ..."
$pyCmd  = $null
$pyArgs = @()

# Prefer the 'py' launcher with the requested version
if (Get-Command py -ErrorAction SilentlyContinue) {
    try {
        & py "-$PyVersion" --version *> $null
        if ($LASTEXITCODE -eq 0) { $pyCmd = "py"; $pyArgs = @("-$PyVersion") }
    } catch { }
    if (-not $pyCmd) {
        # 'py' exists but not that version -> use py's default
        $pyCmd = "py"; $pyArgs = @("-3")
        Write-Warn2 "Python $PyVersion not found, using py's default Python."
    }
}
# Fallback: 'python' on PATH
if (-not $pyCmd -and (Get-Command python -ErrorAction SilentlyContinue)) {
    $pyCmd = "python"; $pyArgs = @()
}
if (-not $pyCmd) {
    Write-Err2 "Python not found. Install Python 3.11/3.12 from https://www.python.org/downloads/ (tick 'Add to PATH')."
    return
}
$verShown = (& $pyCmd @pyArgs --version) 2>&1
Write-Ok "Using: $pyCmd $($pyArgs -join ' ')  ($verShown)"

# ---------- 3. Remove old venv if -Force ----------
if ($Force -and (Test-Path $VenvPath)) {
    Write-Step "Removing the old venv (-Force) ..."
    Remove-Item -Recurse -Force $VenvPath
    Write-Ok "Removed $VenvPath"
}

# ---------- 4. Create the venv ----------
if (-not (Test-Path (Join-Path $VenvPath "Scripts\python.exe"))) {
    Write-Step "Creating the virtual env ..."
    & $pyCmd @pyArgs -m venv $VenvPath
    if ($LASTEXITCODE -ne 0) { Write-Err2 "Failed to create the venv."; return }
    Write-Ok "Created venv: $VenvPath"
} else {
    Write-Ok "Venv already exists, just installing/updating packages."
}

$VenvPy = Join-Path $VenvPath "Scripts\python.exe"

# ---------- 5. Upgrade pip + install litellm[proxy] ----------
Write-Step "Upgrading pip ..."
& $VenvPy -m pip install --upgrade pip *> $null
Write-Ok "pip is up to date."

Write-Step "Installing litellm[proxy] (this can take a few minutes) ..."
& $VenvPy -m pip install "litellm[proxy]"
if ($LASTEXITCODE -ne 0) { Write-Err2 "Failed to install litellm. See the log above."; return }

# ---------- 6. Verify ----------
if (-not (Test-Path $LitellmExe)) {
    Write-Err2 "Installed but $LitellmExe is missing. Try again with -Force."
    return
}
$llVer = (& $VenvPy -m litellm --version) 2>&1
Write-Ok "LiteLLM is ready. $llVer"

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " DONE. LiteLLM installed at: $VenvPath" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " Next steps:" -ForegroundColor Cyan
Write-Host "   1. Open start-claude.ps1 and set BaseUrl / Model / Key (or leave Key blank to be prompted)."
Write-Host "   2. Run:  .\start-claude.ps1"
