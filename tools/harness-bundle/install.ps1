#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Harness Bundle installer (L5 -- distribution layer).
  Materializes a packed .bundle.json into a target project (byte-exact),
  after verifying its content hash -- the "npm install" analog. This is the
  governed evolution of harness-init: instead of hardcoded templates, it
  installs a named, versioned, hash-verified bundle.
.USAGE
  .\install.ps1 -BundleFile <x.bundle.json> -TargetDir <project dir> [-Force] [-MergeClaude]

  -MergeClaude  After installing, automatically merge CLAUDE.harness.md into
                CLAUDE.md of the target project.
                  * If CLAUDE.md does not exist: creates it from CLAUDE.harness.md.
                  * If CLAUDE.md exists but has no harness section: appends the
                    harness content with a <!-- harness:merged --> sentinel (safe
                    to re-run -- the sentinel prevents double-merging).
                  * If sentinel is already present: skips silently.
#>
param(
    [string]$BundleFile = "",
    [string]$TargetDir  = ".",
    [switch]$Force = $false,
    # Project the common governance text into every agent-guide file the project
    # uses (CLAUDE.md, AGENTS.md, .github/copilot-instructions.md, ... - the list
    # is data, see casan-policies.yaml governance.guide_targets). The old name is
    # kept so existing callers/scripts keep working.
    [Alias("MergeClaude")]
    [switch]$MergeGuides = $false,
    # Stamp the project's identity into contracts/project.yaml on install.
    [string]$ProjectName = "",
    [string]$ProjectDescription = "",
    # By default identity is only written when the file still carries the shipped
    # placeholder, so a project that named itself is never renamed behind its back.
    [switch]$ForceIdentity = $false,
    # Show exactly what an install WOULD do -- per file: WRITE / KEEP / SKIP /
    # MERGE-CONFLICT -- and write nothing. Every consuming team asked for this:
    # they wanted to see the blast radius before committing to it.
    [switch]$DryRun = $false,
    # Copy the shipped CI templates into .github/. Opt-in: dropping workflow
    # files into a repo changes what runs on every push, which is not something
    # an install should do behind the operator's back.
    [switch]$WithCiGates = $false
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Sha256HexOf([byte[]]$Bytes) {
    $s = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($s.ComputeHash($Bytes)) -replace '-', '').ToLower()
}

# A receipt hash that cannot honestly be stated. The hash of an EMPTY file is a real
# hash (of nothing) and recording it makes every empty file look verified.
$Unknown = "unknown"
function Get-HashOrUnknown([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $Unknown }
    return (Sha256HexOf $Bytes)
}

# BOM and CRLF stripped -- what an EOL/BOM-only difference (core.autocrlf checkout,
# a Windows editor) must not count as a change. install.sh and harness-verify.* do
# exactly the same. Latin-1 maps bytes 1:1, so the round trip is byte-exact.
function ConvertTo-NormBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return ,([byte[]]@()) }
    $start = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $start = 3 }
    $lat = [System.Text.Encoding]::GetEncoding(28591)
    $text = $lat.GetString($Bytes, $start, $Bytes.Length - $start)
    return ,($lat.GetBytes($text.Replace("`r`n", "`n")))
}

# CRLF -> LF only, BOM KEPT. The receipt hashes the SHIPPED bytes: LF, and for most
# .ps1 WITH a UTF-8 BOM. A CRLF checkout of such a file (core.autocrlf, or the managed
# .gitattributes `*.ps1 text eol=crlf`) is BOM+CRLF, and ConvertTo-NormBytes turns it
# into a form the receipt never held. Before 1.8.11 only that form was compared, so an
# update called every such file hand-edited and left a .new beside it (B-77).
function ConvertTo-LfBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return ,([byte[]]@()) }
    $lat = [System.Text.Encoding]::GetEncoding(28591)
    return ,($lat.GetBytes($lat.GetString($Bytes).Replace("`r`n", "`n")))
}

function Test-BytesEqual([byte[]]$A, [byte[]]$B) {
    if ($null -eq $A) { $A = [byte[]]@() }
    if ($null -eq $B) { $B = [byte[]]@() }
    return [System.Linq.Enumerable]::SequenceEqual($A, $B)
}

# --- Auto-find newest bundle if not specified ---
if (-not $BundleFile) {
    $found = Get-ChildItem -Recurse -Filter "*.bundle.json" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { throw "No .bundle.json found. Specify -BundleFile <path-or-url>." }
    $BundleFile = $found.FullName
    Write-Output "[install] Auto-selected bundle: $BundleFile"
}

# --- Download if URL ---
$TempDownload = $null
if ($BundleFile -match '^https?://') {
    $TempDownload = [System.IO.Path]::GetTempFileName() + ".bundle.json"
    Write-Output "[install] Downloading bundle from $BundleFile ..."
    Invoke-WebRequest -Uri $BundleFile -OutFile $TempDownload -UseBasicParsing
    $BundleFile = $TempDownload
}

if (-not (Test-Path $BundleFile)) { throw "Bundle file not found: $BundleFile" }
$bundle = Get-Content -Path $BundleFile -Raw -Encoding utf8 | ConvertFrom-Json

# --- Verify content hash before writing anything (fail-closed integrity) ---
$hashInput = ($bundle.files | ForEach-Object { "$($_.path):$($_.b64)" }) -join "`n"
$sha = [System.Security.Cryptography.SHA256]::Create()
$computed = ([BitConverter]::ToString($sha.ComputeHash($Utf8NoBom.GetBytes($hashInput))) -replace '-', '').ToLower()
if ($computed -ne $bundle.content_hash) {
    throw "Bundle integrity check FAILED: computed $computed != declared $($bundle.content_hash)"
}

Write-Output "[install] $($bundle.name) v$($bundle.version) ($($bundle.file_count) files) -> $TargetDir"
if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }

# Files the project owns: never overwritten once they exist, not even with
# -Force, because they carry per-project decisions. When the shipped copy has
# moved on, drop a `<file>.new` beside it so new keys can be adopted on purpose.
$preserve = @()
if ($bundle.PSObject.Properties.Name -contains 'preserve' -and $bundle.preserve) { $preserve = @($bundle.preserve) }

# Shared by the payload parse and the installer-side fallback below. Returns the
# four rule collections and prints nothing -- a Write-Output in here would join
# the return value (the push-telemetry.ps1 lesson).
function Read-OwnershipRules([string]$Text) {
    $r = @{ Owned = @(); Globs = @(); Keyed = @{}; Merge = @{}; Hook = @{} }
    $section = ''
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^([a-z_]+):\s*$') { $section = $matches[1]; continue }
        if ($line -match '^[a-z_]+:') { $section = ''; continue }
        if ($section -eq 'project_owned' -and $line -match '^\s+-\s*"?([^"]+?)"?\s*$') { $r.Owned += $matches[1] }
        if ($section -eq 'project_owned_globs' -and $line -match '^\s+-\s*"?([^"]+?)"?\s*$') { $r.Globs += $matches[1] }
        if ($section -eq 'keyed_lists' -and $line -match '^\s+"([^"]+)":\s*"([^"]+)"') { $r.Keyed[$matches[1]] = $matches[2] }
        if ($section -eq 'merge_json_maps' -and $line -match '^\s+"([^"]+)":\s*"([^"]+)"') { $r.Merge[$matches[1]] = $matches[2] }
        if ($section -eq 'merge_hook_settings' -and $line -match '^\s+"([^"]+)":\s*"([^"]+)"') { $r.Hook[$matches[1]] = $matches[2] }
    }
    return $r
}

# --- Ownership rules (C2): read from the bundle's OWN payload, before anything is
# written, so the rules that govern this install are the ones this bundle shipped
# -- not whatever an older copy left on disk. Absent file = fall back to
# bundle.yaml's `preserve` alone, i.e. exactly the previous behaviour.
$ownGlobs = @(); $keyedLists = @{}; $mergeMaps = @{}; $hookSettings = @{}
$ownEntry = $bundle.files | Where-Object { $_.path -eq '.harness/control/bundle-ownership.yaml' } | Select-Object -First 1
if ($ownEntry) {
    try {
        $rules = Read-OwnershipRules ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ownEntry.b64)))
        $preserve += $rules.Owned; $ownGlobs += $rules.Globs
        $keyedLists = $rules.Keyed; $mergeMaps = $rules.Merge; $hookSettings = $rules.Hook
        $preserve = @($preserve | Select-Object -Unique)
    } catch {
        Write-Output "[own] WARNING: bundle-ownership.yaml unreadable ($($_.Exception.Message)); falling back to preserve list only"
    }
}

# A bundle packed before a rule existed must not reopen the loss that rule
# prevents: v1.6.0 ships no merge_json_maps, so governed by its payload alone it
# would still overwrite tool-registry.json -- the exact defect. So the rules
# that travel BESIDE this installer (../../.harness/control/, in this repo and
# in an installed project alike) are unioned in. A union can only protect more
# than the bundle asked, never less, and the bundle stays authoritative wherever
# both copies define the same path, so a future bundle can still re-scope a rule
# on purpose. No file there is the standalone-installer case and means "bundle
# rules only" -- the previous behaviour, silently.
$installerRules = $null
try { $installerRules = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ".harness\control\bundle-ownership.yaml" } catch { }
if ($installerRules -and (Test-Path $installerRules)) {
    try {
        $mine = Read-OwnershipRules ([System.IO.File]::ReadAllText($installerRules, $Utf8NoBom))
        $newer = @()
        foreach ($p in $mine.Owned) { if ($preserve -notcontains $p) { $preserve += $p; $newer += "project_owned:$p" } }
        foreach ($g in $mine.Globs) { if ($ownGlobs -notcontains $g) { $ownGlobs += $g; $newer += "project_owned_globs:$g" } }
        foreach ($k in (@($mine.Keyed.Keys) | Sort-Object)) { if (-not $keyedLists.ContainsKey($k)) { $keyedLists[$k] = $mine.Keyed[$k]; $newer += "keyed_lists:$k" } }
        foreach ($k in (@($mine.Merge.Keys) | Sort-Object)) { if (-not $mergeMaps.ContainsKey($k)) { $mergeMaps[$k] = $mine.Merge[$k]; $newer += "merge_json_maps:$k" } }
        foreach ($k in (@($mine.Hook.Keys) | Sort-Object)) { if (-not $hookSettings.ContainsKey($k)) { $hookSettings[$k] = $mine.Hook[$k]; $newer += "merge_hook_settings:$k" } }
        if ($newer.Count -gt 0) {
            Write-Output "[own] this bundle predates $($newer.Count) ownership rule(s); applied from the installer's copy: $($newer -join ', ')"
        }
    } catch {
        Write-Output "[own] WARNING: installer-side bundle-ownership.yaml unreadable ($($_.Exception.Message)); using the bundle's own rules only"
    }
}

# --- Tamper detection (C9-adjacent): the PREVIOUS install's receipt already
# records a sha256 per shipped file. Comparing it to what is on disk now answers
# the question `preserve` never could -- "did the project hand-edit a file the
# bundle owns?" Overwriting that silently is how four separate teams lost work.
$prevHashes = @{}     # path -> last INSTALLED hash (the baseline a hand edit is measured against)
$prevShip   = @{}     # path -> hash of the shipped bytes the last run carried
$prevState  = @{}     # path -> state the last run recorded ("" for receipts older than states)
$prevReceipt = Join-Path $TargetDir ".harness\.bundle-manifest.json"
if (Test-Path $prevReceipt) {
    try {
        $pr = Get-Content -Path $prevReceipt -Raw -Encoding utf8 | ConvertFrom-Json
        # Prefer installed_sha256 -- what the LAST install left on disk. Fall back
        # to sha256 (shipped bytes) only for receipts written before that field
        # existed, where it is the best baseline available. "unknown" is the
        # receipt's way of saying "no honest hash" and is no baseline at all.
        foreach ($e in @($pr.files)) {
            if ($e.path) {
                $h = if ($e.PSObject.Properties.Name -contains 'installed_sha256' -and $e.installed_sha256) { "$($e.installed_sha256)" } else { "$($e.sha256)" }
                if ($h -eq $Unknown) { $h = "" }
                $prevHashes[$e.path] = $h
                $sh = "$($e.sha256)"; if ($sh -eq $Unknown) { $sh = "" }
                $prevShip[$e.path] = $sh
                $prevState[$e.path] = if ($e.PSObject.Properties.Name -contains 'state' -and $e.state) { "$($e.state)" } else { "" }
            }
        }
    } catch { }   # unreadable receipt just means "no baseline" -- never fatal
}

# What each file ended as, for the receipt: path -> @{ State; Base }. A receipt that
# only said "version X" while files were skipped, kept or left in conflict made the
# project look fully on X (24hHotnewsAI: receipt 1.8.1, scripts older). State is
# per file, and the hash of a file this run did NOT install is never taken as the
# new baseline -- see the receipt below.
$outcome = @{}
$unchanged = 0

# A `<file>.new` is the installer's own marker for "a shipped copy you have not
# adopted". Once the file matches the shipped copy it is stale, and leaving it
# makes a resolved conflict look unresolved.
function Remove-StaleNew([string]$Dest, [string]$Rel) {
    if (Test-Path "$Dest.new") {
        if (-not $DryRun) { Remove-Item -LiteralPath "$Dest.new" -Force }
        # Write-Host, not Write-Output: inside a function Write-Output joins the
        # return value of whoever calls it (policy-ci ps:no-write-output-in-function).
        Write-Host "  [CLEAN] $Rel.new (stale: the file now matches the shipped copy)"
    }
}

# The branch a generated workflow should trigger on: the REMOTE's default, asked
# of every remote (a repo may have no `origin` -- one here has `private`/`public`),
# falling back to the checked-out branch only when there is no remote to ask.
# Using the current checkout instead would pin CI to whatever feature branch the
# install happened to run from: it fires once, then never again once that branch
# is gone. A dead gate reads as coverage, which is worse than no gate at all.
function Get-DefaultBranch([string]$Root) {
    # A namespaced name is a feature branch, not a default. refs/remotes/*/HEAD is
    # a LOCAL CACHE written at clone time -- one repo's pointed at a temporary
    # `claude/<generated-name>` branch while its real default was main -- so a
    # cached answer that looks like a feature branch is rejected outright.
    # Trusting it would pin CI to a branch that gets deleted, and a gate that
    # stops firing looks exactly like a gate that passes.
    $plausible = { param($b) $b -and $b -notmatch '/' -and $b -ne 'HEAD' }

    try {
        $remotes = @((& git -C $Root remote 2>$null) | Where-Object { $_ })

        # 1. Ask the server. Authoritative, and immune to a stale local cache.
        foreach ($r in $remotes) {
            $ls = (& git -C $Root ls-remote --symref $r HEAD 2>$null)
            if ($ls) {
                $m = [regex]::Match(($ls -join "`n"), 'ref:\s+refs/heads/(\S+)\s+HEAD')
                if ($m.Success -and (& $plausible $m.Groups[1].Value)) { return $m.Groups[1].Value }
            }
        }
        # 2. Local cache, only if it names something plausible.
        foreach ($r in $remotes) {
            $rh = (& git -C $Root symbolic-ref --quiet ("refs/remotes/" + $r + "/HEAD") 2>$null)
            if ($rh) {
                $b = ("$rh".Trim() -replace ('^refs/remotes/' + [regex]::Escape($r) + '/'), '')
                if (& $plausible $b) { return $b }
            }
        }
        # 3. A conventional default that actually exists on a remote.
        foreach ($cand in @("main", "master", "develop", "trunk")) {
            foreach ($r in $remotes) {
                if (& git -C $Root rev-parse --verify --quiet ("refs/remotes/" + $r + "/" + $cand) 2>$null) { return $cand }
            }
        }
        # 4. No remote to ask: the branch in hand is the only one there is.
        $b = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null)
        if (& $plausible $b) { return "$b".Trim() }
    } catch { }
    return "main"
}

function Test-OwnedGlob([string]$Path, [string[]]$Globs) {
    foreach ($g in $Globs) {
        # Match the full relative path AND the bare filename, so a convention like
        # "project-*" or "*.local.*" applies at any depth without the rule author
        # having to spell out a directory prefix.
        if ($Path -like $g) { return $true }
        if ((Split-Path -Leaf $Path) -like $g) { return $true }
    }
    return $false
}

# Item keys of a keyed YAML list, by line scan. No YAML module exists on PS 5.1,
# and this only has to recognize the shape the bundle itself ships: a top-level
# `<list>:` followed by `  - <key>: value` items.
function Get-ListKeys([string]$Text, [string]$ListKey, [string]$ItemKey) {
    $keys = @(); $inList = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match "^$([regex]::Escape($ListKey)):\s*$") { $inList = $true; continue }
        if ($inList -and $line -match '^[A-Za-z0-9_]+:') { $inList = $false; continue }
        if ($inList -and $line -match "^\s+-\s+$([regex]::Escape($ItemKey)):\s*`"?([^`"#]+?)`"?\s*$") {
            $keys += $matches[1].Trim()
        }
    }
    return $keys
}

# --- JSON writer used by the merge below --------------------------------------
# Emits byte-for-byte what python's json.dumps(obj, indent=2, ensure_ascii=False)
# emits, because install.sh does the same merge in python. C7 parity has to hold
# at the BYTE level here: the merged file is re-hashed into the install receipt,
# so two spellings of the same content would make the next run of the OTHER
# installer report a hand-edit that never happened. ConvertTo-Json cannot be used
# -- PS 5.1 indents with 4 spaces, doubles the space after ':' and escapes every
# non-ASCII char, none of which python does.
function ConvertTo-HarnessJsonString([string]$S) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $S.ToCharArray()) {
        $n = [int]$c
        if     ($c -eq '"')  { [void]$sb.Append('\"') }
        elseif ($c -eq '\')  { [void]$sb.Append('\\') }
        elseif ($n -eq 8)    { [void]$sb.Append('\b') }
        elseif ($n -eq 9)    { [void]$sb.Append('\t') }
        elseif ($n -eq 10)   { [void]$sb.Append('\n') }
        elseif ($n -eq 12)   { [void]$sb.Append('\f') }
        elseif ($n -eq 13)   { [void]$sb.Append('\r') }
        elseif ($n -lt 32)   { [void]$sb.Append(('\u{0:x4}' -f $n)) }
        else                 { [void]$sb.Append($c) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-HarnessJson($Value, [int]$Indent = 0) {
    $pad = ' ' * $Indent
    $pad2 = ' ' * ($Indent + 2)
    if ($null -eq $Value)   { return 'null' }
    if ($Value -is [bool])  { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-HarnessJsonString $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $parts = @()
        foreach ($k in $Value.Keys) {
            $parts += "$pad2$(ConvertTo-HarnessJsonString ([string]$k)): $(ConvertTo-HarnessJson $Value[$k] ($Indent + 2))"
        }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = @()
        foreach ($i in $items) { $parts += "$pad2$(ConvertTo-HarnessJson $i ($Indent + 2))" }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value)
}

# ConvertFrom-Json hands back PSCustomObject, which the writer above cannot walk
# in document order without this. Order matters: the merged file must come out
# identical on a re-run, or every install would look like a change.
function ConvertTo-OrderedTree($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-OrderedTree $p.Value }
        return $o
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Value.Keys)) { $o[[string]$k] = ConvertTo-OrderedTree $Value[$k] }
        return $o
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $a = @()
        foreach ($i in $Value) { $a += ,(ConvertTo-OrderedTree $i) }
        return ,$a
    }
    return $Value
}

# Field-level merge of a JSON object map (bundle-ownership.yaml merge_json_maps).
# Returns a result object and writes NOTHING to the output stream: a Write-Output
# inside a function joins the function's return value, and that exact mistake
# already shipped once in push-telemetry.ps1 (a status line serialized into a
# JSON field and the server 422'd the push). The caller prints; this only decides.
function Merge-JsonEntryMap {
    param([string]$DiskText, [string]$ShipText, [string]$MapKey)

    $fail = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why } }
    try { $diskObj = ConvertTo-OrderedTree ($DiskText | ConvertFrom-Json) }
    catch { return (& $fail "could not parse your copy as JSON") }
    try { $shipObj = ConvertTo-OrderedTree ($ShipText | ConvertFrom-Json) }
    catch { return (& $fail "could not parse the shipped copy as JSON") }
    if (-not ($diskObj -is [System.Collections.IDictionary])) { return (& $fail "could not parse your copy as JSON") }
    if (-not ($shipObj -is [System.Collections.IDictionary])) { return (& $fail "could not parse the shipped copy as JSON") }
    if (-not $shipObj.Contains($MapKey)) { return (& $fail "the shipped copy has no '$MapKey' object") }

    $shipMap = $shipObj[$MapKey]
    if (-not ($shipMap -is [System.Collections.IDictionary])) { return (& $fail "the shipped copy has no '$MapKey' object") }
    $diskMap = $null
    if ($diskObj.Contains($MapKey) -and ($diskObj[$MapKey] -is [System.Collections.IDictionary])) { $diskMap = $diskObj[$MapKey] }

    $addedNames = @(); $yours = @(); $overrides = @(); $extraTop = @()
    $updated = 0; $fields = 0; $entries = 0

    $mergedMap = [ordered]@{}
    foreach ($name in @($shipMap.Keys)) {
        $shipEntry = $shipMap[$name]
        if ($null -eq $diskMap -or -not $diskMap.Contains($name)) {
            $mergedMap[$name] = $shipEntry
            $addedNames += $name
            continue
        }
        $diskEntry = $diskMap[$name]
        if (-not ($shipEntry -is [System.Collections.IDictionary]) -or -not ($diskEntry -is [System.Collections.IDictionary])) {
            # Not an object on one side -- nothing to merge field-wise, bundle wins.
            $mergedMap[$name] = $shipEntry
            $updated++
            continue
        }
        $out = [ordered]@{}
        foreach ($k in @($shipEntry.Keys)) { $out[$k] = $shipEntry[$k] }
        $keptFields = 0
        foreach ($k in @($diskEntry.Keys)) {
            if (-not $shipEntry.Contains($k)) {
                # The whole point: a field the bundle has no opinion about.
                $out[$k] = $diskEntry[$k]
                $keptFields++
            } elseif ((ConvertTo-HarnessJson $diskEntry[$k]) -ne (ConvertTo-HarnessJson $shipEntry[$k])) {
                $overrides += "$name.$k"
            }
        }
        if ($keptFields -gt 0) { $fields += $keptFields; $entries++ }
        $mergedMap[$name] = $out
        $updated++
    }
    if ($null -ne $diskMap) {
        foreach ($name in @($diskMap.Keys)) {
            if (-not $shipMap.Contains($name)) { $mergedMap[$name] = $diskMap[$name]; $yours += $name }
        }
    }

    # Top level: the bundle owns its own keys (schema_version, generated_at...),
    # anything the project added beside them is theirs and rides along.
    $root = [ordered]@{}
    foreach ($k in @($shipObj.Keys)) {
        if ($k -eq $MapKey) { $root[$k] = $mergedMap } else { $root[$k] = $shipObj[$k] }
    }
    foreach ($k in @($diskObj.Keys)) {
        if (-not $shipObj.Contains($k)) { $root[$k] = $diskObj[$k]; $extraTop += $k }
    }

    return [pscustomobject]@{
        Ok = $true; Reason = ""
        Text = (ConvertTo-HarnessJson $root 0) + "`n"
        Added = $addedNames.Count; AddedNames = @($addedNames)
        Updated = $updated; Yours = @($yours); Overrides = @($overrides)
        Fields = $fields; Entries = $entries; ExtraTop = @($extraTop)
    }
}

# Identity of one hook matcher entry (bundle-ownership.yaml merge_hook_settings):
# the matcher STRING, "" when absent/null. $null marks a malformed (non-object)
# entry, which can only pair with an equally malformed shipped one -- -ceq keeps
# the comparison case-sensitive, matching python's == in install.sh.
function Get-HookMatcher($Entry) {
    if (-not ($Entry -is [System.Collections.IDictionary])) { return $null }
    if (-not $Entry.Contains('matcher') -or $null -eq $Entry['matcher']) { return "" }
    return [string]$Entry['matcher']
}

# Matcher-entry merge of a Claude Code settings file (bundle-ownership.yaml
# merge_hook_settings). `hooks` is {event: [ {matcher, hooks:[...]}, ... ]}, so
# neither the flat-map merge above nor the keyed-list conflict fits its shape.
# Shipped matcher entries update to the shipped version; entries and whole
# events only the project has survive; top-level keys the bundle ships stay the
# bundle's (a replaced project edit is NAMED by the caller); extra top-level
# keys ride along. Duplicate matchers pair by position -- the deterministic
# convention documented in bundle-ownership.yaml. Same contract as
# Merge-JsonEntryMap: returns a result object, prints nothing, and emits the
# byte-identical text install.sh's python emits.
function Merge-HookSettings {
    param([string]$DiskText, [string]$ShipText, [string]$HooksKey)

    $fail = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why } }
    try { $diskObj = ConvertTo-OrderedTree ($DiskText | ConvertFrom-Json) }
    catch { return (& $fail "could not parse your copy as JSON") }
    try { $shipObj = ConvertTo-OrderedTree ($ShipText | ConvertFrom-Json) }
    catch { return (& $fail "could not parse the shipped copy as JSON") }
    if (-not ($diskObj -is [System.Collections.IDictionary])) { return (& $fail "could not parse your copy as JSON") }
    if (-not ($shipObj -is [System.Collections.IDictionary])) { return (& $fail "could not parse the shipped copy as JSON") }
    if (-not $shipObj.Contains($HooksKey) -or -not ($shipObj[$HooksKey] -is [System.Collections.IDictionary])) {
        return (& $fail "the shipped copy has no '$HooksKey' object")
    }

    $shipHooks = $shipObj[$HooksKey]
    $diskHooks = $null
    if ($diskObj.Contains($HooksKey) -and ($diskObj[$HooksKey] -is [System.Collections.IDictionary])) { $diskHooks = $diskObj[$HooksKey] }

    $updated = 0; $added = @(); $yours = @(); $replaced = @(); $extraTop = @(); $topWins = @()

    $mergedHooks = [ordered]@{}
    foreach ($ev in @($shipHooks.Keys)) {
        $shipList = @($shipHooks[$ev])
        $diskList = $null
        if ($null -ne $diskHooks -and $diskHooks.Contains($ev) -and
            ($diskHooks[$ev] -is [System.Collections.IEnumerable]) -and -not ($diskHooks[$ev] -is [string]) -and
            -not ($diskHooks[$ev] -is [System.Collections.IDictionary])) {
            $diskList = @($diskHooks[$ev])
        }
        if ($null -eq $diskList) {
            # Event the project does not have (or holds malformed): shipped wins.
            $mergedHooks[$ev] = $shipList
            foreach ($se in $shipList) { $added += "$ev[$(Get-HookMatcher $se)]" }
            continue
        }
        $consumed = @($false) * $diskList.Count
        $out = @()
        foreach ($se in $shipList) {
            $sm = Get-HookMatcher $se
            $j = -1
            for ($i = 0; $i -lt $diskList.Count; $i++) {
                if (-not $consumed[$i] -and ($sm -ceq (Get-HookMatcher $diskList[$i]))) { $j = $i; break }
            }
            $out += ,$se
            if ($j -lt 0) {
                $added += "$ev[$sm]"
            } else {
                $consumed[$j] = $true
                $updated++
                if ((ConvertTo-HarnessJson $diskList[$j]) -cne (ConvertTo-HarnessJson $se)) { $replaced += "$ev[$sm]" }
            }
        }
        for ($i = 0; $i -lt $diskList.Count; $i++) {
            # The whole point: an entry only the project has.
            if (-not $consumed[$i]) { $out += ,$diskList[$i]; $yours += "$ev[$(Get-HookMatcher $diskList[$i])]" }
        }
        $mergedHooks[$ev] = $out
    }
    if ($null -ne $diskHooks) {
        foreach ($ev in @($diskHooks.Keys)) {
            if (-not $shipHooks.Contains($ev)) {
                $mergedHooks[$ev] = $diskHooks[$ev]
                foreach ($de in @($diskHooks[$ev])) { $yours += "$ev[$(Get-HookMatcher $de)]" }
            }
        }
    }

    # Top level: shipped keys are the bundle's (hooks replaced by the merge
    # above); keys only the project has ride along.
    $root = [ordered]@{}
    foreach ($k in @($shipObj.Keys)) {
        if ($k -ceq $HooksKey) { $root[$k] = $mergedHooks; continue }
        $root[$k] = $shipObj[$k]
        if ($diskObj.Contains($k) -and ((ConvertTo-HarnessJson $diskObj[$k]) -cne (ConvertTo-HarnessJson $shipObj[$k]))) { $topWins += $k }
    }
    foreach ($k in @($diskObj.Keys)) {
        if (-not $shipObj.Contains($k)) { $root[$k] = $diskObj[$k]; $extraTop += $k }
    }

    return [pscustomobject]@{
        Ok = $true; Reason = ""
        Text = (ConvertTo-HarnessJson $root 0) + "`n"
        Added = @($added); Updated = $updated; Yours = @($yours)
        Replaced = @($replaced); ExtraTop = @($extraTop); TopWins = @($topWins)
    }
}

function Resolve-BundleDest {
    <#
      Resolve a bundle-declared relative path INSIDE $TargetDir, or refuse.

      Destinations were built as `Join-Path $TargetDir ($f.path -replace '/','\')`
      with $f.path taken from the bundle. Join-Path does not contain anything:
      a '..' component walks out of the target, and an absolute path or a drive
      letter discards $TargetDir entirely. A bundle declaring
      "../../../Windows/System32/Tasks/harness" installed there.

      The content hash does not cover this. It proves the bundle was not
      altered after packing; it says nothing about whether what was packed is
      benign. A bundle is governance content fetched from elsewhere, so its
      paths are input, not fact.

      Throws rather than sanitising: quietly rewriting a traversing path
      installs a file the bundle author did not name, which is its own
      surprise. A bundle reaching outside the target is broken or hostile, and
      the operator should hear about it either way.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RelPath
    )
    if ([string]::IsNullOrWhiteSpace($RelPath)) {
        throw "Refusing bundle path (empty): '$RelPath'"
    }
    if ($RelPath -ne $RelPath.Trim()) {
        throw "Refusing bundle path (leading/trailing whitespace): '$RelPath'"
    }
    if ($RelPath -match '^[\\/]' -or $RelPath -match '^[A-Za-z]:') {
        throw "Refusing absolute bundle path: '$RelPath'"
    }
    $parts = $RelPath -split '[\\/]'
    foreach ($part in $parts) {
        if ($part -eq '..' -or $part -eq '') {
            throw "Refusing bundle path that escapes the target: '$RelPath'"
        }
    }
    $dest = Join-Path $Root ($parts -join '\')

    # Compare the resolved PARENT: the file need not exist yet, and a symlink
    # or junction planted at the destination is the trick being guarded against.
    $rootFull = [System.IO.Path]::GetFullPath($Root.TrimEnd('\') + '\')
    $parentDir = [System.IO.Path]::GetDirectoryName($dest)
    $parentFull = [System.IO.Path]::GetFullPath($parentDir.TrimEnd('\') + '\')
    if (-not $parentFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing bundle path that resolves outside the target: '$RelPath' -> $dest"
    }
    return $dest
}

$written = 0; $skipped = 0; $kept = 0; $merged = 0; $conflicts = @(); $merges = @()
foreach ($f in $bundle.files) {
    $dest = Resolve-BundleDest -Root $TargetDir -RelPath $f.path
    $bytes = [Convert]::FromBase64String($f.b64)
    $exists = Test-Path $dest
    $shipHash = Get-HashOrUnknown $bytes      # what the receipt calls `sha256`
    # What a file this run does NOT install carries into the receipt as its
    # baseline: the LAST installed hash, never the hash of what is on disk now.
    $carry = if ($prevHashes[$f.path]) { "$($prevHashes[$f.path])" } else { $Unknown }

    # 1) Project-owned, by exact path or by convention glob.
    if ($exists -and (($preserve -contains $f.path) -or (Test-OwnedGlob $f.path $ownGlobs))) {
        $same = $false
        try { $same = Test-BytesEqual ([System.IO.File]::ReadAllBytes($dest)) $bytes } catch { }
        if (-not $same) {
            if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
            Write-Output "  [KEEP]  $($f.path) (yours; shipped copy saved as $($f.path).new)"
            $outcome[$f.path] = @{ State = "kept"; Base = $carry }
        } else {
            Write-Output "  [KEEP]  $($f.path) (yours; identical to shipped)"
            Remove-StaleNew $dest $f.path
            $outcome[$f.path] = @{ State = "kept"; Base = $shipHash }
        }
        $kept++
        continue
    }

    if ($exists) {
        $diskBytes = $null
        try { $diskBytes = [System.IO.File]::ReadAllBytes($dest) } catch { }
        $diskHash = if ($null -ne $diskBytes -and $diskBytes.Length -gt 0) { Sha256HexOf $diskBytes } else { "" }
        $diskNorm = if ($null -ne $diskBytes -and $diskBytes.Length -gt 0) { Sha256HexOf (ConvertTo-NormBytes $diskBytes) } else { "" }
        $diskLf = if ($null -ne $diskBytes -and $diskBytes.Length -gt 0) { Sha256HexOf (ConvertTo-LfBytes $diskBytes) } else { "" }

        # 1b) Already what the bundle ships (byte-exact, or differing only in EOL/BOM
        # -- a core.autocrlf checkout). Nothing to write, nothing to decide, and
        # not a "skip": reporting it as skipped would make every re-run of a
        # current project look partial.
        if ($null -ne $diskBytes -and ((Test-BytesEqual $diskBytes $bytes) -or
                (Test-BytesEqual (ConvertTo-NormBytes $diskBytes) (ConvertTo-NormBytes $bytes)))) {
            Write-Output "  [SAME]  $($f.path)"
            Remove-StaleNew $dest $f.path
            $outcome[$f.path] = @{ State = "installed"; Base = $null }
            $unchanged++
            continue
        }

        # 2) A JSON object map the project may have EXTENDED -- extra FIELDS on
        # entries the bundle ships, and/or entries of its own. Overwriting the
        # whole file is what erased one project's contract/timeout annotations
        # across all 62 registry tools (see merge_json_maps in
        # bundle-ownership.yaml). Merge per entry, per field instead.
        # Runs with or WITHOUT -Force on purpose: the merge cannot lose a field
        # the bundle does not ship, and gating it behind -Force would leave a
        # plain install with a registry that never learns about new tools --
        # which C3 turns into "unknown tool, denied by default" at run time.
        if ($mergeMaps.ContainsKey($f.path) -and $diskBytes) {
            $mk = $mergeMaps[$f.path]
            $res = Merge-JsonEntryMap -DiskText ([System.Text.Encoding]::UTF8.GetString($diskBytes)) `
                                      -ShipText ([System.Text.Encoding]::UTF8.GetString($bytes)) `
                                      -MapKey $mk
            if ($res.Ok) {
                if (-not $DryRun) { [System.IO.File]::WriteAllText($dest, $res.Text, $Utf8NoBom) }
                Write-Output "  [MERGE] $($f.path) ($mk`: $($res.Added) added, $($res.Updated) updated, $(@($res.Yours).Count) yours kept; $($res.Fields) project field(s) preserved on $($res.Entries) entry(ies))"
                if (@($res.Yours).Count -gt 0)      { Write-Output "             kept yours: $(@($res.Yours) -join ', ')" }
                if (@($res.AddedNames).Count -gt 0) { Write-Output "             added by the bundle: $(@($res.AddedNames) -join ', ')" }
                if (@($res.ExtraTop).Count -gt 0)   { Write-Output "             kept your extra top-level key(s): $(@($res.ExtraTop) -join ', ')" }
                # Never silent: these are the only edits of theirs that did NOT
                # survive, so name every one (C10).
                if (@($res.Overrides).Count -gt 0)  { Write-Output "             bundle value wins on $(@($res.Overrides).Count) field(s) you had changed: $(@($res.Overrides) -join ', ')" }
                $merges += "$($f.path): $($res.Fields) project field(s) on $($res.Entries) entry(ies), $(@($res.Yours).Count) project-only entry(ies) kept"
                $merged++
                Remove-StaleNew $dest $f.path
                $outcome[$f.path] = @{ State = "installed"; Base = $null }
                continue
            }
            # Unparseable on either side, or the shipped copy lost the map: never
            # write a half-merged governance file. Say so and keep theirs.
            if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
            $msg = "$($f.path): $($res.Reason) -- not merged"
            Write-Output "  [CONFLICT] $msg"
            Write-Output "             kept yours; shipped copy is $($f.path).new"
            $conflicts += $msg
            $kept++
            $outcome[$f.path] = @{ State = "conflict"; Base = $carry }
            continue
        }

        # 2b) Claude Code settings: hooks is {event: [matcher entries]}, a shape
        # the flat-map merge above cannot address. Overwriting wholesale is how
        # a project's own PreToolUse hook vanished with zero warning -- lost
        # enforcement that nothing reported (see merge_hook_settings in
        # bundle-ownership.yaml). Shipped matcher entries update, the project's
        # own entries/events and extra top-level keys survive. Runs with or
        # WITHOUT -Force for the same reason as the map merge: it cannot drop a
        # project entry, and gating it would leave stale fleet hooks in place.
        if ($hookSettings.ContainsKey($f.path) -and $diskBytes) {
            $hk = $hookSettings[$f.path]
            $res = Merge-HookSettings -DiskText ([System.Text.Encoding]::UTF8.GetString($diskBytes)) `
                                      -ShipText ([System.Text.Encoding]::UTF8.GetString($bytes)) `
                                      -HooksKey $hk
            if ($res.Ok) {
                if (-not $DryRun) { [System.IO.File]::WriteAllText($dest, $res.Text, $Utf8NoBom) }
                Write-Output "  [MERGE] $($f.path) ($hk`: $(@($res.Added).Count) added, $($res.Updated) updated, $(@($res.Yours).Count) yours kept; $(@($res.ExtraTop).Count) extra top-level key(s) kept)"
                if (@($res.Yours).Count -gt 0)    { Write-Output "             kept your hook entry(ies): $(@($res.Yours) -join ', ')" }
                if (@($res.Added).Count -gt 0)    { Write-Output "             added by the bundle: $(@($res.Added) -join ', ')" }
                if (@($res.ExtraTop).Count -gt 0) { Write-Output "             kept your extra top-level key(s): $(@($res.ExtraTop) -join ', ')" }
                # Never silent: the next two lines name every project edit that
                # did NOT survive (C10).
                if (@($res.Replaced).Count -gt 0) { Write-Output "             bundle version replaces $(@($res.Replaced).Count) hook entry(ies) you had edited: $(@($res.Replaced) -join ', ')" }
                if (@($res.TopWins).Count -gt 0)  { Write-Output "             bundle value wins on top-level key(s) you had changed: $(@($res.TopWins) -join ', ') (hold local overrides in .claude/settings.local.json)" }
                $merges += "$($f.path): $(@($res.Yours).Count) project hook entry(ies) kept, $(@($res.ExtraTop).Count) extra top-level key(s) kept"
                $merged++
                Remove-StaleNew $dest $f.path
                $outcome[$f.path] = @{ State = "installed"; Base = $null }
                continue
            }
            # Unparseable, or the shipped copy lost its hooks object: never
            # write half-merged hook config -- a wrong guess here is silently
            # missing enforcement. Say so and keep theirs.
            if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
            $msg = "$($f.path): $($res.Reason) -- not merged"
            Write-Output "  [CONFLICT] $msg"
            Write-Output "             kept yours; shipped copy is $($f.path).new"
            $conflicts += $msg
            $kept++
            $outcome[$f.path] = @{ State = "conflict"; Base = $carry }
            continue
        }

        # 3) A keyed list the project may have EXTENDED. Overwriting is right for
        # the shipped entries and destructive for the project's own, so when the
        # project has entries the bundle does not ship, stop and name them.
        # Deliberately a conflict, not an auto-merge: guessing where to splice a
        # YAML item risks a broken pipeline that still validates (C10).
        if ($keyedLists.ContainsKey($f.path) -and $diskBytes) {
            $spec = $keyedLists[$f.path] -split ':', 2
            $mineText = [System.Text.Encoding]::UTF8.GetString($diskBytes)
            $shipText = [System.Text.Encoding]::UTF8.GetString($bytes)
            $mine = @(Get-ListKeys $mineText $spec[0] $spec[1])
            $ship = @(Get-ListKeys $shipText $spec[0] $spec[1])
            $extra = @($mine | Where-Object { $ship -notcontains $_ })
            if ($extra.Count -gt 0) {
                if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
                $msg = "$($f.path): your $($spec[0]) has $($extra.Count) entry(ies) the bundle does not ship -- $($extra -join ', ')"
                Write-Output "  [CONFLICT] $msg"
                Write-Output "             kept yours; shipped copy is $($f.path).new -- carry those entries over by hand"
                $conflicts += $msg
                $kept++
                $outcome[$f.path] = @{ State = "conflict"; Base = $carry }
                continue
            }
        }

        # 4) A bundle-owned file the project hand-edited since the last install.
        # Only claimable when a baseline exists; with no receipt we cannot tell an
        # edit from a first install, and guessing would either cry wolf or hide it.
        if ($prevHashes.ContainsKey($f.path) -and $diskHash -and $prevHashes[$f.path] -and
            $diskHash -ne $prevHashes[$f.path] -and $diskNorm -ne $prevHashes[$f.path] -and
            $diskLf -ne $prevHashes[$f.path]) {
            # Hand-edited. If the bundle has not moved on since the last run there is
            # nothing to adopt: keep the edit, no .new, no conflict. (Not when the
            # last run already left this file in conflict -- the receipt's shipped
            # hash then names the copy that was REFUSED, so "unchanged" would be
            # measured against the very bytes the edit is in conflict with.)
            if ($prevState[$f.path] -ne "conflict" -and $prevShip[$f.path] -and $prevShip[$f.path] -eq $shipHash) {
                Write-Output "  [KEEP]  $($f.path) (yours; edited since the last install, the bundle has not changed it)"
                $kept++
                $outcome[$f.path] = @{ State = "kept"; Base = $carry }
                continue
            }
            if (-not $DryRun) { [System.IO.File]::WriteAllBytes("$dest.new", $bytes) }
            $msg = "$($f.path): edited by hand since the last install (sha differs from the recorded baseline)"
            Write-Output "  [CONFLICT] $msg"
            Write-Output "             kept yours; shipped copy is $($f.path).new"
            $conflicts += $msg
            $kept++
            $outcome[$f.path] = @{ State = "conflict"; Base = $carry }
            continue
        }

        if (-not $Force) {
            Write-Output "  [SKIP] $($f.path) (exists; use -Force to overwrite)"
            $skipped++
            $outcome[$f.path] = @{ State = "skipped"; Base = $carry }
            continue
        }
    }

    if ($DryRun) {
        Write-Output "  [WRITE] $($f.path)"
    } else {
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($dest, $bytes)
        Write-Output "  [WRITE] $($f.path)"
        Remove-StaleNew $dest $f.path
    }
    $outcome[$f.path] = @{ State = "installed"; Base = $null }
    $written++
}

# --- Summary. Conflicts are listed again, by name: a count alone reads as "all
# fine" and the whole point of this pass is that some files were NOT updated.
Write-Output ""
Write-Output "[summary] written=$written  merged=$merged  kept=$kept  skipped=$skipped  conflicted=$($conflicts.Count)  unchanged=$unchanged"
if ($merges.Count -gt 0) {
    Write-Output "[summary] merged in place -- your fields survived:"
    foreach ($m in $merges) { Write-Output "  - $m" }
}
if ($conflicts.Count -gt 0) {
    Write-Output "[summary] NOT updated -- resolve these by hand:"
    foreach ($c in $conflicts) { Write-Output "  - $c" }
}
if ($DryRun) {
    Write-Output "[summary] DRY RUN -- nothing was written. Re-run without -DryRun to apply."
    if ($TempDownload -and (Test-Path $TempDownload)) { Remove-Item $TempDownload -Force }
    exit 0
}

# --- Install receipt: what this run did to EACH file, not just which bundle it came
# from. `version` and `content_hash` name the bundle this run was driven by; they
# are not a claim that every file in it landed -- `status` and each file's `state`
# are. (A receipt that said only "version X" while files were skipped or left in
# conflict is how 24hHotnewsAI read 1.8.1 over scripts that were older.)
#
#   installed  the file on disk is what this run put there (written, merged, or
#              already identical) -- `installed_sha256` is its hash
#   kept       project-owned, or hand-edited while the bundle did not change it
#   conflict   hand-edited AND the bundle changed it: yours kept, shipped copy in
#              <file>.new
#   skipped    exists and no -Force
# For every state but "installed", `installed_sha256` is the baseline CARRIED from
# the previous receipt ("unknown" when there is none) -- never the hash of the
# bytes on disk, which would turn the next run's "you edited this" into "you did
# not". `sha256` keeps its meaning (the shipped bytes; the uninstaller reads it).
$counts = [ordered]@{ installed = 0; kept = 0; conflict = 0; skipped = 0 }
$manifestFiles = foreach ($f in $bundle.files) {
    $bytes = [Convert]::FromBase64String($f.b64)
    $o = $outcome[$f.path]
    $counts[$o.State] = [int]$counts[$o.State] + 1
    $base = $o.Base
    if ($o.State -eq "installed") {
        $dst = Resolve-BundleDest -Root $TargetDir -RelPath $f.path
        $base = Get-HashOrUnknown ([System.IO.File]::ReadAllBytes($dst))
    }
    [ordered]@{ path = $f.path; sha256 = (Get-HashOrUnknown $bytes); installed_sha256 = "$base"; state = $o.State }
}
$receiptStatus = if ($counts["conflict"] -gt 0 -or $counts["skipped"] -gt 0) { "partial" } else { "complete" }
$receiptDir = Join-Path $TargetDir ".harness"
if (-not (Test-Path $receiptDir)) { New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null }
$receipt = [ordered]@{
    name         = $bundle.name
    version      = $bundle.version
    content_hash = $bundle.content_hash
    installed_at = (Get-Date -Format 'o')
    status       = $receiptStatus
    counts       = $counts
    # Recorded so a maintainer can SEE which files this install treats as
    # project-owned, instead of having to read the installer to find out.
    preserve     = @($preserve)
    files        = @($manifestFiles)
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $receiptDir ".bundle-manifest.json"), $receipt, $Utf8NoBom)
if ($receiptStatus -eq "partial") {
    Write-Output "[summary] receipt status: PARTIAL -- $($counts['conflict']) conflict(s), $($counts['skipped']) skipped: the receipt records each file's state, it does not claim v$($bundle.version) is fully applied."
}

Write-Output "[install] done: $written written, $merged merged, $skipped skipped, $kept kept (project-owned). Integrity OK ($($bundle.content_hash))."

# --- Exec bit for shipped .sh files (C7 parity meets NTFS). Windows has no
# POSIX exec bit, so a commit made from here ships every .sh as mode 100644 and
# the first run on Linux prod dies with "Permission denied". The bit that
# PROPAGATES is the one in the git INDEX: update-index --chmod=+x records
# 100755 regardless of the filesystem, and --add covers a first install where
# the files are not yet tracked (with core.filemode=false, a later `git add`
# keeps the recorded index mode instead of resetting it -- so the bit survives
# into the commit). chmod itself is meaningless on NTFS; install.sh owns the
# filesystem half. Best-effort: no git / not a work tree is reported, never
# fatal -- but it IS reported, because the failure mode is silent (C10).
$shOnDisk = @($bundle.files | ForEach-Object { $_.path } |
              Where-Object { $_ -like '*.sh' -and (Test-Path (Join-Path $TargetDir ($_ -replace '/', '\'))) })
if ($shOnDisk.Count -gt 0) {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    # Native git chats on stderr (CRLF warnings, "fatal: not a git repository")
    # and PS 5.1 under ErrorActionPreference=Stop turns a REDIRECTED stderr line
    # into a terminating error AFTER git already ran -- which counted every
    # successful stamp as a failure on the first test of this block. Drop to
    # Continue around the git calls so stderr is data, and judge by exit code.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $inTree = ""
    if ($gitCmd) { try { $inTree = ("$(& git -C $TargetDir rev-parse --is-inside-work-tree 2>$null)").Trim() } catch { $inTree = "" } }
    if (-not $gitCmd) {
        Write-Output "[execbit] git not found -- index +x bit NOT set on $($shOnDisk.Count) .sh file(s); committed from Windows they will hit 'Permission denied' on Linux until re-installed there"
    } elseif ($inTree -ne 'true') {
        Write-Output "[execbit] target is not a git work tree -- nothing to stamp; the index +x bit applies once the project is under git"
    } else {
        $ok = 0; $failedSh = @()
        foreach ($rel in $shOnDisk) {
            try {
                & git -C $TargetDir update-index --add --chmod=+x -- $rel 2>$null
                if ($LASTEXITCODE -eq 0) { $ok++ } else { $failedSh += $rel }
            } catch { $failedSh += $rel }
        }
        Write-Output "[execbit] git index +x (mode 100755) recorded on $ok/$($shOnDisk.Count) .sh file(s) -- survives commits made from Windows"
        if ($failedSh.Count -gt 0) { Write-Output "[execbit] WARNING: could not stamp: $($failedSh -join ', ')" }
    }
    $ErrorActionPreference = $prevEap
}

# --- Portal-sync scaffold: create the two files a newcomer would otherwise
# have to hand-author, at the right location, ready to edit. NEVER overwrite an
# existing file (a real ingest key / configured project_id is preserved). These
# are exactly what push-telemetry.ps1 reads to sync telemetry to the Portal. ---
$syncDir = Join-Path $TargetDir ".harness"
if (-not (Test-Path $syncDir)) { New-Item -ItemType Directory -Path $syncDir -Force | Out-Null }

$syncJson = Join-Path $syncDir "portal-sync.json"
if (-not (Test-Path $syncJson)) {
    $syncTmpl = @"
{
  "_README": "Fill portal_url and project_id from your Control Portal (open the Project, then Settings, then Reveal ingest key). Next, paste the ingest key into portal-sync.key in THIS same .harness folder. This file is shared by every clone and is meant to be committed: it holds NO per-person or per-machine field (your email goes in .harness/local/checkout.json via set-member-email). Set pdp_enforce to true to make the PreToolUse hook consult the Portal PDP (H4 outbound allowlist, H5 approval, H3 release gate) -- leave false to keep it off. You may delete this _README line.",
  "portal_url": "https://YOUR-PORTAL-DOMAIN",
  "project_id": "PASTE-PROJECT-ID-HERE",
  "pdp_enforce": false
}
"@
    [System.IO.File]::WriteAllText($syncJson, $syncTmpl, $Utf8NoBom)
    Write-Output "[scaffold] created .harness\portal-sync.json  -> EDIT portal_url + project_id"
} else {
    Write-Output "[scaffold] .harness\portal-sync.json already exists -> kept"
}

$syncKey = Join-Path $syncDir "portal-sync.key"
if (-not (Test-Path $syncKey)) {
    [System.IO.File]::WriteAllText($syncKey, "", $Utf8NoBom)
    Write-Output "[scaffold] created empty .harness\portal-sync.key -> PASTE ingest key here (1 line)"
} else {
    Write-Output "[scaffold] .harness\portal-sync.key already exists -> kept"
}

# --- Buglist scaffold (M6): every project gets a living buglist.md at its root
# from the shipped template, so AI has a mandated place to log bugs (system OR
# AI-introduced). NEVER overwrite an existing buglist. ---
$bugFile = Join-Path $TargetDir "buglist.md"
$bugTmpl = Join-Path $syncDir "templates\buglist.md"
if (-not (Test-Path $bugFile)) {
    if (Test-Path $bugTmpl) {
        $t = (Get-Content $bugTmpl -Raw -Encoding utf8).Replace("<PROJECT>", (Split-Path $TargetDir -Leaf))
        [System.IO.File]::WriteAllText($bugFile, $t, $Utf8NoBom)
        Write-Output "[scaffold] created buglist.md (log every bug here -- see rule in the file)"
    }
} else {
    Write-Output "[scaffold] buglist.md already exists -> kept"
}

# --- Agent Pack scaffold (v1.6.0): the bundle ships the agents + skills; the
# project supplies only agent-config.yaml (its test runner). Auto-generate it by
# detecting the stack, so review->fix->test works from day one instead of the
# project having to know the file exists. NEVER overwrite an existing one (it is
# project-owned in bundle-ownership.yaml). Detection is best-effort: if we cannot
# tell the stack, write the annotated sample so a human fills it in rather than
# guessing a command that would fail silently.
$acFile = Join-Path $TargetDir ".harness\control\agent-config.yaml"
$acSample = Join-Path $syncDir "templates\agent-pack\agent-config.yaml.sample"
if (-not (Test-Path $acFile) -and (Test-Path $acSample)) {
    $unit = ""; $full = ""; $detected = ""
    $pkg = Join-Path $TargetDir "package.json"
    if (Test-Path $pkg) {
        $pkgTxt = Get-Content $pkg -Raw -Encoding utf8
        if ($pkgTxt -match '"vitest"') { $unit = "npx vitest related --run {files}"; $full = "npx vitest run"; $detected = "vitest" }
        elseif ($pkgTxt -match '"jest"') { $unit = "npx jest --findRelatedTests {files}"; $full = "npx jest"; $detected = "jest" }
    }
    if (-not $detected -and ((Test-Path (Join-Path $TargetDir "pyproject.toml")) -or (Test-Path (Join-Path $TargetDir "pytest.ini")))) {
        $unit = "pytest --testmon -q"; $full = "pytest -q"; $detected = "pytest"
    }
    if (-not $detected -and (Test-Path (Join-Path $TargetDir "composer.json"))) {
        $unit = "php artisan test --filter {files}"; $full = "php artisan test"; $detected = "phpunit"
    }
    if ($detected) {
        $gen = @"
# Agent Pack project config -- AUTO-GENERATED by installer (detected: $detected).
# Tune to taste. Project-owned: re-install never overwrites this.
# Schema: .harness/schemas/agent-config.schema.json
test:
  unit_related_cmd: "$unit"
  full_suite_cmd:   "$full"
  integration_smoke: []
impact:
  force_full_test_on:
    - "**/migrations/**"
    - "**/schema.*"
    - "**/middleware.*"
    - "package-lock.json"
    - "composer.lock"
    - "poetry.lock"
"@
        [System.IO.File]::WriteAllText($acFile, $gen, $Utf8NoBom)
        Write-Output "[scaffold] agent-config.yaml generated (detected $detected test runner)"
    } else {
        Copy-Item $acSample $acFile
        Write-Output "[scaffold] agent-config.yaml: stack not detected -> wrote sample to fill in (Agent Pack review->fix->test needs it)"
    }
}

# --- CI gates scaffold (-WithCiGates): copy the shipped workflow templates into
# .github/. Opt-in, because adding workflow files changes what runs on every push.
# Never overwrites: a project's own tuned workflow outranks the template.
if ($WithCiGates) {
    $ciSrc = Join-Path $syncDir "templates\ci"
    if (-not (Test-Path $ciSrc)) {
        Write-Output "[ci] no templates/ci in this bundle -- nothing to copy"
    } else {
        $wf = Join-Path $TargetDir ".github\workflows"
        if (-not (Test-Path $wf)) { New-Item -ItemType Directory -Path $wf -Force | Out-Null }
        foreach ($pair in @(
            @{ src = "harness-gate.yml.template"; dst = (Join-Path $wf "harness-gate.yml") },
            @{ src = "tests.yml.template";        dst = (Join-Path $wf "tests.yml") },
            @{ src = "CODEOWNERS.template";       dst = (Join-Path $TargetDir ".github\CODEOWNERS") }
        )) {
            $s = Join-Path $ciSrc $pair.src
            if (-not (Test-Path $s)) { continue }
            if (Test-Path $pair.dst) {
                Write-Output "[ci] $(Split-Path $pair.dst -Leaf) already exists -> kept"
                continue
            }
            $text = Get-Content $s -Raw -Encoding utf8

            # tests.yml ships with every stack block commented and a failing
            # placeholder, because a template that guesses wrong fails on every
            # PR. But by this point the agent-config scaffold above has ALREADY
            # detected the runner from the repo -- so making the operator
            # hand-uncomment a block we already identified is a chore, and one
            # they will hit at the worst moment (first red PR). Render the
            # detected block active; fall back to the commented template only
            # when detection genuinely found nothing.
            if ($pair.src -eq "tests.yml.template") {
                $ac = Join-Path $TargetDir ".harness\control\agent-config.yaml"
                $full = ""
                if (Test-Path $ac) {
                    $m = [regex]::Match((Get-Content $ac -Raw -Encoding utf8), '(?m)^\s*full_suite_cmd:\s*"?([^"\r\n]+)"?\s*$')
                    if ($m.Success) { $full = $m.Groups[1].Value.Trim() }
                }
                # The setup steps must match what THIS repo actually has, not what
                # a stack usually has. A generated workflow that fails on its
                # first PR for a missing lockfile or a missing .env teaches the
                # team to ignore red CI -- the worst habit this whole gate exists
                # to prevent. So each branch below is conditioned on files that
                # were checked to exist.
                # Monorepo: the runner does not live at the repo root. Find the
                # directory that actually holds the manifest and run there.
                # Without this the workflow does `npm ci` at a root with no
                # package.json and dies on step one -- three projects in this
                # fleet keep their manifest in a subdirectory (web/, a
                # product-named folder, and apps/backend/).
                $workDir = ""
                if ($full -match '^(npx |npm )' -and -not (Test-Path (Join-Path $TargetDir "package.json"))) {
                    # An explicit `--prefix <dir>` names the directory outright.
                    $pm = [regex]::Match($full, '--prefix\s+(\S+)')
                    if ($pm.Success) {
                        $workDir = $pm.Groups[1].Value
                        # Once we cd there, --prefix would resolve relative to it
                        # and look for <dir>/<dir>. Strip it.
                        $full = ($full -replace '\s*--prefix\s+\S+', '').Trim()
                    } else {
                        # Otherwise pick the workspace that actually HAS tests.
                        # Depth alone is not enough: one repo has
                        # apps/frontend and apps/backend at the same depth, both
                        # with a test script, and the shallowest-wins rule took
                        # frontend -- which has no tests -- so the whole workflow
                        # was skipped while six real test files sat in backend.
                        # Having tests is the signal; a test script is only a
                        # tiebreak.
                        $cand = Get-ChildItem -Path $TargetDir -Filter package.json -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                                Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.claude\\' } |
                                Sort-Object { ($_.FullName -split '\\').Count }
                        $best = $null; $bestScore = -1
                        foreach ($c in $cand) {
                            $dir = Split-Path $c.FullName -Parent
                            $j = Get-Content $c.FullName -Raw -Encoding utf8
                            $n = @(Get-ChildItem -Path $dir -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
                                   Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.claude\\' -and
                                                  $_.Name -match '\.(test|spec)\.[jt]sx?$' }).Count
                            # tests dominate; a test script breaks ties among zeros
                            $score = ($n * 100) + $(if ($j -match '"test"\s*:') { 1 } else { 0 })
                            if ($score -gt $bestScore) { $bestScore = $score; $best = $dir }
                        }
                        if ($best -and $bestScore -gt 0) {
                            $workDir = $best.Substring($TargetDir.Length).TrimStart('\','/').Replace('\','/')
                        }
                    }
                    if ($workDir) { Write-Output "[ci] tests.yml: monorepo -- running in $workDir" }
                }
                # Lockfile/manifest checks must look where the runner will run.
                $runRoot = $TargetDir
                if ($workDir) { $runRoot = Join-Path $TargetDir ($workDir -replace '/', '\') }

                $setup = ""
                if ($full -match '^(npx |npm )') {
                    # `npm ci` REQUIRES a lockfile and hard-fails without one.
                    $inst = "npm ci"
                    if (-not (Test-Path (Join-Path $runRoot "package-lock.json"))) { $inst = "npm install" }
                    # The install step must run where the manifest is, not at the
                    # repo root -- otherwise it fails before the test step is ever
                    # reached.
                    $instWd = ""
                    if ($workDir) { $instWd = "`n        working-directory: $workDir" }
                    $setup = "      - uses: actions/setup-node@v4`n        with:`n          node-version: '20'`n      - run: $inst$instWd"
                } elseif ($full -match 'pytest|python -m') {
                    $pyInstall = $null
                    # Test dependencies commonly live in a *-test/-dev file rather
                    # than requirements.txt; one project here has only
                    # requirements-test.txt, and missing it produced a TODO for a
                    # project whose deps were declared all along.
                    foreach ($rf in @("requirements.txt", "requirements-test.txt", "requirements-dev.txt", "dev-requirements.txt")) {
                        if (Test-Path (Join-Path $TargetDir $rf)) { $pyInstall = "pip install -r $rf"; break }
                    }
                    if (-not $pyInstall -and (Test-Path (Join-Path $TargetDir "pyproject.toml"))) {
                        # Only installable when pyproject declares [project]; a
                        # config-only pyproject (pytest/coverage/mypy settings)
                        # makes `pip install -e .` fail with a metadata error.
                        $pj = Get-Content (Join-Path $TargetDir "pyproject.toml") -Raw -Encoding utf8
                        if ($pj -match '(?m)^\s*\[project\]') { $pyInstall = "pip install -e ." }
                    }
                    if ($pyInstall) {
                        $setup = "      - uses: actions/setup-python@v5`n        with:`n          python-version: '3.12'`n      - run: $pyInstall"
                    } else {
                        # No honest install command exists. Say so in the file
                        # rather than emitting one that will fail.
                        $setup = "      - uses: actions/setup-python@v5`n        with:`n          python-version: '3.12'`n      # TODO: this repo has no requirements.txt and no installable pyproject [project]`n      # table, so the installer could not infer how to install deps. Add the`n      # right command here (e.g. pip install pytest -r dev-requirements.txt).`n      - run: pip install pytest"
                        Write-Output "[ci] tests.yml: no requirements.txt / installable pyproject -- left a TODO for the dependency step"
                    }
                } elseif ($full -match 'artisan|phpunit') {
                    # Laravel refuses to boot without APP_KEY, so `php artisan
                    # test` fails immediately on a fresh checkout unless .env is
                    # created and a key generated first.
                    $php = "      - uses: shivammathur/setup-php@v2`n        with:`n          php-version: '8.2'`n      - run: composer install --no-interaction --prefer-dist"
                    if (Test-Path (Join-Path $TargetDir ".env.example")) {
                        $php += "`n      - run: cp .env.example .env`n      - run: php artisan key:generate"
                    }
                    $setup = $php
                }
                # Trigger on the branch this repo ACTUALLY uses. The template
                # hardcoded `main`, so a repo on `master` got a workflow that
                # installs cleanly, shows up in .github/, and never fires --
                # present, green-looking, gating nothing. That is worse than no
                # workflow: an absent gate is visibly absent, a dead one reads as
                # coverage. Two of six projects were on master.
                # The REMOTE's default branch, not whatever this checkout happens
                # to be sitting on. An install run from a feature branch would
                # otherwise pin CI to it -- firing once, then silently never again
                # after the branch is deleted (one install was run from a
                # temporary `claude/<generated-name>` branch). Same dead-gate
                # failure as hardcoding `main`, reached from the other side.
                $branch = Get-DefaultBranch $TargetDir

                # A repo with no tests must not get a test workflow. Running a
                # runner against zero tests either errors or reports a vacuous
                # pass, and a green badge that tested nothing is a lie the whole
                # gate exists to prevent (one project here has no test files).
                $hasTests = @(Get-ChildItem -Path $runRoot -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.claude\\|\\\.harness\\' -and
                                   ($_.Name -match '\.(test|spec)\.[jt]sx?$' -or $_.Name -match '^test_.*\.py$' -or $_.Name -match 'Test\.php$') }).Count
                if ($hasTests -eq 0) {
                    Write-Output "[ci] tests.yml SKIPPED: no test files found -- a workflow that tests nothing but reports green is worse than none"
                    continue
                }

                # Indent the run step under working-directory when in a subdir.
                $wdLine = ""
                if ($workDir) { $wdLine = "`n        working-directory: $workDir" }

                if ($setup -and $full) {
                    $text = @"
# Project test suite in CI -- AUTO-GENERATED by the installer from
# .harness/control/agent-config.yaml (full_suite_cmd), so CI and the Agent Pack's
# targeted-tester run the SAME suite. Two places declaring "how to test this
# project" drift apart; this one reads the single declaration.
name: tests

on:
  pull_request:
    branches: [$branch]
  push:
    branches: [$branch]

jobs:
  test:
    name: Project test suite
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
$setup
      - run: $full$wdLine
"@
                    Write-Output "[ci] tests.yml generated from agent-config (cmd: $full)"
                } else {
                    Write-Output "[ci] tests.yml: could not read a runner from agent-config -- wrote the template with all stack blocks commented (it fails until you enable one, by design)"
                }
            }

            # harness-gate.yml is a static template that also hardcodes `main`.
            # Same silent failure as tests.yml: on a `master` repo it would sit
            # in .github/ and never fire. Rewrite its trigger to the real branch.
            if ($pair.src -eq "harness-gate.yml.template") {
                $gb = Get-DefaultBranch $TargetDir
                if ($gb -ne "main") {
                    $text = $text -replace '(?m)^(\s*branches:\s*)\[main\]', ('$1[' + $gb + ']')
                    Write-Output "[ci] harness-gate.yml: trigger branch -> $gb"
                }
            }

            # Substitute the owner handle so CODEOWNERS is usable as written.
            # Falls back to leaving the placeholder visible rather than inventing
            # a handle -- a wrong owner silently routes reviews to nobody.
            if ($pair.src -eq "CODEOWNERS.template") {
                $owner = ""
                $projContract = Join-Path $TargetDir "contracts\project.yaml"
                if (Test-Path $projContract) {
                    $m = [regex]::Match((Get-Content $projContract -Raw -Encoding utf8), '(?m)^\s*owner:\s*"?@?([A-Za-z0-9_\-]+)"?\s*$')
                    if ($m.Success) { $owner = "@" + $m.Groups[1].Value }
                }
                if ($owner) { $text = $text.Replace("@your-handle-here", $owner) }
                else { Write-Output "[ci] CODEOWNERS: no owner in contracts/project.yaml -- left @your-handle-here to fill in" }
            }
            [System.IO.File]::WriteAllText($pair.dst, $text, $Utf8NoBom)
            Write-Output "[ci] wrote $(Split-Path $pair.dst -Leaf)"
        }
        Write-Output "[ci] NOTE: CODEOWNERS only enforces when branch protection requires Code Owner review (C10)."
        # Only true on the fallback path. Saying it unconditionally contradicted
        # the "generated from agent-config" line printed two lines earlier.
        if (Test-Path (Join-Path $TargetDir ".github\workflows\tests.yml")) {
            $ty = Get-Content (Join-Path $TargetDir ".github\workflows\tests.yml") -Raw -Encoding utf8
            if ($ty -match 'No stack selected') {
                Write-Output "[ci] NOTE: tests.yml has every stack block commented -- uncomment yours or it fails by design."
            }
        }
    }
}

# C5: never commit the ingest key. Ensure the target project's .gitignore
# ignores it (idempotent -- add the line only if missing).
$giPath = Join-Path $TargetDir ".gitignore"
$giLine = ".harness/portal-sync.key"
$giHas = (Test-Path $giPath) -and (Select-String -Path $giPath -SimpleMatch $giLine -Quiet)
if (-not $giHas) {
    Add-Content -Path $giPath -Value "`n# Harness Portal ingest key - secret, never commit (C5)`n$giLine" -Encoding utf8
    Write-Output "[scaffold] added portal-sync.key to .gitignore (C5)"
}

# Portal v2 P1 1.7: per-machine state (checkout credential, member_email) lives in .harness/local/.
# That folder must never reach git -- ignore it in the target project (idempotent).
$localLine = ".harness/local/"
$localHas = (Test-Path $giPath) -and (Select-String -Path $giPath -Pattern '^/?\.harness/local/?\s*$' -Quiet)
if (-not $localHas) {
    Add-Content -Path $giPath -Value "`n# Harness per-machine state (checkout credential, member_email) - never commit`n$localLine" -Encoding utf8
    Write-Output "[scaffold] added .harness/local/ to .gitignore (machine-local state)"
}

# The legacy-guide migration below writes a one-time '<file>.pre-migration.bak'.
# That is a local safety net, not project content -- ignore it so it does not
# show up as untracked noise in every project the migration touched.
$bakLine = "*.pre-migration.bak"
$bakHas = (Test-Path $giPath) -and (Select-String -Path $giPath -SimpleMatch $bakLine -Quiet)
if (-not $bakHas) {
    Add-Content -Path $giPath -Value "`n# One-time backup written when a legacy guide block is migrated`n$bakLine" -Encoding utf8
    Write-Output "[scaffold] added *.pre-migration.bak to .gitignore"
}

# The ledger's append lock (evidence-ledger: byte-range lock on this file) is
# runtime state, like the chain itself -- never project content.
$lockLine = ".harness/ledger/chain.lock"
$lockHas = (Test-Path $giPath) -and (Select-String -Path $giPath -SimpleMatch $lockLine -Quiet)
if (-not $lockHas) {
    Add-Content -Path $giPath -Value "`n# Harness ledger append lock - runtime state`n$lockLine" -Encoding utf8
    Write-Output "[scaffold] added ledger chain.lock to .gitignore"
}

# `<file>.new` is the installer's marker for "a shipped copy you have not adopted"
# (a project-owned or conflicted file). It is a local to-do, not project content:
# committing one ships the conflict to everybody and to the next checkout.
$newHas = (Test-Path $giPath) -and (Select-String -Path $giPath -Pattern '^\*\.new\s*$' -Quiet)
if (-not $newHas) {
    Add-Content -Path $giPath -Value "`n# Shipped copies the installer leaves beside a file you own or edited - resolve, then delete`n*.new" -Encoding utf8
    Write-Output "[scaffold] added *.new to .gitignore"
}

# A project that runs Prettier over the repo (`prettier --write .`, lint-staged)
# reformats the bundle's own files: in ScreenRecord (2026-09-30) it rewrote 71 of
# them, including casan-policies.yaml, whose suite commands turned into
# 'python ...' -- cmd.exe then ran nothing and harness-eval skipped every suite.
# Only when the project uses Prettier; one marker line keeps this idempotent.
$usesPrettier = @(Get-ChildItem -Path $TargetDir -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(\.prettierrc(\..+)?|prettier\.config\..+)$' }).Count -gt 0
$pkgJson = Join-Path $TargetDir "package.json"
if (-not $usesPrettier -and (Test-Path $pkgJson)) { $usesPrettier = (Get-Content $pkgJson -Raw) -match '"prettier"' }
if ($usesPrettier) {
    $piPath = Join-Path $TargetDir ".prettierignore"
    $piMarker = "# harness-bundle: files owned by the governance bundle"
    if (-not ((Test-Path $piPath) -and (Select-String -Path $piPath -SimpleMatch $piMarker -Quiet))) {
        $piLines = @($piMarker,
            "# Reformatting them breaks the bundle integrity check and can change what they mean.",
            ".harness/", "tools/harness-bundle/", "contracts/", ".claude/agents/", ".claude/skills/",
            ".claude/settings.json", ".claude/settings.posix.json", "CLAUDE.harness.md")
        Add-Content -Path $piPath -Value ("`n" + ($piLines -join "`n")) -Encoding utf8
        Write-Output "[scaffold] project uses Prettier -- added the bundle's paths to .prettierignore"
    }
}

# --- H1 scaffold: build the context pointer store so a freshly-onboarded project
# satisfies its own context contract right away (the policy-ci suite asserts it,
# and the release gate would otherwise block until the first session ran the
# hook). Best-effort: a failure here must never fail the install.
$ctxBuild = Join-Path $TargetDir ".harness\scripts\powershell\harness-context-build.ps1"
$ctxStore = Join-Path $TargetDir ".harness\context\pipeline-context.yaml"
if ((Test-Path $ctxBuild) -and (-not (Test-Path $ctxStore))) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ctxBuild -HarnessRoot $TargetDir *> $null
        if (Test-Path $ctxStore) { Write-Output "[scaffold] built .harness\context\pipeline-context.yaml (H1)" }
    } catch {
        Write-Warning "[scaffold] could not build the H1 pointer store (non-fatal): $($_.Exception.Message)"
    }
}

# --- Project identity: stamp name/description into contracts/project.yaml ---
# Patches ONLY the two scalars inside the `project:` block, so comments and every
# other key in the contract survive untouched.
function Set-ProjectIdentity {
    param([string]$Path, [string]$Name, [string]$Description, [bool]$Force)
    if (-not (Test-Path $Path)) { return "no-contract" }
    $lines = [System.IO.File]::ReadAllText($Path, $Utf8NoBom) -split "`r?`n"
    $inProject = $false; $changed = $false; $curName = ""
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^project:\s*$') { $inProject = $true; continue }
        if ($inProject) {
            if ($lines[$i] -match '^\S') { break }                      # dedent = block ended
            if ($lines[$i] -match '^(\s+)name:\s*(.*)$') { $curName = $matches[2].Trim().Trim('"') }
        }
    }
    # The shipped contract carries the toolkit's own identity; treat that (and an
    # empty name) as "not yet claimed by this project". A name starting with "-"
    # is never legitimate -- it can only come from an argument-binding slip -- so
    # treat it as unclaimed too and let a re-run repair it.
    $isPlaceholder = ($curName -eq "" -or $curName -eq "harness-toolkit" -or
                      $curName -eq "my-project" -or $curName.StartsWith("-"))
    if (-not $Force -and -not $isPlaceholder) { return "kept:$curName" }

    $inProject = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^project:\s*$') { $inProject = $true; continue }
        if ($inProject) {
            if ($lines[$i] -match '^\S') { break }
            if ($lines[$i] -match '^(\s+)name:\s*') {
                $lines[$i] = "$($matches[1])name: `"$Name`""; $changed = $true
            } elseif ($lines[$i] -match '^(\s+)description:\s*') {
                $lines[$i] = "$($matches[1])description: `"$Description`""; $changed = $true
            }
        }
    }
    if (-not $changed) { return "no-fields" }
    [System.IO.File]::WriteAllText($Path, ($lines -join "`n"), $Utf8NoBom)
    return "set"
}

if ($ProjectName) {
    if (-not $ProjectDescription) { $ProjectDescription = $ProjectName }
    $contract = Join-Path $TargetDir "contracts\project.yaml"
    $r = Set-ProjectIdentity -Path $contract -Name $ProjectName -Description $ProjectDescription -Force:$ForceIdentity
    switch -Wildcard ($r) {
        "set"          { Write-Output "[identity] contracts/project.yaml -> name/description = '$ProjectName'" }
        "kept:*"       { Write-Output "[identity] kept existing project name '$($r.Substring(5))' (use -ForceIdentity to overwrite)" }
        "no-contract"  { Write-Warning "[identity] contracts/project.yaml not found -- skipped" }
        default        { Write-Warning "[identity] could not find name/description under 'project:' -- skipped" }
    }
}

# --- Project the common governance text into every agent-guide file ---
# ONE canonical source (CLAUDE.harness.md) -> many tool-specific files. The block
# is delimited, so re-installing REPLACES only the managed block and never
# touches whatever the project wrote around it.
if ($MergeGuides) {
    $harnessMd = Join-Path $TargetDir "CLAUDE.harness.md"
    if (-not (Test-Path $harnessMd)) {
        Write-Warning "[guides] CLAUDE.harness.md not found in target -- skipping (bundle may not ship it)"
    } else {
        $govText = ([System.IO.File]::ReadAllText($harnessMd, $Utf8NoBom)).Trim()

        # C2: the target list is data, not code. Falls back to the common trio.
        $targets = @()
        $policy = Join-Path $TargetDir ".harness\control\casan-policies.yaml"
        if (Test-Path $policy) {
            $inBlock = $false
            foreach ($line in (Get-Content $policy -Encoding utf8)) {
                if ($line -match '^\s*guide_targets:\s*(#.*)?$') { $inBlock = $true; continue }
                if ($inBlock) {
                    if ($line -match '^\s*#') { continue }
                    if ($line -match '^\s*-\s*(.+?)\s*$') {
                        $v = ($matches[1] -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
                        if ($v) { $targets += $v }
                    } elseif ($line -match '\S') { break }
                }
            }
        }
        if (-not $targets) { $targets = @("CLAUDE.md", "AGENTS.md", ".github/copilot-instructions.md") }

        $begin = "<!-- BEGIN harness-governance -->"
        $end   = "<!-- END harness-governance -->"
        $note  = "<!-- standard-governance v$($bundle.version) - MANAGED BLOCK. Edits inside are replaced on the next install; put your own project rules OUTSIDE this block. -->"
        $block = "$begin`n$note`n`n$govText`n`n$end"

        foreach ($rel in $targets) {
            $p = Resolve-BundleDest -Root $TargetDir -RelPath $rel
            $dir = Split-Path -Parent $p
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            if (-not (Test-Path $p)) {
                [System.IO.File]::WriteAllText($p, $block + "`n", $Utf8NoBom)
                Write-Output "[guides] created $rel"
                continue
            }
            $existing = [System.IO.File]::ReadAllText($p, $Utf8NoBom)
            # LastIndexOf for the closing marker: if the governance text (or the
            # project's own notes) ever mentions the marker inside the block, a
            # first-match search would cut the block short and leave orphaned text
            # behind on every refresh.
            $bi = $existing.IndexOf($begin); $ei = $existing.LastIndexOf($end)
            if ($bi -ge 0 -and $ei -gt $bi) {
                $pre = $existing.Substring(0, $bi)
                $post = $existing.Substring($ei + $end.Length)
                [System.IO.File]::WriteAllText($p, $pre + $block + $post, $Utf8NoBom)
                Write-Output "[guides] refreshed managed block in $rel"
            } elseif ($existing -match '<!--\s*harness:merged\s*-->') {
                # Pre-1.5.0 merge appended the governance text with only a start
                # sentinel and ran to EOF, so it could never be refreshed. Convert
                # it: keep everything BEFORE the sentinel (that is the project's
                # own content) and re-emit the governance as a managed block.
                # A one-time .bak makes the conversion reversible.
                $mm = [regex]::Match($existing, '(?m)^\s*-{3,}\s*\r?\n<!--\s*harness:merged\s*-->')
                if (-not $mm.Success) { $mm = [regex]::Match($existing, '<!--\s*harness:merged\s*-->') }
                $bak = "$p.pre-migration.bak"
                if (-not (Test-Path $bak)) { [System.IO.File]::WriteAllText($bak, $existing, $Utf8NoBom) }
                $pre = $existing.Substring(0, $mm.Index).TrimEnd()
                [System.IO.File]::WriteAllText($p, $pre + "`n`n---`n`n" + $block + "`n", $Utf8NoBom)
                Write-Output "[guides] migrated legacy block in $rel -> managed block (backup: $rel.pre-migration.bak)"
            } else {
                [System.IO.File]::WriteAllText($p, $existing.TrimEnd() + "`n`n---`n`n" + $block + "`n", $Utf8NoBom)
                Write-Output "[guides] appended governance to existing $rel (your content untouched)"
            }
        }
    }
}

# --- Re-stamp the receipt with what this install actually LEFT ON DISK ---------
# The baseline for "did the project hand-edit a bundle-owned file?" has to be the
# state the installer finished in, not the bytes the bundle shipped. Several steps
# above deliberately modify files after writing them -- the guide merge appends a
# managed block, settings/identity get stamped -- so comparing against the shipped
# hash flagged .claude/settings.json as hand-edited on the very next run. That
# false positive would train a maintainer to ignore conflict reports, which costs
# more than having no detection at all.
#
# `sha256` keeps its original meaning (the shipped bytes) because the uninstaller
# uses it to tell a pristine file from a user-edited one; `installed_sha256` is
# added alongside, and the tamper check prefers it when present.
try {
    $rPath = Join-Path $TargetDir ".harness\.bundle-manifest.json"
    if (Test-Path $rPath) {
        $r = Get-Content -Path $rPath -Raw -Encoding utf8 | ConvertFrom-Json
        $out = foreach ($e in @($r.files)) {
            $ih = "$($e.installed_sha256)"
            # Only a file this run INSTALLED has a hash worth re-reading. The others
            # keep the baseline the receipt above carried over: re-hashing a
            # conflicted or kept file here would make the hand edit the new baseline.
            if (-not $e.state -or $e.state -eq "installed") {
                $p = Resolve-BundleDest -Root $TargetDir -RelPath $e.path
                $ih = $Unknown
                if (Test-Path $p) {
                    try { $ih = Get-HashOrUnknown ([System.IO.File]::ReadAllBytes($p)) } catch { }
                }
            }
            [ordered]@{ path = $e.path; sha256 = "$($e.sha256)"; installed_sha256 = $ih; state = "$($e.state)" }
        }
        $r2 = [ordered]@{
            name = $r.name; version = $r.version; content_hash = $r.content_hash
            installed_at = $r.installed_at; status = $r.status; counts = $r.counts
            preserve = @($r.preserve); files = @($out)
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($rPath, $r2, $Utf8NoBom)
    }
} catch {
    Write-Output "[receipt] WARNING: could not re-stamp installed hashes ($($_.Exception.Message)); next run may report false conflicts"
}

# --- Cleanup temp download if used ---
if ($TempDownload -and (Test-Path $TempDownload)) { Remove-Item $TempDownload -Force }
