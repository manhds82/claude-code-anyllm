<#
================================================================
  start-claude.ps1  (claude-code-anyllm)
  Run Claude Code inside VS Code, but powered by ANY OpenAI-compatible
  LLM endpoint, bridged through a local LiteLLM proxy.

  Flow:  VS Code (Claude Code) -> LiteLLM :4000 -> your provider's /v1 endpoint

  USAGE:
    1. Run:  .\start-claude.ps1
       With no -Provider/-BaseUrl given, you get an interactive menu built
       from config\providers.conf -- pick FPT, NVIDIA, Gemini, GitHub, Groq...
       Each provider reads its key from its own env var (see -ListProviders),
       so you just set the key for whichever provider you actually have.
    2. Or skip the menu:  .\start-claude.ps1 -Provider nvidia
    3. Or bypass providers.conf entirely with -BaseUrl / -Model / -Key.
    4. The script starts the proxy (in its own window), waits until it is ready,
       then opens VS Code already pointed at the proxy.
    5. Stop the proxy: close the LiteLLM window, or run  .\start-claude.ps1 -Stop

  PARAMETERS:
    -Provider <id> : Pick a provider by id from config\providers.conf.
    -ListProviders : List providers.conf entries and which have a key set.
    -BaseUrl <url> : OpenAI-compatible /v1 endpoint to use for this run
                     (overrides the selected provider's base_url).
    -Model <name>  : Model name to use for this run (overrides provider's model).
    -Key <key>     : API key to use for this run (not saved to disk;
                     overrides the provider's key_env).
    -List          : List the models the endpoint exposes (/v1/models), then exit.
    -Port <int>    : Proxy port (default 4000). Auto-finds a free port if busy.
    -Stop          : Stop a running proxy on that port.
    -NoVSCode      : Only start the proxy; don't open VS Code.

  FIRST TIME (LiteLLM not installed yet): run  .\setup-litellm.ps1  once.
================================================================
#>

param(
    # ================ EDIT THESE FOR YOUR PROVIDER ================
    # OpenAI-compatible base URL (must end in /v1). Examples:
    #   FPT Cloud : https://mkp-api.fptcloud.com/v1
    #   OpenAI    : https://api.openai.com/v1
    #   OpenRouter: https://openrouter.ai/api/v1
    #   Groq      : https://api.groq.com/openai/v1
    #   DeepSeek  : https://api.deepseek.com/v1
    #   Ollama    : http://localhost:11434/v1
    [string]$BaseUrl = "https://mkp-api.fptcloud.com/v1",

    # Model name exactly as the provider spells it. See options with: -List
    # Pick one that supports tool / function calling so Claude Code can edit files.
    [string]$Model   = "DeepSeek-V4-Flash",

    # API key. Leave "" to read $env:LLM_API_KEY, else you'll be asked at runtime
    # (hidden input). Recommended: don't hard-code it here -- set LLM_API_KEY instead.
    [string]$Key     = "",
    # =============================================================

    # Pick a provider by id from config\providers.conf instead of -BaseUrl/-Model.
    # Omit both -Provider and -BaseUrl to get an interactive menu instead.
    [string]$Provider = "",

    [switch]$List,
    [switch]$Stop,
    [switch]$NoVSCode,
    [switch]$ListProviders,
    [int]$Port = 4000,

    # Folder to open in VS Code. Default: the script's own folder (claude-code-anyllm).
    # Set this to open a different project: -OpenDir "C:\MyProjects\myapp"
    # Or drop open-with-claude.ps1 in each project to set this automatically.
    [string]$OpenDir = ""
)

$ErrorActionPreference = "Stop"

# Label Claude Code shows for the model. Arbitrary; the script keeps the proxy
# config and the ANTHROPIC_MODEL env var in sync, so you normally never touch this.
$ClaudeAlias = "claude-sonnet-4-6"

$ProxyUrl = "http://localhost:$Port"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    [!] $msg"  -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    [X] $msg"  -ForegroundColor Red }

# Return the configured key: inline -> $env:LLM_API_KEY -> prompt (hidden input).
function Resolve-Key([string]$current) {
    if (-not [string]::IsNullOrWhiteSpace($current)) { return $current }
    if (-not [string]::IsNullOrWhiteSpace($env:LLM_API_KEY)) { return $env:LLM_API_KEY }
    $secure = Read-Host "Enter API key" -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $key    = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    return $key
}

# ---------- Paths (work no matter where the folder lives) ----------
if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# LiteLLM virtual env. Prefer project-local ".venv" (created by setup-litellm.ps1),
# otherwise fall back to "litellm-env" in the current user's home folder.
$LocalVenv = Join-Path $ScriptDir ".venv"
$UserVenv  = Join-Path $env:USERPROFILE "litellm-env"
if (Test-Path (Join-Path $LocalVenv "Scripts\litellm.exe")) {
    $VenvPath = $LocalVenv
} else {
    $VenvPath = $UserVenv
}

# Proxy config file lives inside the project. It is REGENERATED on every run.
$ConfigPath = Join-Path $ScriptDir "config\litellm_config.yaml"

# Folder VS Code opens: -OpenDir wins, otherwise the script's own folder.
$ProjectDir = if ([string]::IsNullOrWhiteSpace($OpenDir)) { $ScriptDir } else { (Resolve-Path $OpenDir).Path }

# Provider list: config\providers.conf, pipe-delimited "id|label|base_url|model|key_env".
# Add a line there to add a provider -- no code changes needed.
function Get-Providers {
    $path = Join-Path $ScriptDir "config\providers.conf"
    if (-not (Test-Path $path)) { return @() }
    Get-Content $path | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith("#") } | ForEach-Object {
        $parts = $_ -split '\|'
        if ($parts.Count -ge 5) {
            [PSCustomObject]@{
                Id      = $parts[0].Trim()
                Label   = $parts[1].Trim()
                BaseUrl = $parts[2].Trim()
                Model   = $parts[3].Trim()
                KeyEnv  = $parts[4].Trim()
            }
        }
    }
}

# Interactive menu: pick a provider, show which ones already have a key set
# (via their key_env from providers.conf).
function Select-ProviderInteractive([array]$providers) {
    Write-Step "Choose a provider (config\providers.conf)"
    for ($i = 0; $i -lt $providers.Count; $i++) {
        $p = $providers[$i]
        $hasKey = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($p.KeyEnv))
        $tag = if ($hasKey) { "[key set]" } else { "[no key]" }
        Write-Host ("  {0}. {1,-38} {2}" -f ($i + 1), $p.Label, $tag)
    }
    $choice = Read-Host "`nPick a number (Enter = 1)"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $providers.Count) {
        Write-Err2 "Invalid choice."
        return $null
    }
    return $providers[$idx]
}


# ---------- Mode -Stop: kill the proxy and exit ----------
if ($Stop) {
    Write-Step "Looking for the process holding port $Port ..."
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) {
        Write-Warn2 "No process is listening on port $Port."
    } else {
        $pids = $conns.OwningProcess | Sort-Object -Unique
        foreach ($procId in $pids) {
            try {
                Stop-Process -Id $procId -Force
                Write-Ok "Stopped process PID $procId."
            } catch {
                Write-Err2 "Could not stop PID $procId : $_"
            }
        }
    }
    return
}


# ---------- Mode -ListProviders: show config\providers.conf then exit ----------
if ($ListProviders) {
    $providers = Get-Providers
    if (-not $providers) {
        Write-Err2 "No providers found in config\providers.conf"
        return
    }
    Write-Step "Providers in config\providers.conf"
    foreach ($p in $providers) {
        $hasKey = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($p.KeyEnv))
        $tag = if ($hasKey) { "[key set]" } else { "[no key]" }
        Write-Host ("  {0,-8} {1,-38} {2}   (env: {3})" -f $p.Id, $p.Label, $tag, $p.KeyEnv)
    }
    Write-Host "`nSet a key once:  setx <KEY_ENV_NAME> `"sk-...`"   (open a new terminal after)"
    Write-Host "Use directly:    .\start-claude.ps1 -Provider <id>"
    return
}


# ---------- Mode -List: list models then exit ----------
if ($List) {
    $Key = Resolve-Key $Key
    if ([string]::IsNullOrWhiteSpace($Key)) { Write-Err2 "No API key. Aborting."; return }
    Write-Step "Fetching models from $BaseUrl/models ..."
    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/models" -Headers @{ Authorization = "Bearer $Key" } -TimeoutSec 15
        $ids  = $resp.data | ForEach-Object { $_.id } | Sort-Object
        if ($ids) {
            Write-Ok "$($ids.Count) model(s). Put one in `$Model or pass it with -Model:"
            $ids | ForEach-Object { Write-Host "    - $_" }
        } else {
            Write-Warn2 "Could not read the list (empty response)."
        }
    } catch {
        Write-Err2 "GET /models failed: $_"
        Write-Warn2 "Check the key, the base URL, and your network."
    }
    return
}


# ---------- 0. Resolve provider (-Provider, or an interactive menu) ----------
# Skipped entirely if the caller passed -BaseUrl and/or -Model explicitly --
# those always win over providers.conf.
$providers = Get-Providers
if ($Provider) {
    $selected = $providers | Where-Object { $_.Id -eq $Provider }
    if (-not $selected) {
        Write-Err2 "Provider '$Provider' not found. Run -ListProviders to see valid ids."
        return
    }
    if (-not $PSBoundParameters.ContainsKey('BaseUrl')) { $BaseUrl = $selected.BaseUrl }
    if (-not $PSBoundParameters.ContainsKey('Model'))   { $Model   = $selected.Model }
    if ([string]::IsNullOrWhiteSpace($Key)) { $Key = [Environment]::GetEnvironmentVariable($selected.KeyEnv) }
    Write-Ok "Provider: $($selected.Label)"
} elseif (-not $PSBoundParameters.ContainsKey('BaseUrl') -and -not $PSBoundParameters.ContainsKey('Model') -and $providers.Count -gt 0) {
    $selected = Select-ProviderInteractive $providers
    if (-not $selected) { return }
    $BaseUrl = $selected.BaseUrl
    $Model   = $selected.Model
    if ([string]::IsNullOrWhiteSpace($Key)) { $Key = [Environment]::GetEnvironmentVariable($selected.KeyEnv) }
    Write-Ok "Provider: $($selected.Label)"
}


# ---------- 1. Check the virtual env (auto-install if missing) ----------
Write-Step "Checking the LiteLLM virtual env ..."
$ActivateScript = Join-Path $VenvPath "Scripts\Activate.ps1"
$LitellmExe     = Join-Path $VenvPath "Scripts\litellm.exe"
if (-not (Test-Path $LitellmExe)) {
    Write-Warn2 "LiteLLM not found. Trying to install it via setup-litellm.ps1 ..."
    $setup = Join-Path $ScriptDir "setup-litellm.ps1"
    if (Test-Path $setup) {
        & $setup
        # After install, the project-local .venv is preferred -- switch to it.
        if (Test-Path (Join-Path $LocalVenv "Scripts\litellm.exe")) {
            $VenvPath       = $LocalVenv
            $ActivateScript = Join-Path $VenvPath "Scripts\Activate.ps1"
            $LitellmExe     = Join-Path $VenvPath "Scripts\litellm.exe"
        }
    }
    if (-not (Test-Path $LitellmExe)) {
        Write-Err2 "LiteLLM still missing. Run it manually:  .\setup-litellm.ps1"
        return
    }
}
Write-Ok "LiteLLM found."


# ---------- 2. Resolve the key (prompt if missing) ----------
$Key = Resolve-Key $Key
if ([string]::IsNullOrWhiteSpace($Key)) {
    Write-Err2 "No API key. Aborting."
    return
}


# ---------- 3. Write the proxy config (UTF-8 WITHOUT BOM) ----------
Write-Step "Writing config: $ConfigPath"
$ConfigDir = Split-Path -Parent $ConfigPath
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    Write-Ok "Created config folder: $ConfigDir"
}
$yaml = @"
model_list:
  - model_name: $ClaudeAlias
    litellm_params:
      model: openai/$Model
      api_base: $BaseUrl
      api_key: os.environ/LLM_API_KEY
"@
[System.IO.File]::WriteAllText($ConfigPath, $yaml, (New-Object System.Text.UTF8Encoding($false)))
$firstByte = [System.IO.File]::ReadAllBytes($ConfigPath)[0]
if ($firstByte -eq 239) {
    Write-Err2 "Config still has a BOM (first byte = 239). Aborting."
    return
}
Write-Ok "Config is clean (no BOM)."


# ---------- 4. Warn about a stray .env file (if any) ----------
$envFile = Join-Path (Split-Path $ConfigPath) ".env"
if (Test-Path $envFile) {
    Write-Warn2 "Found $envFile - LiteLLM auto-reads it and it MAY break on encoding."
    Write-Warn2 "If the proxy crashes with UnicodeDecodeError, rename this file:"
    Write-Host  "      Rename-Item `"$envFile`" .env.bak" -ForegroundColor Yellow
}


# ---------- 5. Find a free port (auto-advance if busy) ----------
$originalPort = $Port
while ($true) {
    $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $busy) { break }
    $Port++
    if ($Port -gt $originalPort + 20) {
        Write-Err2 "No free port between $originalPort and $Port."
        return
    }
}
if ($Port -ne $originalPort) {
    Write-Warn2 "Port $originalPort was busy, switching to port $Port."
}
$ProxyUrl = "http://localhost:$Port"


# ---------- 6. Start the proxy in its own window ----------
Write-Step "Starting LiteLLM proxy in a new window (port $Port) ..."
$proxyCmd = @"
& '$ActivateScript'
`$env:LLM_API_KEY = '$Key'
Write-Host 'LiteLLM proxy is running. CLOSE this window to stop the proxy.' -ForegroundColor Green
litellm --config '$ConfigPath' --port $Port
"@
Start-Process powershell -ArgumentList "-NoExit", "-Command", $proxyCmd | Out-Null
Write-Ok "Proxy window started."


# ---------- 7. Wait until the proxy is ready ----------
Write-Step "Waiting for the proxy to be ready (up to 30s) ..."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "$ProxyUrl/health/liveliness" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch {
        # not up yet, retry
    }
}
if ($ready) {
    Write-Ok "Proxy is ready at $ProxyUrl"
} else {
    Write-Warn2 "Could not confirm the proxy after 30s. Check the proxy window for errors."
    Write-Warn2 "VS Code will still open; if Claude Code reports a connection error, check that window."
}


# ---------- 8. Open VS Code pointed at the proxy ----------
if ($NoVSCode) {
    Write-Step "Skipping VS Code (-NoVSCode)."
    Write-Host "`nProxy is running. To open VS Code manually, run IN THIS WINDOW:" -ForegroundColor Cyan
    Write-Host "  `$env:ANTHROPIC_BASE_URL = '$ProxyUrl'"
    Write-Host "  `$env:ANTHROPIC_AUTH_TOKEN = 'litellm-proxy'"
    Write-Host "  `$env:ANTHROPIC_MODEL = '$ClaudeAlias'"
    Write-Host "  `$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = '$ClaudeAlias'"
    Write-Host "  `$env:ANTHROPIC_DEFAULT_SONNET_MODEL = '$ClaudeAlias'"
    Write-Host "  `$env:ANTHROPIC_DEFAULT_OPUS_MODEL = '$ClaudeAlias'"
    Write-Host "  Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue"
    Write-Host "  code ."
    return
}

Write-Step "Opening VS Code (Claude Code pointed at the proxy) ..."
$env:ANTHROPIC_BASE_URL   = $ProxyUrl
$env:ANTHROPIC_AUTH_TOKEN = "litellm-proxy"   # dummy token; the real key lives in the proxy
$env:ANTHROPIC_MODEL      = $ClaudeAlias
# Route the background models (haiku/sonnet/opus) to the same alias so the proxy
# can serve them too -- otherwise Claude Code's background calls fail.
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $ClaudeAlias
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $ClaudeAlias
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $ClaudeAlias
# Drop any real Anthropic key in this session so Claude Code can't fall back to it.
Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue

code $ProjectDir
Write-Ok "Opened VS Code for project: $ProjectDir"

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " DONE. Claude Code in VS Code now runs on: $Model" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " Tool-calling smoke test (do this inside Claude Code):" -ForegroundColor Cyan
Write-Host "   1. 'Read README.md and summarize it'"
Write-Host "   2. 'Create a file test.txt containing hello'"
Write-Host " If it reads/creates the file -> good. If it only replies with text -> pick another model."
Write-Host ""
Write-Host " Stop the proxy when done:  .\start-claude.ps1 -Stop -Port $Port" -ForegroundColor Yellow
