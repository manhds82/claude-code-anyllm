#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Hash-chain ledger + Evidence Bundle generator (H5).
  Append-only immutable audit trail for all harness actions.
.DESCRIPTION
  Maintains an append-only hash-chain ledger at .harness/ledger/chain.jsonl
  Each entry contains prev_hash linking to the previous entry -- tampering with
  any entry breaks the chain for all subsequent entries.

  Also generates Evidence Bundles per change (8-part DoD per §18.3 spec).

  Commands:
    init      - Create genesis block
    append    - Add a new ledger entry (-EntryJson, -EntryFile, or piped stdin)
    verify    - Verify chain integrity from genesis to head
    seal      - Close the current chain segment: write a final seal entry, archive
                the file as chain-NNN.jsonl, start a fresh chain.jsonl whose genesis
                records the archive's name + head hash (-Reason for the why)
    bundle    - Generate an evidence bundle for a change (-EntryJson/-EntryFile/stdin)
    export    - Export ledger as CSV

  Input resolution order for append/bundle (PIPE-1 fix): -EntryJson string,
  then -EntryFile path (recommended for callers -- avoids command-line
  quoting/length limits), then piped stdin. If none of these are actually
  available, the script fails fast with an error instead of blocking on a
  console read that will never resolve.
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "append", "verify", "seal", "bundle", "export")]
    [string]$Command = "append",

    [string]$LedgerDir = "",

    [string]$EntryJson = "",

    [string]$EntryFile = "",

    # seal only: why this segment is being closed. Recorded verbatim in the seal
    # entry -- an auditor reading the archive should not have to guess.
    [string]$Reason = ""
)

# --- Helper: resolve entry input without ever blocking on an unredirected console (PIPE-1) ---
function Get-EntryInput {
    param(
        [string]$EntryJsonParam,
        [string]$EntryFileParam
    )
    if ($EntryJsonParam) { return $EntryJsonParam }
    if ($EntryFileParam) {
        if (-not (Test-Path $EntryFileParam)) {
            Write-Error "[evidence-ledger] -EntryFile not found: $EntryFileParam"
            exit 1
        }
        return Get-Content -Path $EntryFileParam -Raw -Encoding utf8
    }
    if ([Console]::IsInputRedirected) {
        return [Console]::In.ReadToEnd()
    }
    Write-Error "[evidence-ledger] No input provided -- pass -EntryJson, -EntryFile, or pipe JSON via stdin"
    exit 1
}

# Resolve paths
$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) { $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.." }
if (-not $LedgerDir) { $LedgerDir = "$HarnessRoot\.harness\ledger" }
if (-not (Test-Path $LedgerDir)) { New-Item -ItemType Directory -Path $LedgerDir -Force | Out-Null }

$ChainFile = "$LedgerDir\chain.jsonl"
$BundleDir = "$LedgerDir\bundles"
if (-not (Test-Path $BundleDir)) { New-Item -ItemType Directory -Path $BundleDir -Force | Out-Null }

# --- Helper: write/append UTF-8 without BOM (Windows PowerShell 5.1's `-Encoding
#     utf8` always emits a BOM, contaminating an otherwise-clean append-only
#     JSONL ledger -- same class of defect as H-INIT-3) ---
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param([string]$Path, [string]$Value)
    [System.IO.File]::WriteAllText($Path, $Value, $Utf8NoBom)
}

function Add-Utf8NoBom {
    param([string]$Path, [string]$Value)
    [System.IO.File]::AppendAllText($Path, $Value, $Utf8NoBom)
}

# --- U1: record the appends that DID NOT HAPPEN -------------------------------
#
# C9 says every side-effect appends one line. So an append that throws is a
# side-effect that HAPPENED WITH NO LINE RECORDING IT. The chain stays
# internally consistent and `verify` stays green, because a missing entry leaves
# no hole to find -- the next entry links to the last one that succeeded. There
# is no way to discover the gap from the chain itself.
#
# Measured on this machine: `ledger append threw for tool=Edit ::
# System.OutOfMemoryException`. Get-LastEntry reads a 4 MB tail, and this box
# routinely runs under 1 GB free, so the failure lands exactly when the most is
# happening.
#
# THIS FILE IS NOT THE CHAIN. A marker line has no valid prev_hash, so writing it
# into chain.jsonl would make `verify` report a break -- trading a silent gap for
# a loud false alarm about tampering. It goes to its own file, and `harness
# doctor` grades a non-empty one as FAIL.
#
# The writer is deliberately the cheapest thing that can still write: string
# concatenation and one AppendAllText. No Get-LastEntry, no ConvertTo-Json, no
# hashing -- a fallback that repeats whatever exhausted memory is not a fallback.
$AppendFailFile = "$LedgerDir\append-failures.jsonl"

function ConvertTo-JsonStringLiteral {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    # Only what JSON forbids raw. Keep it small; this runs while memory is short.
    $t = $Text.Replace('\', '\\').Replace('"', '\"')
    $t = $t -replace "[`r`n`t]", ' '
    if ($t.Length -gt 400) { $t = $t.Substring(0, 400) }
    return $t
}

function Write-AppendFailure {
    param([string]$Tool, [string]$Reason, [string]$Stage)
    try {
        $line = '{"ts":"' + (Get-Date -Format 'o') +
                '","type":"append_failed","stage":"' + (ConvertTo-JsonStringLiteral $Stage) +
                '","tool":"' + (ConvertTo-JsonStringLiteral $Tool) +
                '","session_id":"' + (ConvertTo-JsonStringLiteral $env:HARNESS_SESSION_ID) +
                '","reason":"' + (ConvertTo-JsonStringLiteral $Reason) + '"}'
        [System.IO.File]::AppendAllText($AppendFailFile, $line + "`n", $Utf8NoBom)
        return $true
    } catch {
        # Even the cheap path failed (disk full, permissions, memory gone).
        # Last resort: the hook error log, with a signature doctor grades FAIL.
        try {
            $errLog = "$HarnessRoot\.harness\telemetry\hook-errors.log"
            $dir = Split-Path -Parent $errLog
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.File]::AppendAllText($errLog,
                ("{0} LEDGER-APPEND-LOST tool={1} :: {2}`n" -f (Get-Date -Format 'o'), $Tool, $Reason),
                $Utf8NoBom)
        } catch { }
        return $false
    }
}

# --- Append lock -------------------------------------------------------------
#
# "Read the last entry_hash, then append a line linking to it" is two steps. With
# no lock, two hooks running at once (parallel tool calls, subagents, a second
# session) both read the same last entry and both link to it: the chain FORKS.
# Measured 2026-09-29 on this repo: 974 of 8,953 entries linked to an older entry
# than the line above them, and doctor still said OK. After that, one genuine
# rewrite hides among hundreds of harmless forks (C9 + C14).
#
# The lock is a byte-range lock on byte 0 of chain.lock, NOT an exclusive open.
# It is the same OS primitive Python's msvcrt.locking / fcntl.lockf use, so the
# bash twin (whose writer is Python) and this script exclude each other when both
# run on one machine. An OS lock dies with its process: a hook killed on timeout
# cannot leave the ledger locked forever, which a lock FILE or directory would.
$LedgerLockFile = "$LedgerDir\chain.lock"
$LedgerLockTimeoutMs = 10000

function Enter-LedgerLock {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($LedgerLockFile, 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
            $fs.Lock(0, 1)
            return $fs
        } catch [System.IO.IOException] {
            if ($fs) { $fs.Dispose() }
            if ($sw.ElapsedMilliseconds -ge $LedgerLockTimeoutMs) {
                throw "ledger lock not acquired within $LedgerLockTimeoutMs ms (another append is holding it)"
            }
            Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 50)
        }
    }
}

function Exit-LedgerLock {
    param($Handle)
    if ($Handle) {
        try { $Handle.Unlock(0, 1) } catch { }
        $Handle.Dispose()
    }
}

# --- Helper: SHA-256 hash ---
function Get-EntryHash {
    param([string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash.ToLower()
    return $hash
}

# --- Helper: read last entry ---
# Appending needs exactly TWO values off the previous entry -- its entry_hash and
# its index -- so this pulls those two out by pattern and never deserializes the
# line.
#
# Deserializing it is what killed this repo's own ledger. An older index bug
# appended arrays instead of adding, so each entry embedded the one before it and
# DOUBLED: 365 KB, 730 KB, 1.46 MB, 2.19 MB. ConvertFrom-Json on that final 2.19 MB
# line takes ~70 MINUTES under Windows PowerShell 5.1 (measured, not estimated).
# The PostToolUse hook's timeout is seconds, so every append was killed mid-flight
# and the chain silently stopped growing on 2026-07-23 -- 14 days before anyone
# noticed, because the caller redirected all streams to $null. Regex over the same
# 2.19 MB is milliseconds.
#
# The index bug itself is fixed (b730629), but a poisoned entry is permanent: it
# stays in the chain and breaks every append that comes after it. Reading has to
# survive data that is already bad, not just avoid producing more of it.
function Get-LastEntry {
    if (-not (Test-Path $ChainFile)) { return $null }

    # Read the tail with a raw FileStream, never Get-Content -Tail. -Tail walks the
    # file BACKWARDS decoding as it goes, and on a line this chain actually has
    # (2.19 MB, see below) that walk was measured at over TEN MINUTES in Windows
    # PowerShell 5.1 -- it, not JSON parsing, was what let the PostToolUse hook
    # time out on every append. Seek-and-read of the last 4 MB is milliseconds
    # regardless of how the line got there.
    $text = $null
    try {
        $fs = [System.IO.File]::Open($ChainFile, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            if ($len -le 0) { return $null }
            $cap = 4MB
            $take = [int][Math]::Min([int64]$cap, $len)
            $fs.Seek($len - $take, 'Begin') | Out-Null
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            # A window that starts mid-file may open mid-way through a multi-byte
            # UTF-8 char; harmless here, because everything matched below is ASCII.
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $null }
    if (-not $text) { return $null }

    $trimmed = $text.TrimEnd("`r", "`n")
    if ($trimmed.Length -eq 0) { return $null }
    $nl = $trimmed.LastIndexOf("`n")
    $line = if ($nl -ge 0) { $trimmed.Substring($nl + 1) } else {
        # No newline left in the window. Two very different causes, and the
        # earlier version conflated them:
        #
        #   a) the window is FULL (take == cap) and still has no newline, so the
        #      final line really does exceed 4 MB -- the case this warning is for;
        #   b) the file is SMALLER than the cap and holds exactly one line. After
        #      TrimEnd strips its trailing newline there is no "`n" left, which
        #      is not a 4 MB line, it is a brand-new chain with only its genesis.
        #
        # (b) is the state of every freshly installed project at its first
        # append, so the warning fired across the fleet on the most ordinary
        # event there is. A warning that cries wolf on the normal case is a P0
        # defect, not noise (C14) -- found on a real project whose chain was
        # 476 bytes long.
        if ($take -ge $cap) {
            # The regexes still run over the window's tail, which is where the
            # outermost entry's own fields sit -- best-effort linkage, said out loud.
            Write-Warning "[evidence-ledger] last entry exceeds 4MB; reading its tail window only"
        }
        $trimmed
    }

    # Corruption sentinel: an index stored as an ARRAY is the fingerprint of the
    # pre-b730629 append bug, whose entries also embed nested copies of their
    # predecessors and DOUBLE in size each write (365 KB -> 730 KB -> 1.46 MB ->
    # 2.19 MB in this repo's own chain). Such an entry's index is meaningless --
    # never arithmetic on it; the caller falls back to the chain length. The old
    # "defence" took the corrupt array's last element (a 1) and wrote index 2 onto
    # a 5238-entry chain, destroying the ordering the chain exists to prove.
    $isCorrupt = $line -match '"index"\s*:\s*\['

    $hashMatches = [regex]::Matches($line, '"entry_hash"\s*:\s*"([0-9a-fA-F]{64})"')
    $entryHash = $null
    if ($hashMatches.Count -ge 1) {
        $entryHash = $hashMatches[$hashMatches.Count - 1].Groups[1].Value
        if ($hashMatches.Count -gt 1) {
            Write-Warning "[evidence-ledger] last entry contains $($hashMatches.Count) entry_hash values (corrupted); linking to the outermost one"
        }
    }

    $index = $null
    if (-not $isCorrupt) {
        $idxMatch = [regex]::Match($line, '"index"\s*:\s*(\d+)\s*[,}]')
        if ($idxMatch.Success) { $index = $idxMatch.Groups[1].Value }
    } else {
        Write-Warning "[evidence-ledger] last entry stores index as an array (pre-b730629 corruption); ignoring it and using chain length"
    }

    if ($null -eq $entryHash -and $null -eq $index) { return $null }
    return [PSCustomObject]@{ index = $index; entry_hash = $entryHash }
}

# --- Helper: get chain length ---
function Get-ChainLength {
    if (-not (Test-Path $ChainFile)) { return 0 }
    # Streamed, not Get-Content: this is the fallback path for a chain already
    # known to hold multi-megabyte entries, and loading all of them into memory to
    # count them would reintroduce the stall this function exists to escape.
    $n = 0
    try {
        foreach ($l in [System.IO.File]::ReadLines($ChainFile)) {
            if ($l -ne '') { $n++ }
        }
    } catch { return 0 }
    return $n
}

# ===== COMMANDS =====

switch ($Command) {
    "init" {
        # Two sessions starting together both see "no chain" and both call init;
        # without the lock the second genesis overwrote the first chain's entries.
        # And init never overwrites a chain that already has entries: starting over
        # on top of history is what left 24hHotnewsAI's live chain with no link to
        # its sealed segment (15.09). Closing a segment is `seal`, which keeps it.
        $Lock = Enter-LedgerLock
        try {
        if ((Test-Path $ChainFile) -and (Get-Item $ChainFile).Length -gt 0) {
            Write-Output "[evidence-ledger] chain.jsonl already has entries -- not overwriting. To start a new segment use: evidence-ledger seal -Reason '<why>'"
            break
        }
        $Genesis = @{
            index = 0
            prev_hash = "GENESIS"
            entry_hash = ""
            timestamp = (Get-Date -Format 'o')
            actor = @{
                agent = "harness"
                user = "system"
                session_id = "genesis"
                role = "system"
            }
            action = @{
                type = "config_change"
                tool = "harness-init"
                description = "Genesis block -- harness ledger initialized"
            }
            decision = @{
                result = "allow"
                reason = "System initialization"
                risk_level = "none"
            }
            payload_ref = ""
            signature = ""
        }
        $JsonWithoutHash = $Genesis | ConvertTo-Json -Depth 10 -Compress
        $Genesis.entry_hash = Get-EntryHash $JsonWithoutHash

        $GenesisJson = $Genesis | ConvertTo-Json -Depth 10 -Compress
        Write-Utf8NoBom -Path $ChainFile -Value "$GenesisJson`n"

        Write-Output "[evidence-ledger] Genesis block created at index 0"
        Write-Output "[evidence-ledger] Hash: $($Genesis.entry_hash)"
        Write-Output "[evidence-ledger] Chain file: $ChainFile"
        } finally { Exit-LedgerLock $Lock }
        break
    }

    "append" {
        $InputJson = Get-EntryInput -EntryJsonParam $EntryJson -EntryFileParam $EntryFile
        if (-not $InputJson -or $InputJson.Trim() -eq "") {
            Write-Error "[evidence-ledger] No input provided for append"
            exit 1
        }

        try {
            $Entry = $InputJson | ConvertFrom-Json
        } catch {
            Write-Error "[evidence-ledger] Invalid input JSON: $_"
            exit 1
        }

        # U1: from here to the append itself, EVERY failure must leave a trace.
        # The tool name is pulled out first so the marker can name it even when
        # the rest of the entry never gets built.
        $FailTool = ""
        try { if ($Entry.action.tool) { $FailTool = "$($Entry.action.tool)" } } catch { }
        $FailStage = "lock"
        $Lock = $null
        try {
        $Lock = Enter-LedgerLock
        # Everything from reading the last entry to writing the new line happens
        # under the lock -- the timestamp too, so file order and time order agree.
        $FailStage = "read-last-entry"

        $LastEntry = Get-LastEntry
        # Second line of defence, independent of Get-LastEntry: coerce to a scalar
        # int before adding. A chain that ALREADY contains a malformed index (this
        # repo's does, for 2836 entries) must not keep propagating it, so an
        # unparseable index falls back to the chain length -- which is what the
        # index means anyway. Never `+ 1` on something whose type is unverified.
        $NextIndex = 0
        if ($LastEntry) {
            $rawIdx = $LastEntry.index
            if ($rawIdx -is [array]) { $rawIdx = $rawIdx | Select-Object -Last 1 }
            $parsed = 0
            if ([int]::TryParse("$rawIdx", [ref]$parsed)) {
                $NextIndex = $parsed + 1
            } else {
                $NextIndex = Get-ChainLength
                Write-Warning "[evidence-ledger] previous entry has a non-numeric index ($($LastEntry.index -join ',')); using chain length $NextIndex instead"
            }
        }
        # "GENESIS" means one thing only: this is entry 0. Writing it because the
        # previous hash could not be READ would claim the chain starts here and
        # silently orphan everything before it -- the chain would then verify as
        # intact while having lost its history, which is worse than an obvious gap.
        # An unreadable predecessor is recorded as exactly that.
        $PrevHash = "GENESIS"
        if ($LastEntry) {
            if ($LastEntry.entry_hash) {
                $PrevHash = $LastEntry.entry_hash
            } else {
                $PrevHash = "UNREADABLE"
                Write-Warning "[evidence-ledger] previous entry has no readable entry_hash; linking as UNREADABLE so verify reports the break instead of hiding it"
            }
        }

        # Build canonical entry
        $NewEntry = @{
            index = $NextIndex
            prev_hash = $PrevHash
            entry_hash = ""  # Will compute after serialization
            timestamp = (Get-Date -Format 'o')
            actor = @{
                agent = if ($Entry.actor.agent) { $Entry.actor.agent } else { "unknown" }
                user = if ($Entry.actor.user) { $Entry.actor.user } else { "unknown" }
                session_id = if ($Entry.actor.session_id) { $Entry.actor.session_id } else { $env:HARNESS_SESSION_ID }
                role = if ($Entry.actor.role) { $Entry.actor.role } else { "" }
            }
            action = @{
                type = if ($Entry.action.type) { $Entry.action.type } else { "tool_call" }
                tool = if ($Entry.action.tool) { $Entry.action.tool } else { "" }
                description = if ($Entry.action.description) { $Entry.action.description } else { "" }
                input_hash = if ($Entry.action.input_hash) { $Entry.action.input_hash } else { "" }
                output_hash = if ($Entry.action.output_hash) { $Entry.action.output_hash } else { "" }
            }
            decision = @{
                result = if ($Entry.decision.result) { $Entry.decision.result } else { "allow" }
                reason = if ($Entry.decision.reason) { $Entry.decision.reason } else { "" }
                risk_level = if ($Entry.decision.risk_level) { $Entry.decision.risk_level } else { "none" }
            }
            payload_ref = if ($Entry.payload_ref) { $Entry.payload_ref } else { "" }
            signature = if ($Entry.signature) { $Entry.signature } else { "" }
        }

        $FailStage = "serialize-and-hash"
        $JsonWithoutHash = $NewEntry | ConvertTo-Json -Depth 10 -Compress
        $NewEntry.entry_hash = Get-EntryHash $JsonWithoutHash

        $OutEntryJson = $NewEntry | ConvertTo-Json -Depth 10 -Compress
        $FailStage = "write-chain"
        Add-Utf8NoBom -Path $ChainFile -Value "$OutEntryJson`n"

        Write-Output "[evidence-ledger] Appended entry $NextIndex"
        Write-Output "[evidence-ledger] Hash: $($NewEntry.entry_hash) | Prev: $PrevHash"
        Write-Output $OutEntryJson

        } catch {
            # The side-effect already happened; only its record failed. Say so
            # somewhere durable, then exit non-zero so a caller that DOES check
            # can react. Callers today redirect output to $null and ignore the
            # code -- which is exactly why the marker file exists rather than a
            # message.
            $reason = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
            $wrote = Write-AppendFailure -Tool $FailTool -Reason $reason -Stage $FailStage
            Write-Warning ("[evidence-ledger] APPEND FAILED at {0} for tool={1} :: {2}{3}" -f `
                $FailStage, $FailTool, $reason,
                $(if ($wrote) { " (recorded in append-failures.jsonl)" } else { " (COULD NOT RECORD)" }))
            Exit-LedgerLock $Lock
            exit 3
        } finally {
            Exit-LedgerLock $Lock
            $Lock = $null
        }
        break
    }

    "verify" {
        if (-not (Test-Path $ChainFile)) {
            Write-Error "[evidence-ledger] No chain file found at $ChainFile"
            exit 1
        }

        $Lines = Get-Content -Path $ChainFile -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' }
        $TotalEntries = $Lines.Count
        $Valid = $true
        $PreviousHash = "GENESIS"

        for ($i = 0; $i -lt $TotalEntries; $i++) {
            $Entry = $Lines[$i] | ConvertFrom-Json

            # Verify prev_hash chain
            if ($Entry.prev_hash -ne $PreviousHash) {
                Write-Error "[evidence-ledger] CHAIN BREAK at entry $($Entry.index): prev_hash mismatch"
                Write-Error "[evidence-ledger]   Expected: $PreviousHash"
                Write-Error "[evidence-ledger]   Got:      $($Entry.prev_hash)"
                $Valid = $false
            }

            # Verify entry_hash
            $StoredHash = $Entry.entry_hash
            $Entry.entry_hash = ""
            $JsonWithoutHash = $Entry | ConvertTo-Json -Depth 10 -Compress
            $ComputedHash = Get-EntryHash $JsonWithoutHash

            if ($ComputedHash -ne $StoredHash) {
                Write-Error "[evidence-ledger] TAMPER DETECTED at entry $($Entry.index): entry_hash mismatch"
                Write-Error "[evidence-ledger]   Computed: $ComputedHash"
                Write-Error "[evidence-ledger]   Stored:   $StoredHash"
                $Valid = $false
            }

            $PreviousHash = $StoredHash
        }

        if ($Valid) {
            Write-Output "[evidence-ledger] LEDGER INTACT -- $TotalEntries entries, all hashes verified"
        } else {
            Write-Error "[evidence-ledger] LEDGER COMPROMISED -- integrity check FAILED"
            exit 2
        }
        break
    }

    "seal" {
        # Close the segment around bad history instead of editing it. A poisoned
        # entry (pre-b730629 doubling bug) is permanent once written; rewriting or
        # deleting it would make the "immutable" ledger a file someone fixes when
        # it embarrasses them, which is worth less than no ledger at all. Seal =
        # one final entry saying why, archive the file untouched, fresh segment.
        if (-not (Test-Path $ChainFile)) {
            Write-Output "[evidence-ledger] Nothing to seal -- no chain.jsonl"
            break
        }

        $SealReason = if ($Reason) { $Reason } else { "segment sealed (no reason given)" }

        # Held from reading the head to the final rename: an append landing between
        # the seal entry and the archive move would go into the archived file after
        # its seal, or start an unlinked chain.
        $Lock = Enter-LedgerLock
        try {
        # Same index/prev resolution as append -- including the corruption
        # fallbacks, since sealing a poisoned chain is this command's whole job.
        $LastEntry = Get-LastEntry
        $NextIndex = 0
        if ($LastEntry) {
            $parsed = 0
            if ([int]::TryParse("$($LastEntry.index)", [ref]$parsed)) { $NextIndex = $parsed + 1 }
            else { $NextIndex = Get-ChainLength }
        }
        $PrevHash = "GENESIS"
        if ($LastEntry) {
            $PrevHash = if ($LastEntry.entry_hash) { $LastEntry.entry_hash } else { "UNREADABLE" }
        }

        $SealEntry = @{
            index = $NextIndex
            prev_hash = $PrevHash
            entry_hash = ""
            timestamp = (Get-Date -Format 'o')
            actor = @{ agent = "harness"; user = "$env:HARNESS_USER"; session_id = "$env:HARNESS_SESSION_ID"; role = "system" }
            action = @{ type = "seal"; tool = "evidence-ledger"; description = $SealReason }
            decision = @{ result = "allow"; reason = "segment sealed"; risk_level = "none" }
            payload_ref = ""
            signature = ""
        }
        $JsonNoHash = $SealEntry | ConvertTo-Json -Depth 10 -Compress
        $SealEntry.entry_hash = Get-EntryHash $JsonNoHash
        Add-Utf8NoBom -Path $ChainFile -Value "$($SealEntry | ConvertTo-Json -Depth 10 -Compress)`n"

        # Next free archive number -- never overwrite an existing archive.
        $ArchiveNum = 1
        Get-ChildItem -Path $LedgerDir -Filter "chain-*.jsonl" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^chain-(\d+)\.jsonl$') {
                $n = [int]$Matches[1]
                if ($n -ge $ArchiveNum) { $ArchiveNum = $n + 1 }
            }
        }
        $ArchiveName = "chain-{0:D3}.jsonl" -f $ArchiveNum

        # New genesis is STAGED before the archive rename so the window where
        # chain.jsonl does not exist is one Move-Item, not a build-then-write.
        # A hook appending into that window would create its own unlinked chain.
        $Genesis = @{
            index = 0
            prev_hash = "GENESIS"
            entry_hash = ""
            timestamp = (Get-Date -Format 'o')
            actor = @{ agent = "harness"; user = "system"; session_id = "seal"; role = "system" }
            action = @{ type = "config_change"; tool = "evidence-ledger"; description = "Genesis block -- segment continues from $ArchiveName" }
            decision = @{ result = "allow"; reason = "segment rotation"; risk_level = "none" }
            payload_ref = ""
            signature = ""
            prev_segment = $ArchiveName
            prev_segment_head = $SealEntry.entry_hash
        }
        $GenNoHash = $Genesis | ConvertTo-Json -Depth 10 -Compress
        $Genesis.entry_hash = Get-EntryHash $GenNoHash
        $StagedGenesis = Join-Path $LedgerDir ".chain.genesis.tmp"
        Write-Utf8NoBom -Path $StagedGenesis -Value "$($Genesis | ConvertTo-Json -Depth 10 -Compress)`n"

        Move-Item -Path $ChainFile -Destination (Join-Path $LedgerDir $ArchiveName)
        Move-Item -Path $StagedGenesis -Destination $ChainFile

        Write-Output "[evidence-ledger] Sealed segment -> $ArchiveName (head $($SealEntry.entry_hash))"
        Write-Output "[evidence-ledger] New segment started; genesis links prev_segment_head for cross-file continuity"
        } finally { Exit-LedgerLock $Lock }
        break
    }

    "bundle" {
        # Generate an evidence bundle for a change
        $InputJson = Get-EntryInput -EntryJsonParam $EntryJson -EntryFileParam $EntryFile
        if (-not $InputJson -or $InputJson.Trim() -eq "") {
            Write-Error "[evidence-ledger] No input provided for bundle"
            exit 1
        }

        $Input = $InputJson | ConvertFrom-Json
        $BundleId = [guid]::NewGuid().ToString()
        $ChangeId = if ($Input.change_id) { $Input.change_id } else { "change-$(Get-Date -Format 'yyyyMMddHHmmss')" }

        $Bundle = @{
            bundle_id = $BundleId
            change_id = $ChangeId
            created_at = (Get-Date -Format 'o')
            created_by = @{
                agent = if ($Input.created_by.agent) { $Input.created_by.agent } else { "unknown" }
                user = if ($Input.created_by.user) { $Input.created_by.user } else { "unknown" }
                # $env:HARNESS_SESSION_ID is "" when unset in PowerShell, but a bare
                # `if (unset-env-var)` test is falsy for "" too, so this fell through
                # to the bare $env: reference as the else-value -- which is $null
                # when the variable was never set at all (vs "" when set-but-empty).
                # The schema requires session_id to be a string; null failed it. A
                # final `+ ""` is the smallest fix that can never turn a real value
                # into empty (string concatenation with a non-null string is a no-op).
                session_id = $(if ($Input.created_by.session_id) { $Input.created_by.session_id } else { $env:HARNESS_SESSION_ID }) + ""
            }
            requirement_trace = @{
                spec_ref = if ($Input.requirement_trace.spec_ref) { $Input.requirement_trace.spec_ref } else { "" }
                # @(...) around the WHOLE if/else, not just the else branch: an
                # if/else used as a value here returns whatever the taken branch
                # "outputs", and PowerShell's pipeline unrolling silently turns an
                # empty-array branch into $null, which ConvertTo-Json then renders
                # as "{}" -- schema type "array" -- instead of "[]". Found live: 3
                # of 6 bundles already on disk across the fleet have this exact
                # {} where the schema requires an array. @() forces array context
                # on the result regardless of which branch ran or how many
                # elements it has.
                requirement_ids = @( if ($Input.requirement_trace.requirement_ids) { $Input.requirement_trace.requirement_ids } else { @() } )
            }
            design_impact = @{
                description = if ($Input.design_impact.description) { $Input.design_impact.description } else { "" }
                affected_components = @( if ($Input.design_impact.affected_components) { $Input.design_impact.affected_components } else { @() } )
                design_doc_ref = if ($Input.design_impact.design_doc_ref) { $Input.design_impact.design_doc_ref } else { "" }
            }
            code_diff = @{
                files_changed = @( if ($Input.code_diff.files_changed) { $Input.code_diff.files_changed } else { @() } )
                diff_ref = if ($Input.code_diff.diff_ref) { $Input.code_diff.diff_ref } else { "" }
                diff_hash = if ($Input.code_diff.diff_hash) { $Input.code_diff.diff_hash } else { "" }
            }
            test_report = @{
                passed = if ($Input.test_report.passed) { $Input.test_report.passed } else { 0 }
                failed = if ($Input.test_report.failed) { $Input.test_report.failed } else { 0 }
                skipped = if ($Input.test_report.skipped) { $Input.test_report.skipped } else { 0 }
                coverage_percent = if ($Input.test_report.coverage_percent) { $Input.test_report.coverage_percent } else { 0 }
                report_ref = if ($Input.test_report.report_ref) { $Input.test_report.report_ref } else { "" }
            }
            security_scan = @{
                scanner = if ($Input.security_scan.scanner) { $Input.security_scan.scanner } else { "" }
                findings_count = if ($Input.security_scan.findings_count) { $Input.security_scan.findings_count } else { 0 }
                high_critical_count = if ($Input.security_scan.high_critical_count) { $Input.security_scan.high_critical_count } else { 0 }
                passed = if ($Input.security_scan.passed) { $Input.security_scan.passed } else { $true }
                report_ref = if ($Input.security_scan.report_ref) { $Input.security_scan.report_ref } else { "" }
            }
            review_verdict = @{
                verdict = if ($Input.review_verdict.verdict) { $Input.review_verdict.verdict } else { "PENDING" }
                score = if ($Input.review_verdict.score) { $Input.review_verdict.score } else { 0 }
                reviewer_agent = if ($Input.review_verdict.reviewer_agent) { $Input.review_verdict.reviewer_agent } else { "" }
                feedback = if ($Input.review_verdict.feedback) { $Input.review_verdict.feedback } else { "" }
                # H3-2 depth: pass the judge's per-dimension rubric through into the
                # bundle. This block used to whitelist only the four fields above and
                # silently drop rubric_scores -- a judge following qa-gate/
                # verify-implementation SKILL.md to the letter (which tells it to put
                # the 5 scores here) still produced a bundle with none, so
                # ingest_prompt_scores always stored an empty rubric and H3-2 could
                # never be met from real evaluation activity. Only numeric per-
                # dimension values are kept (same filter hard-gate.ps1 already
                # applies when READING this field) -- a dimension the judge did not
                # score is dropped rather than defaulted to 0, per SKILL.md ("never
                # invent a dimension score"). rubric_scores itself is always present,
                # empty {} when the judge gave nothing: ingest.py already treats a
                # missing key and an empty object the same way, and an explicit {}
                # says the writer looked rather than never asked.
                rubric_scores = $(
                    $rs = [ordered]@{}
                    if ($null -ne $Input.review_verdict.rubric_scores) {
                        foreach ($p in $Input.review_verdict.rubric_scores.PSObject.Properties) {
                            $v = $p.Value
                            if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
                                $rs[$p.Name] = [double]$v
                            }
                        }
                    }
                    $rs
                )
            }
            approval_record = @{
                required = if ($Input.approval_record.required) { $Input.approval_record.required } else { $false }
                approved_by = if ($Input.approval_record.approved_by) { $Input.approval_record.approved_by } else { "" }
                approved_at = if ($Input.approval_record.approved_at) { $Input.approval_record.approved_at } else { "" }
                approval_ref = if ($Input.approval_record.approval_ref) { $Input.approval_record.approval_ref } else { "" }
            }
            cost_telemetry = @{
                tokens_used = if ($Input.cost_telemetry.tokens_used) { $Input.cost_telemetry.tokens_used } else { 0 }
                estimated_cost_usd = if ($Input.cost_telemetry.estimated_cost_usd) { $Input.cost_telemetry.estimated_cost_usd } else { 0 }
                duration_seconds = if ($Input.cost_telemetry.duration_seconds) { $Input.cost_telemetry.duration_seconds } else { 0 }
            }
        }

        $BundleJson = $Bundle | ConvertTo-Json -Depth 10
        $BundleFile = "$BundleDir\$ChangeId-bundle.json"
        Write-Utf8NoBom -Path $BundleFile -Value $BundleJson

        Write-Output "[evidence-ledger] Evidence bundle created: $BundleFile"
        Write-Output "[evidence-ledger] Bundle ID: $BundleId"
        Write-Output "[evidence-ledger] Change ID: $ChangeId"
        Write-Output $BundleJson
        break
    }

    "export" {
        if (-not (Test-Path $ChainFile)) {
            Write-Error "[evidence-ledger] No chain file found"
            exit 1
        }
        $Lines = Get-Content -Path $ChainFile -Encoding utf8 | Where-Object { $_ -ne '' }
        $CsvFile = "$LedgerDir\ledger-export-$(Get-Date -Format 'yyyyMMddHHmmss').csv"
        Write-Utf8NoBom -Path $CsvFile -Value "index,timestamp,agent,action_type,tool,decision_result,risk_level,entry_hash,prev_hash`n"
        foreach ($line in $Lines) {
            $e = $line | ConvertFrom-Json
            Add-Utf8NoBom -Path $CsvFile -Value "$($e.index),$($e.timestamp),$($e.actor.agent),$($e.action.type),$($e.action.tool),$($e.decision.result),$($e.decision.risk_level),$($e.entry_hash),$($e.prev_hash)`n"
        }
        Write-Output "[evidence-ledger] Exported $($Lines.Count) entries to $CsvFile"
        break
    }
}

# Every success path above leaves the switch via `break`, which does NOT set an
# exit code -- so a caller checking $LASTEXITCODE saw whatever was there before
# (or $null) and could not tell success from failure. The failure paths already
# `exit 1`/`exit 2` and never reach this line, so reaching it means success.
exit 0
