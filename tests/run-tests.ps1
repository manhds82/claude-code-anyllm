<#
================================================================
  tests/run-tests.ps1  (claude-code-anyllm)
  Deterministic, offline test runner. Never launches a proxy,
  hits a provider, or opens an editor.

  Suites:
    policy-ci  - correctness / governance (parse, JSON, config, parity)
    red-team   - security (no secrets, dummy token, no remote-to-shell)

  Usage:
    pwsh -File tests/run-tests.ps1                # all suites
    pwsh -File tests/run-tests.ps1 -Suite red-team
  Exit code = number of failed checks (0 = all green).
================================================================
#>
param([ValidateSet("all","policy-ci","red-team")] [string]$Suite = "all")

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot          # repo root (tests/ is one level down)
$results = New-Object System.Collections.Generic.List[object]

function Check($suite, $name, [bool]$ok, $detail = "") {
    $results.Add([pscustomobject]@{ Suite = $suite; Name = $name; Ok = $ok; Detail = $detail })
    $tag = if ($ok) { "  PASS" } else { "  FAIL" }
    $col = if ($ok) { "Green" } else { "Red" }
    Write-Host $tag -ForegroundColor $col -NoNewline
    Write-Host "  [$suite] $name" -NoNewline
    if (-not $ok -and $detail) { Write-Host "  -> $detail" -ForegroundColor DarkYellow } else { Write-Host "" }
}

function RepoFile($rel) { Join-Path $Root $rel }
function ReadText($rel) { $p = RepoFile $rel; if (Test-Path $p) { [System.IO.File]::ReadAllText($p) } else { $null } }

$productPs1 = @("setup-litellm.ps1", "start-claude.ps1", "toggle-brain.ps1")
$productSh  = @("setup-litellm.sh", "start-claude.sh", "toggle-brain.sh")

# ------------------------------------------------------------------ policy-ci
function Invoke-PolicyCI {
    Write-Host "`n=== suite: policy-ci ===" -ForegroundColor Cyan

    # 1. PowerShell scripts parse (AST) with no errors
    foreach ($f in $productPs1) {
        $p = RepoFile $f
        if (-not (Test-Path $p)) { Check "policy-ci" "parse $f" $false "missing"; continue }
        # Read as UTF-8 explicitly (files are UTF-8) and parse the text, so the
        # check is locale-independent (ParseFile would misread a BOM-less file
        # under a non-UTF-8 system codepage).
        $txt = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
        $tok = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$tok, [ref]$er)
        Check "policy-ci" "parse $f" ($er.Count -eq 0) (($er | ForEach-Object { $_.Message }) -join "; ")
    }

    # 1b. .ps1 must be readable by Windows PowerShell 5.1: pure-ASCII OR UTF-8 BOM.
    #     A BOM-less script with non-ASCII chars is misparsed on a non-UTF-8 locale.
    foreach ($f in $productPs1) {
        $p = RepoFile $f
        if (-not (Test-Path $p)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $nonAscii = $false; foreach ($b in $bytes) { if ($b -gt 0x7F) { $nonAscii = $true; break } }
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Check "policy-ci" "ps1 PS5.1-safe encoding: $f" ((-not $nonAscii) -or $bom) "non-ASCII without UTF-8 BOM -> PS 5.1 misparses on non-UTF-8 locale"
    }

    # 2. Bash scripts pass `bash -n` (skip gracefully if bash absent)
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    foreach ($f in $productSh) {
        $p = RepoFile $f
        if (-not (Test-Path $p)) { Check "policy-ci" "syntax $f" $false "missing"; continue }
        if (-not $bash) { Check "policy-ci" "syntax $f (bash -n)" $true "SKIP: bash not on PATH"; continue }
        & $bash.Source -n $p 2>$null
        Check "policy-ci" "syntax $f (bash -n)" ($LASTEXITCODE -eq 0) "bash -n exit $LASTEXITCODE"
    }

    # 3. profiles/*.json are valid JSON with a description
    $profiles = Get-ChildItem (RepoFile "profiles") -Filter *.json -ErrorAction SilentlyContinue
    Check "policy-ci" "profiles/ has JSON files" ($profiles.Count -gt 0) "none found"
    foreach ($pf in $profiles) {
        try { $j = Get-Content $pf.FullName -Raw | ConvertFrom-Json; $ok = [bool]$j.description }
        catch { $ok = $false }
        Check "policy-ci" "profile valid+described: $($pf.Name)" $ok
    }

    # 4. generated config references env key and defines a model_name
    $cfg = ReadText "config/litellm_config.yaml"
    Check "policy-ci" "config has model_name" ($cfg -and $cfg -match "model_name:")
    Check "policy-ci" "config key via os.environ" ($cfg -and $cfg -match "api_key:\s*os\.environ/")

    # 4b. F-03 regression: generated config quotes user-supplied scalars
    Check "policy-ci" "config quotes user values (YAML scalars)" (($cfg -match "model_name:\s*'") -and ($cfg -match "api_base:\s*'"))

    # 5. .gitignore covers venv + env files
    $gi = ReadText ".gitignore"
    Check "policy-ci" ".gitignore ignores .venv" ($gi -and $gi -match "(?m)^\.venv/")
    Check "policy-ci" ".gitignore ignores .env" ($gi -and $gi -match "(?m)^\.env")

    # 6. .gitattributes keeps .sh as LF
    $ga = ReadText ".gitattributes"
    Check "policy-ci" ".gitattributes *.sh eol=lf" ($ga -and $ga -match "\*\.sh\s+text\s+eol=lf")

    # 7. cross-platform flag parity (each feature present in both launchers)
    $psL = ReadText "start-claude.ps1"; $shL = ReadText "start-claude.sh"
    $map = @(
        @{ f = "list";      ps = '$List';     sh = '--list' }
        @{ f = "stop";      ps = '$Stop';     sh = '--stop' }
        @{ f = "port";      ps = '$Port';     sh = '--port' }
        @{ f = "model";     ps = '$Model';    sh = '--model' }
        @{ f = "key";       ps = '$Key';      sh = '--key' }
        @{ f = "base-url";  ps = '$BaseUrl';  sh = '--base-url' }
        @{ f = "provider";  ps = '$Provider'; sh = '--provider' }
        @{ f = "no-vscode"; ps = '$NoVSCode'; sh = '--no-vscode' }
    )
    foreach ($m in $map) {
        $ok = ($psL -and $psL.Contains($m.ps)) -and ($shL -and $shL.Contains($m.sh))
        Check "policy-ci" "parity: $($m.f)" $ok "ps:$($psL.Contains($m.ps)) sh:$($shL.Contains($m.sh))"
    }

    # 8. engineering docs exist
    Check "policy-ci" "docs/SRS.md exists"  (Test-Path (RepoFile "docs/SRS.md"))
    Check "policy-ci" "docs/spec.md exists" (Test-Path (RepoFile "docs/spec.md"))
}

# ------------------------------------------------------------------- red-team
function Get-TrackedFiles {
    Push-Location $Root
    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) { (& git ls-files) | Where-Object { $_ } }
        else { Get-ChildItem -Recurse -File | ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\','/') } }
    } finally { Pop-Location }
}

function Invoke-RedTeam {
    Write-Host "`n=== suite: red-team ===" -ForegroundColor Cyan

    # secret regexes (high-confidence live-key shapes)
    $secretRx = @(
        [regex]'sk-[A-Za-z0-9_\-]{20,}',
        [regex]'ghp_[A-Za-z0-9]{20,}',
        [regex]'AKIA[0-9A-Z]{16}',
        [regex]'xox[baprs]-[A-Za-z0-9-]{10,}',
        [regex]'-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
    )
    $tracked = Get-TrackedFiles | Where-Object { $_ -notmatch '^tests/' -and $_ -notmatch '^\.venv/' }
    $leaks = @()
    foreach ($rel in $tracked) {
        $p = RepoFile $rel
        if (-not (Test-Path $p)) { continue }
        $txt = try { [System.IO.File]::ReadAllText($p) } catch { "" }
        foreach ($rx in $secretRx) { if ($rx.IsMatch($txt)) { $leaks += "$rel ~ $($rx.ToString())" } }
    }
    Check "red-team" "no secret patterns in tracked files" ($leaks.Count -eq 0) ($leaks -join " | ")

    # config: api_key must be os.environ, never a literal
    $cfg = ReadText "config/litellm_config.yaml"
    $cfgLiteral = $cfg -and ($cfg -match "api_key:\s*(?!os\.environ/)\S")
    Check "red-team" "config has no literal api_key" (-not $cfgLiteral)

    # profiles carry no key material
    $badProfile = @()
    foreach ($pf in (Get-ChildItem (RepoFile "profiles") -Filter *.json -ErrorAction SilentlyContinue)) {
        $t = [System.IO.File]::ReadAllText($pf.FullName)
        if ($t -match 'sk-[A-Za-z0-9_\-]{20,}' -or $t -match '(?i)"?api[_-]?key"?\s*:') { $badProfile += $pf.Name }
    }
    Check "red-team" "profiles contain no key material" ($badProfile.Count -eq 0) ($badProfile -join ", ")

    # ANTHROPIC_AUTH_TOKEN is the dummy wherever it is set
    $authBad = @()
    foreach ($f in @("start-claude.ps1","start-claude.sh","profiles/fpt.json")) {
        $t = ReadText $f; if (-not $t) { continue }
        foreach ($mm in [regex]::Matches($t, 'ANTHROPIC_AUTH_TOKEN["'']?\s*[:=]\s*["'']([^"'']+)["'']')) {
            if ($mm.Groups[1].Value -ne 'litellm-proxy') { $authBad += "$f=$($mm.Groups[1].Value)" }
        }
    }
    Check "red-team" "ANTHROPIC_AUTH_TOKEN is dummy only" ($authBad.Count -eq 0) ($authBad -join ", ")

    # B-02 regression: a key must never be interpolated into a command string.
    # The proxy child inherits the key from the environment instead.
    $keyInterp = @()
    $badPatterns = @(("LLM_API_KEY = '" + '$'), ("KeyEnv) = '" + '$'))
    foreach ($f in $productPs1) {
        $t = ReadText $f; if (-not $t) { continue }
        foreach ($bp in $badPatterns) { if ($t.Contains($bp)) { $keyInterp += "$f ~ $bp" } }
    }
    Check "red-team" "key never interpolated into a command string" ($keyInterp.Count -eq 0) ($keyInterp -join " | ")

    # product scripts must not pipe remote content into a shell
    $remoteExec = @()
    foreach ($f in ($productPs1 + $productSh)) {
        $t = ReadText $f; if (-not $t) { continue }
        if ($t -match '(?i)(curl|wget|irm|invoke-restmethod)[^\r\n|]*\|\s*(bash|sh|iex|invoke-expression)') { $remoteExec += $f }
        if ($t -match '(?i)iex\s*\(\s*(irm|invoke-restmethod|new-object\s+net\.webclient)') { $remoteExec += $f }
    }
    Check "red-team" "no remote-to-shell in product scripts" (($remoteExec | Select-Object -Unique).Count -eq 0) (($remoteExec | Select-Object -Unique) -join ", ")
}

# --------------------------------------------------------------------- run
if ($Suite -in @("all","policy-ci")) { Invoke-PolicyCI }
if ($Suite -in @("all","red-team"))  { Invoke-RedTeam }

Write-Host "`n=== summary ===" -ForegroundColor Cyan
$fail = 0
foreach ($grp in ($results | Group-Object Suite)) {
    $p = @($grp.Group | Where-Object Ok).Count
    $f = @($grp.Group | Where-Object { -not $_.Ok }).Count
    $fail += $f
    $col = if ($f -eq 0) { "Green" } else { "Red" }
    Write-Host ("  {0,-10} {1} passed, {2} failed" -f $grp.Name, $p, $f) -ForegroundColor $col
}
$total = $results.Count
$totCol = if ($fail -eq 0) { "Green" } else { "Red" }
Write-Host ("  TOTAL      {0}/{1} passed" -f ($total - $fail), $total) -ForegroundColor $totCol
if ($fail -eq 0) { Write-Host "`nALL GREEN" -ForegroundColor Green } else { Write-Host "`n$fail CHECK(S) FAILED" -ForegroundColor Red }
exit $fail
