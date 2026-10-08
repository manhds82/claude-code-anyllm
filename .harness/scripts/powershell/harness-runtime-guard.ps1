#!/usr/bin/env pwsh
<#
.SYNOPSIS
  PreToolUse hook — Runtime Guard (H4). PEP for side-effect prevention.
.DESCRIPTION
  Reads risk-policy.yaml (SSOT) to decide allow/deny for each tool call.
  Reads stdin JSON { tool, input, ... } from Claude Code PreToolUse hook.
  Returns:
    - exit 0: allow (no match found)
    - exit 2: deny (match found, hard stop)
    - JSON with permissionDecision: "deny" on stdout for soft denial
.NOTES
  C2: Reads YAML config — never hardcode deny rules in this script.
  C10: Local hook is defense-in-depth; high-risk actions need server-side PDP.
#>

$InputJson = $input | Out-String
$InputJson = $InputJson.Trim()
if (-not $InputJson) {
    exit 0
}

try {
    $CallRecord = $InputJson | ConvertFrom-Json
} catch {
    exit 0
}

# Claude Code's PreToolUse payload uses tool_name / tool_input; accept the
# older tool / input shape too.
$ToolName = if ($CallRecord.tool_name) { $CallRecord.tool_name } else { $CallRecord.tool }
$ToolInput = if ($CallRecord.tool_input) { $CallRecord.tool_input } else { $CallRecord.input }

# Resolve harness root
$HarnessRoot = $env:HARNESS_ROOT
if (-not $HarnessRoot) {
    $HarnessRoot = Resolve-Path "$PSScriptRoot\..\..\.."
}

# Load risk policy from YAML (SSOT — C2)
$RiskPolicyPath = "$HarnessRoot\.harness\control\risk-policy.yaml"
if (-not (Test-Path $RiskPolicyPath)) {
    # No policy file = permissive mode (fail-open for read)
    exit 0
}

try {
    $RawYaml = Get-Content -Path $RiskPolicyPath -Raw -Encoding utf8
    # Simple YAML parsing: extract all `- pattern: "..."` entries
    $DenyPatterns = @()
    foreach ($line in $RawYaml -split "`n") {
        if ($line.Trim() -match '^-\s+pattern:\s+"(.+)"$') {
            # Unescape YAML double-backslash to single backslash for regex
            $pattern = $matches[1] -replace '\\\\', '\'
            $DenyPatterns += $pattern
        }
    }
} catch {
    Write-Warning "[harness-runtime-guard] Cannot read risk-policy.yaml: $_"
    exit 0
}

# Build command string from tool input for pattern matching.
# Command deny-patterns describe SHELL COMMANDS, so only read the command/script
# fields. Do NOT fall back to serializing the whole tool-input JSON: for Write/
# Edit that is file CONTENT, and scanning documentation/source text against
# shell-command regexes produced false positives (a file that merely quotes a
# dangerous one-liner is not executing it). Non-command tools are still governed
# by tool-registry risk levels below (deny-by-default for registered side-effects).
$CommandString = ""
if ($ToolInput) {
    if ($ToolInput.command) { $CommandString = [string]$ToolInput.command }
    elseif ($ToolInput.script) { $CommandString = [string]$ToolInput.script }
}

# Security-event logging helper (H4) -- dot-source once, defensive.
$GuardLibPath = Join-Path $PSScriptRoot "lib-security-log.ps1"
if (Test-Path $GuardLibPath) { . $GuardLibPath }

# STDERR is the only channel that reaches the agent. Claude Code surfaces a
# non-zero PreToolUse exit as "No stderr output" when nothing was written there,
# and Write-Warning does NOT land on stderr -- the host renders it to stdout.
# So a deny told the agent it was blocked but never by what: it would guess,
# rewrite the command and retry, and every occurrence looked like a brand-new
# mystery. Every deny path must name the rule it matched, on stderr.
function Write-DenyToStderr {
    param([string]$Reason, [string]$Tool, [string]$Command = "")
    $snip = ""
    if ($Command) {
        # Capped at 200 chars: the command may carry a secret and this text is
        # echoed verbatim into the agent transcript.
        $snip = $Command.Substring(0, [Math]::Min($Command.Length, 200))
        $snip = " | command: $snip"
    }
    [Console]::Error.WriteLine("[harness-runtime-guard] DENIED tool=$Tool :: $Reason$snip")
}

# C9: persist a deny entry to the evidence ledger (chain.jsonl) so the Portal
# blocked-count reflects real guard denies. Best-effort — a ledger failure must
# never change the guard verdict.
function Write-LedgerDeny {
    param([string]$Tool, [string]$Pattern, [string]$Command)
    try {
        $LedgerScript = Join-Path $PSScriptRoot "evidence-ledger.ps1"
        if (-not (Test-Path $LedgerScript)) { return }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $inputHash = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Command"))) -replace '-', '').ToLower()
        $entry = @{
            actor = @{ agent = "claude-code"; user = "$env:HARNESS_USER"; session_id = "$env:HARNESS_SESSION_ID"; role = "member" }
            action = @{ type = "tool_call"; tool = $Tool; description = "blocked by runtime guard"; input_hash = $inputHash; output_hash = "" }
            decision = @{ result = "deny"; reason = "deny pattern: $Pattern"; risk_level = "high" }
        } | ConvertTo-Json -Compress -Depth 4
        & $LedgerScript append -EntryJson $entry *>$null
    } catch {
        # Swallow — evidence is best-effort, verdict is not.
    }
}

# Check command deny patterns. A single malformed regex must never brick the
# developer's shell -- match inside try/catch and skip a pattern that won't
# compile (fail-open per pattern; the rest still enforce).
foreach ($pattern in $DenyPatterns) {
    $isMatch = $false
    try { $isMatch = ($CommandString -match $pattern) } catch { continue }
    if ($isMatch) {
        $DenyReason = "Command matched deny pattern: $pattern"
        Write-Warning "[harness-runtime-guard] DENIED: $DenyReason"
        Write-DenyToStderr -Reason $DenyReason -Tool $ToolName -Command $CommandString

        if (Get-Command Write-SecurityEvent -ErrorAction SilentlyContinue) {
            $cmdSnip = $CommandString.Substring(0, [Math]::Min($CommandString.Length, 240))
            Write-SecurityEvent -HarnessRoot $HarnessRoot -Type "guard_block" -Severity "high" `
                -Category $ToolName -DetectedBy "harness-runtime-guard" `
                -Excerpt "blocked command: `"$cmdSnip`" | matched deny-pattern: $pattern"
        }
        Write-LedgerDeny -Tool $ToolName -Pattern $pattern -Command $CommandString

        # Output JSON for PreToolUse permission decision
        $Decision = @{
            permissionDecision = "deny"
            reason = $DenyReason
            tool = $ToolName
        } | ConvertTo-Json -Compress
        Write-Output $Decision

        # Exit 2 signals hard deny to Claude Code
        exit 2
    }
}

# Claude Code names an MCP tool `mcp__<server>__<tool>`; the tool registry keys
# it `<server>.<tool>` (C3). Those two strings are never equal, so the registry
# lookup below silently missed EVERY MCP tool -- all ten deny-by-default
# entries, `deploy` and `mysql_query` among them, both marked critical. The
# layer existed, was configured, and had never once fired.
#
# Returns the candidate keys in order of precision:
#   1. the raw name          -- native tools (Bash, Write, Read...) key as-is
#   2. `<server>.<tool>`     -- the registry's own MCP convention
#   3. `<tool>` alone        -- a registry that keys MCP tools bare
#   4. any `*.<tool>`         -- the SAME server can be mounted under a second
#      name (this session carries codeprovider-mcp a second time under a UUID
#      alias, and `mcp__<uuid>__deploy` matches none of 1-3), and a policy that
#      depends on which alias the caller happened to use is not a policy.
#      Verified unambiguous before relying on it: no tool name in the registry
#      appears under more than one server, and no bare key collides with a
#      dotted tail. If that ever stops holding, this rule must be revisited --
#      it would then be picking one of several policies by accident.
function Get-RegistryKeyCandidates {
    param([string]$Name, $Registry)
    $candidates = @($Name)
    if ($Name -match '^mcp__(.+?)__(.+)$') {
        $short = $matches[2]
        $candidates += "$($matches[1]).$short"
        $candidates += $short
        if ($Registry) {
            $suffix = ".$short"
            foreach ($prop in $Registry.PSObject.Properties) {
                if ($prop.Name.EndsWith($suffix)) { $candidates += $prop.Name }
            }
        }
    }
    return $candidates
}

# The short name, for policy that lists bare tool names.
$ShortToolName = $ToolName
if ($ToolName -match '^mcp__(.+?)__(.+)$') { $ShortToolName = $matches[2] }

# Check tool-level deny defaults for non-Bash tools
$ToolDenyPath = "$HarnessRoot\.harness\control\tool-registry.json"
if (Test-Path $ToolDenyPath) {
    try {
        $ToolRegistry = Get-Content -Path $ToolDenyPath -Raw -Encoding utf8 | ConvertFrom-Json
        $ToolEntry = $null
        $MatchedKey = ""
        foreach ($candidate in (Get-RegistryKeyCandidates -Name $ToolName -Registry $ToolRegistry.tools)) {
            $prop = $ToolRegistry.tools.PSObject.Properties[$candidate]
            if ($prop) { $ToolEntry = $prop.Value; $MatchedKey = $candidate; break }
        }
        if ($ToolEntry) {
            if ($ToolEntry.risk_level -in @("high", "critical") -and $ToolEntry.default_action -eq "deny") {
                $DenyReason = "Tool '$ToolName' (registry key '$MatchedKey') has risk level '$($ToolEntry.risk_level)' — deny-by-default"
                Write-Warning "[harness-runtime-guard] DENIED: $DenyReason"
                Write-DenyToStderr -Reason $DenyReason -Tool $ToolName -Command $CommandString
                if (Get-Command Write-SecurityEvent -ErrorAction SilentlyContinue) {
                    Write-SecurityEvent -HarnessRoot $HarnessRoot -Type "guard_block" -Severity $ToolEntry.risk_level `
                        -Category $ToolName -DetectedBy "harness-runtime-guard" `
                        -Excerpt "blocked tool '$ToolName' | registry key: $MatchedKey | reason: deny-by-default (risk=$($ToolEntry.risk_level)) in tool-registry"
                }
                Write-LedgerDeny -Tool $ToolName -Pattern "deny-by-default ($($ToolEntry.risk_level))" -Command $CommandString
                $Decision = @{
                    permissionDecision = "deny"
                    reason = $DenyReason
                    tool = $ToolName
                } | ConvertTo-Json -Compress
                Write-Output $Decision
                exit 2
            }
        }
    } catch {
        # Tool registry not available or parse error — permissive
    }
}

# --- Server-side PDP consult (H4 outbound allowlist + H5 approval workflow) ---
# Opt-in: only when .harness/portal-sync.json sets "pdp_enforce": true. The
# decision lives on the Portal; the hook honors deny/ask. Best-effort/fail-open
# on any network error (C10: this is defense-in-depth + a server decision, not a
# hard boundary — hard enforcement needs the tool path itself routed via the PDP).
try {
    # Resolve WHERE portal-sync.json lives. Normally it is under $HarnessRoot.
    # Portal v2 P1 1.7: portal-sync.json now holds NO per-machine field (member_email moved to
    # .harness/local/) and may be committed -- but projects that predate it still gitignore it, and
    # the ingest KEY (portal-sync.key) never travels with git. So in a git WORKTREE it does
    # not exist here -- it lives only in the MAIN checkout. The guard used to
    # look only under $HarnessRoot, find nothing, and skip the ENTIRE PDP
    # consult with no trace. A gate that does not run must never be
    # indistinguishable from one that ran and allowed (C12). So a worktree
    # resolves its sibling main checkout (via git's own common-dir, the
    # authority -- not a guessed path, C13) and reads the same project's config
    # from there. commit_head below deliberately keeps using $HarnessRoot: THIS
    # worktree's HEAD is what a deploy launched from here would ship, so the two
    # roots are intentionally different and must not be merged.
    $SyncRoot = $HarnessRoot
    if ((-not (Test-Path "$SyncRoot\.harness\portal-sync.json")) -and (Test-Path "$HarnessRoot\.git" -PathType Leaf)) {
        try {
            $CommonDir = (& git -C $HarnessRoot rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1)
            if ($CommonDir) { $SyncRoot = Split-Path -Parent $CommonDir.Trim() }
        } catch { }
    }
    $SyncCfgPath = "$SyncRoot\.harness\portal-sync.json"
    if ((Test-Path $SyncCfgPath) -and $CommandString) {
        $SyncCfg = Get-Content -Path $SyncCfgPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($SyncCfg.pdp_enforce -eq $true -and $SyncCfg.portal_url -and $SyncCfg.project_id) {
            # Only consult for high-risk shapes to avoid latency on ordinary calls.
            #
            # `docker\s+compose\s+up` used to be matched LITERALLY, so the form
            # every script here actually uses -- `docker compose -f a.yml -f
            # b.yml up -d` (deploy-portal.ps1) -- was never sent, and a compose
            # release issued through a shell got NO PDP decision at all: no
            # release gate, no approval, not even a decision row. Any compose
            # command is now sent and the server decides which are mutations.
            #
            # This filter stays deliberately BROAD (a bare `deploy` still
            # matches a command that only names a deploy file). Over-asking
            # costs one round trip and the server answers `allow`; under-asking
            # silently ungates a release. The precise mention-vs-invocation rule
            # lives server-side in ONE place (app/core/pdp.py::_command_ships)
            # rather than being re-implemented in PowerShell and bash, where
            # three copies would drift.
            #
            # $ShortToolName, not $ToolName: Claude Code sends an MCP tool as
            # `mcp__<server>__deploy`, which matches none of these names. Keep
            # both halves of this line -- the widened command shapes AND the
            # resolved tool name; each fixes a different way a real release
            # reached no gate at all.
            $HighRisk = ($CommandString -match '(?i)\b(curl|wget|Invoke-WebRequest|iwr|nc|ncat|http_fetch|deploy|drop\s+table|truncate\s+table|delete\s+from|alter\s+table)\b') `
                -or ($CommandString -match '(?i)\bdocker[-\s]+compose\b') `
                -or ($CommandString -match '(?i)(deploy|release|\bkubectl\s+apply\b|\bhelm\s+(install|upgrade)\b|\bterraform\s+apply\b|\bansible-playbook\b)') `
                -or ($ShortToolName -in @('deploy','rollback_deploy','mysql_query','exec_in_container','http_fetch'))
            if ($HighRisk) {
                # Portal v2 P1 1.2b: authenticate with the CHECKOUT credential (X-Checkout-Id +
                # X-Checkout-Credential, and NOT the shared key) when this machine holds one; the
                # server derives checkout and member from it, so a "declared" actor cannot borrow
                # someone else's approval. The shared key is the legacy fallback only.
                # The credential is read by the shared reader (harness_checkout_facts.py --auth:
                # dpapi-v1 / plain-v1 / legacy) and only on THIS path -- a high-risk shape with a
                # credential present -- so the common tool call spawns nothing extra. The value
                # goes into the request headers and nowhere else (C5).
                $AuthHeaders = $null
                $AuthSource = ""
                $AuthLib = Join-Path $PSScriptRoot "..\lib\harness_checkout_facts.py"
                if (($env:HARNESS_CHECKOUT_CREDENTIAL -or (Test-Path "$SyncRoot\.harness\local\checkout.json") `
                        -or (Test-Path "$HarnessRoot\.harness\local\checkout.json") `
                        -or (Test-Path "$HarnessRoot\.git" -PathType Leaf)) -and (Test-Path $AuthLib)) {
                    $pyc = Get-Command python -ErrorAction SilentlyContinue
                    if (-not $pyc) { $pyc = Get-Command python3 -ErrorAction SilentlyContinue }
                    if ($pyc) {
                        $aj = (& $pyc.Source $AuthLib --auth $HarnessRoot 2>$null) -join ""
                        if ($aj) {
                            $Au = $aj | ConvertFrom-Json
                            if ($Au.checkout_id -and $Au.checkout_credential) {
                                $AuthHeaders = @{ "X-Checkout-Id" = "$($Au.checkout_id)"; "X-Checkout-Credential" = "$($Au.checkout_credential)" }
                                $AuthSource = "checkout"
                            }
                        }
                    }
                }
                if (-not $AuthHeaders) {
                    $Key = $env:HARNESS_PORTAL_INGEST_KEY
                    if (-not $Key) {
                        $KeyFile = "$SyncRoot\.harness\portal-sync.key"
                        if (Test-Path $KeyFile) { $Key = (Get-Content -Path $KeyFile -Raw).Trim() }
                    }
                    if ($Key) { $AuthHeaders = @{ "X-Ingest-Key" = $Key }; $AuthSource = "legacy-key" }
                }
                if ($AuthHeaders) {
                    # Legacy path: say so at most once a day per machine (a stamp file shared with
                    # the python clients, same dir and name as harness_checkout_facts.legacy_warning),
                    # never on every tool call (C14). The warning names no key.
                    if ($AuthSource -eq "legacy-key") {
                        try {
                            $StD = $env:HARNESS_STATE_DIR
                            if (-not $StD) {
                                $StB = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME ".local\state" }
                                $StD = Join-Path $StB "harness"
                            }
                            $St = Join-Path $StD "legacy-key-warn.stamp"
                            $WarnDue = $true
                            if (Test-Path $St) { if (((Get-Date) - (Get-Item $St).LastWriteTime).TotalSeconds -lt 86400) { $WarnDue = $false } }
                            if ($WarnDue) {
                                New-Item -ItemType Directory -Force -Path $StD | Out-Null
                                Set-Content -Path $St -Value ([DateTime]::UtcNow.ToString("o"))
                                [Console]::Error.WriteLine("[harness-runtime-guard] no checkout credential on this machine -- using the shared ingest key (legacy path; enrol with tools/harness-bundle/enroll-checkout). Shown once a day.")
                            }
                        } catch { }
                    }
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                    $Url = "$($SyncCfg.portal_url.TrimEnd('/'))/api/pdp/$($SyncCfg.project_id)/decide"
                    # Actor identity: prefer the per-machine human identity (same convention as the
                    # ledger-deny actor above) so the Portal can resolve a real requester, not a
                    # session id nobody can read (C10). Fall back to session id only when the
                    # developer machine has no HARNESS_USER configured, so we still send *something*.
                    $Actor = if ($env:HARNESS_USER) { $env:HARNESS_USER } else { $env:HARNESS_SESSION_ID }
                    $ActorHost = "$env:COMPUTERNAME"
                    # H3 pipeline-record gate: the commit THIS release would actually ship is
                    # whatever HEAD resolves to right now on this checkout (deploy takes no
                    # commit parameter of its own -- it pulls HEAD). Resolved here, not asserted
                    # by the caller, so the server has something it can trust as "what commit".
                    # Best-effort: git absent or not a repo just means an empty string, which the
                    # gate (when its opt-in toggle is on) correctly reports as unverifiable rather
                    # than guessing.
                    # Bounded at 5s to match the bash counterpart's
                    # subprocess timeout (C7 parity). Unbounded, a git holding a
                    # lock stalls the operator's shell here, BEFORE the 8s HTTP
                    # timeout below has even started counting.
                    $CommitHead = ""
                    try {
                        $OutFile = [IO.Path]::GetTempFileName()
                        $g = Start-Process -FilePath "git" -NoNewWindow -PassThru `
                            -ArgumentList @("-C", $HarnessRoot, "rev-parse", "HEAD") `
                            -RedirectStandardOutput $OutFile -RedirectStandardError "NUL"
                        if ($g.WaitForExit(5000)) {
                            $CommitHead = ((Get-Content -Path $OutFile -ErrorAction SilentlyContinue | Select-Object -First 1) + "").Trim()
                        } else {
                            try { $g.Kill() } catch {}
                        }
                        Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
                    } catch {}
                    $Body = @{ tool = "$ToolName"; command = "$CommandString"; actor = "$Actor"; actor_host = "$ActorHost"; commit_head = "$CommitHead" } | ConvertTo-Json -Compress
                    # Decode the reply as UTF-8 ourselves. PS 5.1's Invoke-RestMethod falls back to
                    # ISO-8859-1 when Content-Type carries no charset (FastAPI's JSON default), so a
                    # "—" in the PDP reason came back as "â\u0080\u0094" and was stored that way in
                    # security-events.jsonl, where the Portal's Security tab showed it (B-21).
                    $Raw = Invoke-WebRequest -Uri $Url -Method Post -ContentType "application/json; charset=utf-8" `
                        -Headers $AuthHeaders -UserAgent "harness-runtime-guard/1.0" `
                        -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 8 -UseBasicParsing
                    $Resp = [System.Text.Encoding]::UTF8.GetString($Raw.RawContentStream.ToArray()) | ConvertFrom-Json
                    if ($Resp.decision -eq 'deny' -or $Resp.decision -eq 'ask') {
                        $DenyReason = "PDP $($Resp.decision): $($Resp.reason)"
                        Write-Warning "[harness-runtime-guard] $DenyReason"
                        Write-DenyToStderr -Reason $DenyReason -Tool $ToolName -Command $CommandString
                        if (Get-Command Write-SecurityEvent -ErrorAction SilentlyContinue) {
                            Write-SecurityEvent -HarnessRoot $HarnessRoot -Type "pdp_block" -Severity "high" `
                                -Category $ToolName -DetectedBy "harness-runtime-guard-pdp" `
                                -Excerpt "PDP $($Resp.decision): $($Resp.reason) | approval_id=$($Resp.approval_id)"
                        }
                        Write-LedgerDeny -Tool $ToolName -Pattern "pdp:$($Resp.decision)" -Command $CommandString
                        @{ permissionDecision = "deny"; reason = $DenyReason; tool = $ToolName } | ConvertTo-Json -Compress | Write-Output
                        exit 2
                    }
                }
            }
        }
    }
} catch {
    # Fail-open: a PDP/network error must never brick the developer's shell.
    # But an explicit server 401/403 (revoked / expired checkout, disabled person, closed legacy
    # window) is not "the network is down": say so, at most once a day per machine (own stamp,
    # same dir logic and 24h TTL as the legacy-key notice, C14). No header value is printed (C5).
    try {
        $RejCode = 0
        try { $RejCode = [int]$_.Exception.Response.StatusCode } catch { $RejCode = 0 }
        if ($RejCode -eq 401 -or $RejCode -eq 403) {
            $StD = $env:HARNESS_STATE_DIR
            if (-not $StD) {
                $StB = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME ".local\state" }
                $StD = Join-Path $StB "harness"
            }
            $St = Join-Path $StD "pdp-rejected-warn.stamp"
            $WarnDue = $true
            if (Test-Path $St) { if (((Get-Date) - (Get-Item $St).LastWriteTime).TotalSeconds -lt 86400) { $WarnDue = $false } }
            if ($WarnDue) {
                New-Item -ItemType Directory -Force -Path $StD | Out-Null
                Set-Content -Path $St -Value ([DateTime]::UtcNow.ToString("o"))
                [Console]::Error.WriteLine("[harness-runtime-guard] PDP rejected this credential (revoked / disabled / legacy window closed) -- server-side enforcement is NOT active for this machine. Shown once a day.")
            }
        }
    } catch { }
}

# ---------------------------------------------------------------- F2 (B0)
# Sensitivity gate. Everything above judges the COMMAND; this judges the TARGET.
# Without it `file_write` scores 10 whether it writes README.md or
# migrations/003_drop_column.sql -- both tier low, neither needing approval --
# while the same schema change called through database_write scores 85. What
# decided the governance was which tool the agent picked, not what was at stake.
#
# Runs only when sensitive-paths.json sets enforce_at_pretooluse=true. The flag
# ships TRUE (since 1.8.0; older wording here said FALSE, which was never what
# shipped). sensitive-paths.json is on the preserve list, so each project's own
# value survives updates and a project opts OUT by setting it false.
#
# FAIL-OPEN, always. A sensitivity check that cannot run must allow the call:
# bricking every shell in the fleet because one JSON file went missing is far
# worse than one unescalated write. Measured cost when on: 1.8% of files in a
# live 166-file repo escalate, so the noise budget is small.
try {
    $SensPath = Join-Path $HarnessRoot ".harness\control\sensitive-paths.json"
    if (Test-Path $SensPath) {
        $Sens = Get-Content -Path $SensPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($Sens.enforce_at_pretooluse -eq $true) {

            # Only tools that WRITE. Reading a migration file is not a risk.
            $WriteTools = @("Write", "Edit", "MultiEdit", "NotebookEdit")
            if ($WriteTools -contains $ToolName) {

                $Target = ""
                foreach ($k in @("file_path", "path", "notebook_path")) {
                    if ($ToolInput -and $ToolInput.$k) { $Target = "$($ToolInput.$k)"; break }
                }

                if ($Target -ne "") {
                    # Relative to the project, so globs match what they were written against.
                    $Rel = $Target
                    if ($Target.StartsWith($HarnessRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        $Rel = $Target.Substring($HarnessRoot.Length).TrimStart('\', '/')
                    }

                    $Matcher = Join-Path $PSScriptRoot "..\lib\harness_sensitivity.py"
                    if (Test-Path $Matcher) {
                        $py = "python"
                        if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = "python3" }
                        if (Get-Command $py -ErrorAction SilentlyContinue) {
                            $Raw = & $py $Matcher $HarnessRoot --path $Rel --json 2>$null
                            if ($LASTEXITCODE -eq 0 -and $Raw) {
                                $Verdict = ($Raw -join "") | ConvertFrom-Json
                                if ($Verdict.rule -and @("high", "critical") -contains $Verdict.tier) {
                                    $Why = "F2 sensitivity: '$Rel' khop rule '$($Verdict.rule)' -> diem $($Verdict.score) (tier $($Verdict.tier)). $($Verdict.reason) Can nguoi duyet truoc khi ghi."

                                    # F2 approval path (P1 1.0). Only for a rule sensitive-paths.json marks
                                    # `approvable` (C2: the data decides, not this script). Ask the Portal
                                    # whether a reviewer approved THIS path and THESE bytes -- one write,
                                    # time-limited, consumed by the answer. ONLY an exact "allow" lets the
                                    # write through; no portal-sync.json, Portal down, a garbled reply,
                                    # pending, rejected: all stay DENIED. The matcher does the HTTP and the
                                    # content hash so this and the bash guard cannot drift (C7). The hook
                                    # payload goes via a temp file as UTF-8 bytes: piping it would run it
                                    # through $OutputEncoding (ASCII on PS 5.1) and change the hash.
                                    # Defense-in-depth (C10): a shell write never reaches this block.
                                    $PortalSays = $null
                                    if ($Verdict.approvable -eq $true) {
                                        $AskTmp = ""
                                        try {
                                            $AskTmp = [IO.Path]::GetTempFileName()
                                            [IO.File]::WriteAllText($AskTmp, $InputJson, (New-Object System.Text.UTF8Encoding($false)))
                                            $AskRaw = & $py $Matcher $HarnessRoot --path $Rel --ask-portal --tool $ToolName --hook-input-file $AskTmp 2>$null
                                            if ($LASTEXITCODE -eq 0 -and $AskRaw) { $PortalSays = ($AskRaw -join "") | ConvertFrom-Json }
                                        } catch {
                                            $PortalSays = $null
                                        } finally {
                                            if ($AskTmp) { Remove-Item -Path $AskTmp -Force -ErrorAction SilentlyContinue }
                                        }
                                    }
                                    if ($PortalSays -and ($PortalSays.decision -ceq "allow")) {
                                        exit 0
                                    }
                                    if ($PortalSays -and $PortalSays.decision -ne "skip") {
                                        if ($PortalSays.approval_id) {
                                            $Why += " Portal: $($PortalSays.decision) (approval_id=$($PortalSays.approval_id)) - nguoi duyet vao Portal > Approvals duyet dung file nay, roi chay lai."
                                        } else {
                                            $Why += " Khong hoi duoc Portal ($($PortalSays.reason)) - giu nguyen chan."
                                        }
                                    }
                                    # Stderr is what Claude Code shows the agent on exit 2; the
                                    # JSON on stdout alone left it a bare denial with no rule (B-20).
                                    Write-DenyToStderr -Reason $Why -Tool $ToolName -Command $Rel
                                    if (Get-Command Write-LedgerDeny -ErrorAction SilentlyContinue) {
                                        Write-LedgerDeny -Tool $ToolName -Pattern "sensitivity:$($Verdict.rule)" -Command $Rel
                                    }
                                    @{ permissionDecision = "deny"; reason = $Why; tool = $ToolName } |
                                        ConvertTo-Json -Compress | Write-Output
                                    exit 2
                                }
                            }
                        }
                    }
                }
            }
        }
    }
} catch {
    # Fail-open, deliberately silent: see the block comment above.
}

exit 0
