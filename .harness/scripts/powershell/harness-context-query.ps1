#!/usr/bin/env pwsh
<#
.SYNOPSIS
  H1 Context Harness — retrieve the most relevant context chunks for a query
  (RAG-lite / semantic cache). Thin wrapper over scripts/lib/harness_rag.py.
.DESCRIPTION
  An agent calls this to FIND relevant SRS/spec/doc/contract passages instead of
  re-reading whole files. BM25 by default; neural if HARNESS_EMBED_CMD is set.
.EXAMPLE
  harness-context-query.ps1 "how is the ingest key validated" -K 5
#>
param(
    [Parameter(Mandatory)][string]$Query,
    [int]$K = 5,
    [string]$HarnessRoot = ""
)
if (-not $HarnessRoot) {
    $HarnessRoot = $env:HARNESS_ROOT
    if (-not $HarnessRoot) { $HarnessRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path }
}
$Lib = "$HarnessRoot\.harness\scripts\lib\harness_rag.py"
$py = (Get-Command python3 -ErrorAction SilentlyContinue); if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) { Write-Warning "[rag] python not found"; exit 0 }
if (-not (Test-Path $Lib)) { Write-Warning "[rag] core not found: $Lib"; exit 0 }
$env:HARNESS_ROOT = $HarnessRoot
& $py.Source $Lib query $Query --root $HarnessRoot --k $K
exit 0
