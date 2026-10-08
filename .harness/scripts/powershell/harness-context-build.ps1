#!/usr/bin/env pwsh
<#
.SYNOPSIS
  H1 Context Harness -- build/refresh the pipeline-context pointer store.
.DESCRIPTION
  Turns the declarative casan-policies `context` section into a real, maintained
  artifact: .harness/context/pipeline-context.yaml -- a pointer store so a
  sub-agent can DISCOVER the SRS/spec paths, tech stack and artifact locations
  from ONE file instead of re-scanning the repo (the H1 "câu hỏi chốt").

  Refreshes only when missing or older than staleness_ttl_minutes (C2: reads the
  policy; never hardcodes). Called from harness-session-start (SessionStart hook)
  so every session begins with fresh context. Ships in the bundle.
.NOTES
  Defense-in-depth / dev-ergonomics; safe to run any time.
#>
param([string]$HarnessRoot = "")

if (-not $HarnessRoot) {
    $HarnessRoot = $env:HARNESS_ROOT
    if (-not $HarnessRoot) { $HarnessRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path }
}

$Policy = "$HarnessRoot\.harness\control\casan-policies.yaml"
# Defaults mirror casan-policies.yaml `context`.
$Store = "$HarnessRoot\.harness\context\pipeline-context.yaml"
$TtlMin = 240
$RequiredKeys = @("srs_path", "spec_path", "tech_stack", "artifact_paths")

# Read policy (tiny hand parse -- avoid a YAML dep in the hook path).
if (Test-Path $Policy) {
    try {
        $raw = Get-Content -Path $Policy -Raw -Encoding utf8
        if ($raw -match 'pointer_store:\s*"?([^"\r\n]+)"?') { $Store = "$HarnessRoot\" + ($matches[1].Trim() -replace '/', '\') }
        if ($raw -match 'staleness_ttl_minutes:\s*(\d+)') { $TtlMin = [int]$matches[1] }
    } catch { }
}

# Staleness check -- skip rebuild if fresh.
if (Test-Path $Store) {
    $ageMin = ((Get-Date) - (Get-Item $Store).LastWriteTime).TotalMinutes
    # Floor, not Round: bash has no floats and prints integer-divided minutes, so
    # rounding here made the two shells report different ages for the same file.
    if ($ageMin -lt $TtlMin) {
        Write-Output "[context] pipeline-context.yaml fresh ($([math]::Floor($ageMin))m < ${TtlMin}m) -- kept"
        exit 0
    }
}

$HarnessRoot = $HarnessRoot.TrimEnd('\', '/')

# Read a YAML string-list under `<key>:` from the policy (C2 - discovery lives in
# config). Naive on purpose: the hook path must not need a YAML dependency. The
# key line may carry a trailing comment.
function Get-YamlList([string]$key) {
    if (-not (Test-Path $Policy)) { return @() }
    $out = @(); $inBlock = $false
    foreach ($line in Get-Content $Policy -Encoding utf8) {
        if ($line -match ("^\s*" + [regex]::Escape($key) + ":\s*(#.*)?$")) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '^\s*-\s*(.+?)\s*$') {
                $v = $matches[1] -replace '\s+#.*$', ''
                $v = $v.Trim().Trim('"').Trim("'")
                if ($v) { $out += $v }
            } elseif ($line -match '\S') { break }
        }
    }
    return $out
}

function Sort-Ordinal([string[]]$items) {
    $a = @($items)
    if ($a.Count -gt 1) { [Array]::Sort($a, [System.StringComparer]::Ordinal) }
    return $a
}

# Scan exclusions, read from config (C2). The fallback is the shipped default
# rather than "exclude nothing": casan-policies.yaml is project-owned in
# bundle-ownership.yaml, so an upgraded project keeps its old copy and never
# receives this key -- and with an empty list the scan would start indexing
# node_modules and .git.
$ExcludeGlobs = Get-YamlList "exclude_globs"
if (-not $ExcludeGlobs) {
    $ExcludeGlobs = @("node_modules", ".git", "dist", "build", ".harness", ".claude/worktrees", "vendor", ".venv")
}

# An entry matches a path SEGMENT. Wrapping both sides in '/' is what keeps
# "build" from swallowing "rebuild-notes.md"; -like keeps the '*'/'?' wildcards
# and the case-insensitivity of the regex this replaced (the bash counterpart
# matches case-insensitively too, so the two shells agree on either filesystem).
function Test-Excluded([string]$rel) {
    $p = '/' + ($rel -replace '\\', '/') + '/'
    foreach ($e in $ExcludeGlobs) {
        $g = "$e".Trim().Trim('/')
        if (-not $g) { continue }
        if ($p -like "*/$g/*") { return $true }
    }
    return $false
}

# Deterministic pointer discovery: an entry with no wildcard is an exact path
# taken when present (canonical wins); a wildcard entry globs recursively and the
# matches are SORTED (ordinal, so it is stable across machines/locales).
function Find-First([string[]]$candidates) {
    foreach ($c in $candidates) {
        if ($c -match '[*?]') {
            $rel = Get-ChildItem -Path $HarnessRoot -Recurse -File -Filter $c -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($HarnessRoot.Length + 1) -replace '\\', '/' } |
                Where-Object { -not (Test-Excluded $_) }
            # @() is load-bearing: PowerShell unrolls a 1-element array on return,
            # so on EXACTLY ONE surviving match $rel became the string itself and
            # $rel[0] returned its first CHARACTER -- srs_path: "d". Silent and
            # wrong, and tighter exclusions make one match the normal case.
            $rel = @(Sort-Ordinal $rel)
            if ($rel.Count -gt 0) { return $rel[0] }
        } elseif (Test-Path (Join-Path $HarnessRoot $c)) {
            return ($c -replace '\\', '/')
        }
    }
    return ""
}

# --- Discover pointers (best-effort; empty string when absent) ---
$srsCand = Get-YamlList "srs_candidates"
if (-not $srsCand) { $srsCand = @("SRS*.md", "srs*.md", "*requirements*.md") }
$specCand = Get-YamlList "spec_candidates"
if (-not $specCand) { $specCand = @("*spec*.md", "SPEC*.md", "openapi*.y*ml") }
$srs = Find-First $srsCand
$spec = Find-First $specCand

# Tech stack detection from manifest files present at root/near-root.
# Look one level down as well as at the root.
#
# Root-only detection gives every MONOREPO the poison value ["unknown"], because
# its manifests live in subdirectories -- this repo's own are at
# portal/backend/requirements.txt and portal/admin-web/package.json. That value
# fails H1-4 permanently and silently, and because this file is rebuilt on every
# SessionStart, filling it in by hand does not survive the next session. The
# toolkit shipped that state to itself while telling eleven projects to fix
# theirs.
#
# Bounded to depth 2 deliberately: deep enough for the standard
# apps/<name>/ or <service>/ layout, shallow enough that it never walks
# node_modules or a vendored tree.
$MarkerStack = [ordered]@{
    "package.json"     = "node"
    "requirements.txt" = "python"
    "pyproject.toml"   = "python"
    "go.mod"           = "go"
    "pom.xml"          = "java"
    "Cargo.toml"       = "rust"
    "composer.json"    = "php"
}
$SkipDirs = @("node_modules", ".git", ".venv", "venv", "vendor", "dist", "build", "__pycache__", ".harness")

$searchDirs = @($HarnessRoot)
Get-ChildItem -Path $HarnessRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($SkipDirs -notcontains $_.Name -and -not $_.Name.StartsWith(".")) { $searchDirs += $_.FullName }
}

$stack = @()
foreach ($d in $searchDirs) {
    foreach ($marker in $MarkerStack.Keys) {
        if (Test-Path (Join-Path $d $marker)) { $stack += $MarkerStack[$marker] }
    }
    # One more level for the apps/<name>/ and packages/<name>/ shape, which puts
    # every manifest two directories down and is common enough that stopping at
    # one would leave the same silent failure in place for those repos.
    Get-ChildItem -Path $d -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($SkipDirs -notcontains $_.Name -and -not $_.Name.StartsWith(".")) {
            foreach ($marker in $MarkerStack.Keys) {
                if (Test-Path (Join-Path $_.FullName $marker)) { $stack += $MarkerStack[$marker] }
            }
        }
    }
}
if (-not $stack) { $stack = @("unknown") }
$stack = $stack | Select-Object -Unique

# Artifact dirs, resolved from config (C2). A glob match that is a directory
# contributes itself; a match that is a FILE contributes its parent dir -- that
# is what makes "*/__init__.py" name the Python package on layouts whose source
# dir is not called "src".
function Resolve-Dirs([string]$glob) {
    $out = @()
    $full = Join-Path $HarnessRoot $glob
    if ($glob -notmatch '[*?]') {
        # Exact path: take the directory ITSELF. Get-ChildItem on a directory
        # lists its children instead, and returns nothing for an empty dir.
        $it = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($it) {
            $p = if ($it.PSIsContainer) { $it.FullName } else { $it.DirectoryName }
            if ($p -and $p.Length -gt $HarnessRoot.Length) {
                $out += ($p.Substring($HarnessRoot.Length + 1) -replace '\\', '/')
            }
        }
    } else {
        foreach ($it in (Get-ChildItem -Path $full -Force -ErrorAction SilentlyContinue)) {
            $p = if ($it.PSIsContainer) { $it.FullName } else { $it.DirectoryName }
            if (-not $p -or $p.Length -le $HarnessRoot.Length) { continue }
            $out += ($p.Substring($HarnessRoot.Length + 1) -replace '\\', '/')
        }
    }
    return (Sort-Ordinal ($out | Select-Object -Unique))
}
$artGlobs = Get-YamlList "artifact_globs"
if (-not $artGlobs) { $artGlobs = @("docs", "tests", "contracts", ".harness") }
$srcGlobs = Get-YamlList "source_globs"
if (-not $srcGlobs) { $srcGlobs = @("src", "app", "lib", "*/__init__.py") }
$artifacts = @()
foreach ($g in @($srcGlobs) + @($artGlobs)) {
    foreach ($hit in (Resolve-Dirs $g)) {
        if ($artifacts -notcontains $hit) { $artifacts += $hit }
    }
}

# --- Write the pointer store (ASCII YAML -- avoid PS 5.1 mojibake) ---
$dir = Split-Path -Parent $Store
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$lines = @()
$lines += "# pipeline-context pointer store (H1) -- auto-built by harness-context-build."
$lines += "# Sub-agents read this to discover inputs WITHOUT re-scanning the repo."
$lines += "generated_at: `"$now`""
$lines += "srs_path: `"$srs`""
$lines += "spec_path: `"$spec`""
$lines += "tech_stack: [$(( $stack | ForEach-Object { '`"' + $_ + '`"' }) -join ', ')]"
$lines += "artifact_paths: [$(( $artifacts | ForEach-Object { '`"' + $_ + '`"' }) -join ', ')]"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Store, ($lines -join "`n") + "`n", $Utf8NoBom)

$missing = @()
if (-not $srs) { $missing += "srs_path" }
if (-not $spec) { $missing += "spec_path" }
Write-Output "[context] built pipeline-context.yaml (stack=$($stack -join '/'); artifacts=$($artifacts.Count))$(if ($missing) { ' missing: ' + ($missing -join ',') })"

# H1 RAG-lite -- (re)build the retrieval index over context sources (best-effort).
$Rag = "$HarnessRoot\.harness\scripts\lib\harness_rag.py"
if (Test-Path $Rag) {
    $py = (Get-Command python3 -ErrorAction SilentlyContinue); if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) { $env:HARNESS_ROOT = $HarnessRoot; try { & $py.Source $Rag index --root $HarnessRoot } catch { } }
}
exit 0
