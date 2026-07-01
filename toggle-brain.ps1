<#
================================================================
  toggle-brain.ps1  (claude-code-anyllm)
  Toggle Claude Code's "brain" between real Anthropic and any
  OpenAI-compatible LLM via a local LiteLLM proxy.

  INSTEAD OF managing two separate scripts (switch-to-claude.ps1
  and switch-to-fpt.ps1), this ONE script handles everything:
  switching, status checking, proxy lifecycle, and key management.

  USAGE:
    .\toggle-brain.ps1 -Mode claude     Switch to real Anthropic account
    .\toggle-brain.ps1 -Mode proxy      Switch to proxy LLM (FPT/DeepSeek etc.)
    .\toggle-brain.ps1 -Status          Show current brain status
    .\toggle-brain.ps1 -Mode proxy -StartProxy -Key "sk-..."
    .\toggle-brain.ps1 -StopProxy       Stop running proxy
    .\toggle-brain.ps1 -ListProfiles    Show available profiles
    .\toggle-brain.ps1 -Mode proxy -Profile openai   Use a different profile

  DESIGN PHILOSOPHY:
    - "Profile" = a JSON file in profiles/ that sets Claude Code's env vars.
    - Switching = copying the chosen profile → ~\.claude\settings.json.
    - The proxy translates Anthropic ↔ OpenAI so any provider works.
================================================================
#>

param(
    # Which mode to switch to: "claude" (real Anthropic) or "proxy" (third-party LLM)
    [ValidateSet("claude", "proxy", "")]
    [string]$Mode = "",

    # Profile name (without .json) inside the profiles/ folder. Defaults to
    # "claude" for -Mode claude, or "fpt" for -Mode proxy.
    [string]$Profile = "",

    # API key for the proxy provider. Leave empty to be prompted (hidden input).
    [string]$Key = "",

    # Show current brain status and exit
    [switch]$Status,

    # List available profiles and exit
    [switch]$ListProfiles,

    # Start the proxy after switching (only meaningful with -Mode proxy)
    [switch]$StartProxy,

    # Stop a running proxy on the given port
    [switch]$StopProxy,

    # Proxy port (default 4000)
    [int]$Port = 4000
)

$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────
# 0. Paths
# ──────────────────────────────────────────────────────────────
if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$ProfilesDir     = Join-Path $ScriptDir "profiles"
$ClaudeDir       = "$env:USERPROFILE\.claude"
$SettingsPath    = Join-Path $ClaudeDir "settings.json"
$LocalVenv       = Join-Path $ScriptDir ".venv"
$UserVenv        = Join-Path $env:USERPROFILE "litellm-env"
$ConfigPath      = Join-Path $ScriptDir "config\litellm_config.yaml"
$ProxyUrl        = "http://localhost:$Port"

# ──────────────────────────────────────────────────────────────
# 1. UI helpers
# ──────────────────────────────────────────────────────────────
$I = @{ ok="[OK]"; info="==>"; warn="[!]"; err="[X]"; star="[*]" }

function Write-Ok($m)   { Write-Host "$($I.ok) $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "$($I.info) $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "$($I.warn) $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "$($I.err) $m" -ForegroundColor Red }
function Write-Star($m) { Write-Host "$($I.star) $m" -ForegroundColor Magenta }

function Write-Header($m) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host " $m" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
}

# ──────────────────────────────────────────────────────────────
# 2. Helpers
# ──────────────────────────────────────────────────────────────

# Detect the current brain mode from settings.json
function Get-CurrentMode {
    if (-not (Test-Path $SettingsPath)) { return "unknown" }
    try {
        $cfg = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        $envBlock = $cfg.env
        if (-not $envBlock -or @($envBlock.PSObject.Properties).Count -eq 0) { return "claude" }
        $url = "$($envBlock.ANTHROPIC_BASE_URL)"
        if ($url -like "http://localhost*") { return "proxy" }
        return "custom"
    } catch { return "unknown" }
}

# Read a profile JSON file
function Get-Profile([string]$name) {
    $path = Join-Path $ProfilesDir "$name.json"
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
}

# List all available profiles
function Get-AvailableProfiles {
    if (-not (Test-Path $ProfilesDir)) { return @() }
    Get-ChildItem "$ProfilesDir\*.json" | ForEach-Object {
        $name = $_.BaseName
        $p = Get-Profile $name
        [PSCustomObject]@{
            Name        = $name
            Description = if ($p.description) { $p.description } else { "No description" }
            Provider    = if ($p.provider) { $p.provider } else { "generic" }
        }
    }
}

# Check if the proxy is listening
function Test-ProxyRunning {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conns)
}

# Prompt for API key (hidden input)
function Read-SecretKey {
    $secure = Read-Host "Enter API key" -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $key    = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    return $key
}

# ──────────────────────────────────────────────────────────────
# 3. Mode: -Status
# ──────────────────────────────────────────────────────────────
if ($Status) {
    Write-Header "BRAIN STATUS"

    $mode = Get-CurrentMode
    switch ($mode) {
        "claude" { Write-Host "  Current brain: " -NoNewline; Write-Host "REAL ANTHROPIC" -ForegroundColor Green }
        "proxy"  { Write-Host "  Current brain: " -NoNewline; Write-Host "PROXY (third-party LLM)" -ForegroundColor Yellow }
        "custom" { Write-Host "  Current brain: " -NoNewline; Write-Host "CUSTOM CONFIG" -ForegroundColor Magenta }
        default  { Write-Host "  Current brain: " -NoNewline; Write-Host "UNKNOWN" -ForegroundColor Red }
    }

    if (Test-Path $SettingsPath) {
        Write-Host "  Config file:   $SettingsPath" -ForegroundColor DarkGray
    } else {
        Write-Host "  Config file:   (not found)" -ForegroundColor DarkGray
    }

    $proxyRunning = Test-ProxyRunning
    if ($proxyRunning) {
        Write-Host "  Proxy status:  " -NoNewline; Write-Host "RUNNING (port $Port)" -ForegroundColor Green
    } else {
        Write-Host "  Proxy status:  " -NoNewline; Write-Host "STOPPED" -ForegroundColor DarkGray
    }

    Write-Host ""
    if ($mode -eq "proxy" -and -not $proxyRunning) {
        Write-Warn "Proxy mode is active but the proxy is NOT running."
        Write-Host "  Start it:  .\toggle-brain.ps1 -Mode proxy -StartProxy" -ForegroundColor Cyan
    } elseif ($mode -eq "claude" -and $proxyRunning) {
        Write-Warn "Claude mode is active but the proxy is still running."
        Write-Host "  Stop it:   .\toggle-brain.ps1 -StopProxy" -ForegroundColor Cyan
    } elseif ($mode -eq "proxy" -and $proxyRunning) {
        Write-Ok "Everything looks good. Claude Code is using the proxy."
    } elseif ($mode -eq "claude" -and -not $proxyRunning) {
        Write-Ok "Everything looks good. Claude Code is using the real Anthropic API."
    }

    Write-Host ""
    Write-Host "  Toggle:    .\toggle-brain.ps1 -Mode proxy" -ForegroundColor Cyan
    Write-Host "  Profiles:  .\toggle-brain.ps1 -ListProfiles" -ForegroundColor Cyan
    return
}

# ──────────────────────────────────────────────────────────────
# 4. Mode: -ListProfiles
# ──────────────────────────────────────────────────────────────
if ($ListProfiles) {
    Write-Header "AVAILABLE PROFILES"
    $profiles = Get-AvailableProfiles
    if ($profiles.Count -eq 0) {
        Write-Err "No profiles found in $ProfilesDir"
        return
    }
    foreach ($p in $profiles) {
        $tag = switch ($p.Name) {
            "claude" { "ANTHROPIC" }
            "fpt"    { "FPT/DeepSeek" }
            default  { $p.Provider.ToUpper() }
        }
        Write-Host "  $($p.Name)" -NoNewline -ForegroundColor Cyan
        Write-Host "  ($tag)" -NoNewline -ForegroundColor DarkGray
        Write-Host "  — $($p.Description)"
    }
    Write-Host ""
    Write-Host "  Use:  .\toggle-brain.ps1 -Mode proxy -Profile <name>" -ForegroundColor Cyan
    return
}

# ──────────────────────────────────────────────────────────────
# 5. Mode: -StopProxy
# ──────────────────────────────────────────────────────────────
if ($StopProxy) {
    Write-Header "STOP PROXY"
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) {
        Write-Warn "No proxy process found on port $Port."
        return
    }
    $pids = $conns.OwningProcess | Sort-Object -Unique
    foreach ($procId in $pids) {
        try {
            Stop-Process -Id $procId -Force
            Write-Ok "Stopped proxy process (PID $procId)."
        } catch {
            Write-Err "Could not stop PID $procId : $_"
        }
    }
    return
}

# ──────────────────────────────────────────────────────────────
# 6. Main: switch mode
# ──────────────────────────────────────────────────────────────
if (-not $Mode) {
    # No args → show usage
    Write-Host @"

  toggle-brain.ps1 — Toggle Claude Code's brain

  USAGE:
    .\toggle-brain.ps1 -Mode claude     Switch to real Anthropic
    .\toggle-brain.ps1 -Mode proxy      Switch to proxy LLM
    .\toggle-brain.ps1 -Status          Show current brain status
    .\toggle-brain.ps1 -ListProfiles    List available profiles
    .\toggle-brain.ps1 -StopProxy       Stop running proxy

  OPTIONS (with -Mode proxy):
    -Profile <name>   Use a specific profile (default: fpt)
    -Key <key>        API key (omit to be prompted)
    -StartProxy       Auto-start the proxy if not running
    -Port <int>       Proxy port (default 4000)

  EXAMPLES:
    .\toggle-brain.ps1 -Mode claude
    .\toggle-brain.ps1 -Mode proxy -StartProxy
    .\toggle-brain.ps1 -Mode proxy -Profile openai -Key "sk-..."

"@
    return
}

# ──────────────────────────────────────────────────────────────
# 6a. Resolve profile
# ──────────────────────────────────────────────────────────────
if (-not $Profile) {
    $Profile = if ($Mode -eq "claude") { "claude" } else { "fpt" }
}

$profileData = Get-Profile $Profile
if (-not $profileData) {
    Write-Err "Profile '$Profile' not found in $ProfilesDir"
    Write-Host "  Available: " -NoNewline
    (Get-AvailableProfiles).Name | ForEach-Object { Write-Host "$_ " -NoNewline -ForegroundColor Cyan }
    Write-Host ""
    return
}

Write-Header "SWITCHING BRAIN → $($Profile.ToUpper())"
Write-Host "  Profile:     $Profile.json" -ForegroundColor DarkGray
Write-Host "  Target:      $($profileData.description)" -ForegroundColor DarkGray

# ──────────────────────────────────────────────────────────────
# 6b. Apply the profile
# ──────────────────────────────────────────────────────────────
$src = Join-Path $ProfilesDir "$Profile.json"
$dst = $SettingsPath

# Ensure ~\.claude exists
if (-not (Test-Path $ClaudeDir)) {
    New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
    Write-Info "Created $ClaudeDir"
}

Copy-Item $src $dst -Force
Write-Ok "Applied profile → $dst"

# Show what env vars were set
$envBlock = $profileData.env
if ($envBlock -and @($envBlock.PSObject.Properties).Count -gt 0) {
    Write-Info "Environment variables set:"
    foreach ($prop in $envBlock.PSObject.Properties) {
        Write-Host "    $($prop.Name) = $($prop.Value)" -ForegroundColor DarkGray
    }
} else {
    Write-Info "Environment: empty (real Anthropic mode)"
}

# ──────────────────────────────────────────────────────────────
# 6c. Proxy lifecycle (for -Mode proxy)
# ──────────────────────────────────────────────────────────────
if ($Mode -eq "proxy") {
    $proxyRunning = Test-ProxyRunning

    if ($StartProxy -and -not $proxyRunning) {
        Write-Header "STARTING PROXY"

        # Resolve API key
        if ([string]::IsNullOrWhiteSpace($Key)) {
            $Key = Read-SecretKey
        }
        if ([string]::IsNullOrWhiteSpace($Key)) {
            Write-Err "No API key provided. Aborting proxy start."
            Write-Warn "You can still use the profile — just start the proxy manually later."
            Write-Host "  Proxy:  .\start-claude.ps1 -NoVSCode" -ForegroundColor Cyan
            Write-Host ""
            Write-Star "DONE. Profile applied. Restart Claude Code to take effect."
            return
        }

        # Find LiteLLM executable
        if (Test-Path (Join-Path $LocalVenv "Scripts\litellm.exe")) {
            $VenvPath = $LocalVenv
        } elseif (Test-Path (Join-Path $UserVenv "Scripts\litellm.exe")) {
            $VenvPath = $UserVenv
        } else {
            Write-Err "LiteLLM not found. Run setup-litellm.ps1 first."
            Write-Warn "Profile applied, but proxy not started."
            Write-Host ""
            Write-Star "DONE. Profile applied. Restart Claude Code to take effect."
            return
        }

        $ActivateScript = Join-Path $VenvPath "Scripts\Activate.ps1"

        # Write config (UTF-8 without BOM)
        $ClaudeAlias = $profileData.env.ANTHROPIC_MODEL
        if (-not $ClaudeAlias) { $ClaudeAlias = "claude-sonnet-4-6" }

        # Extract model name from the profile's base URL
        $baseUrl = $profileData.env.ANTHROPIC_BASE_URL
        # Default model name — the profile doesn't store the provider model, so
        # we derive it from the alias. Users can override with -Key.
        $providerModel = "DeepSeek-V4-Flash"

        $yaml = @"
model_list:
  - model_name: $ClaudeAlias
    litellm_params:
      model: openai/$providerModel
      api_base: $baseUrl
      api_key: os.environ/LLM_API_KEY
"@
        [System.IO.File]::WriteAllText($ConfigPath, $yaml, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Config written: $ConfigPath"

        # Start proxy in a new window
        $proxyCmd = @"
& '$ActivateScript'
`$env:LLM_API_KEY = '$Key'
Write-Host 'LiteLLM proxy is running. CLOSE this window to stop.' -ForegroundColor Green
litellm --config '$ConfigPath' --port $Port
"@
        Start-Process powershell -ArgumentList "-NoExit", "-Command", $proxyCmd | Out-Null
        Write-Ok "Proxy starting on port $Port (separate window)"

        # Wait for readiness
        Write-Info "Waiting for proxy (up to 15s)..."
        $ready = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            try {
                $r = Invoke-WebRequest -Uri "$ProxyUrl/health/liveliness" -UseBasicParsing -TimeoutSec 2
                if ($r.StatusCode -eq 200) { $ready = $true; break }
            } catch { }
        }
        if ($ready) {
            Write-Ok "Proxy is ready at $ProxyUrl"
        } else {
            Write-Warn "Could not confirm proxy after 15s. Check the proxy window."
        }

    } elseif ($StartProxy -and $proxyRunning) {
        Write-Ok "Proxy is already running on port $Port."
    } elseif (-not $proxyRunning) {
        Write-Warn "Proxy is NOT running. Start it with -StartProxy:"
        Write-Host "    .\toggle-brain.ps1 -Mode proxy -StartProxy" -ForegroundColor Cyan
    }
}

# ──────────────────────────────────────────────────────────────
# 6d. Stop proxy hint (for -Mode claude)
# ──────────────────────────────────────────────────────────────
if ($Mode -eq "claude") {
    $proxyRunning = Test-ProxyRunning
    if ($proxyRunning) {
        Write-Warn "Proxy is still running on port $Port."
        Write-Host "  Stop it:  .\toggle-brain.ps1 -StopProxy" -ForegroundColor Cyan
    }
}

# ──────────────────────────────────────────────────────────────
# 7. Done
# ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Star "DONE. Claude Code brain switched to: $($profileData.description)"
Write-Warn "IMPORTANT: Close and reopen Claude Code (or New session) for the change to take effect."
Write-Host ""
Write-Host "  Verify:    .\toggle-brain.ps1 -Status" -ForegroundColor Cyan
Write-Host "  Revert:    .\toggle-brain.ps1 -Mode $((@("claude","proxy") -ne $Mode)[0])" -ForegroundColor Cyan
