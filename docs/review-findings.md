# Code Review Findings — claude-code-anyllm

> **Date:** 2026-07-22 · **Scope:** product scripts (`setup-litellm.*`, `start-claude.*`,
> `toggle-brain.*`, `profiles/`, generated `config/`). Harness infrastructure (`.harness/`) excluded.
> **Method:** 3‑angle review (correctness / security / performance). A parallel sub‑agent run was
> attempted first but hit a platform session limit, so the review was completed inline and each
> finding was **verified empirically** (parse/run/grep) — evidence noted per item.

## Summary

| ID | Angle | Severity | Status | Title |
|----|-------|----------|--------|-------|
| B‑01 | Correctness | 🔴 HIGH | ✅ Fixed | `.ps1` without BOM + Unicode → PowerShell 5.1 parse failure |
| B‑02 | Security | 🟠 MEDIUM | ⬜ Open | Windows proxy‑start interpolates the API key into a `-Command` string |
| F‑03 | Security | 🟡 LOW | ⬜ Open | `model`/`base_url` interpolated into generated YAML unquoted |
| F‑04 | Robustness | 🟡 LOW | Known | Readiness waits use fixed‑interval polling (bounded) |
| F‑05 | Correctness | 🟡 LOW | Known | `Remove-Item Env:\ANTHROPIC_API_KEY` only affects a fresh session |

Everything else in scope **passed**: cross‑platform flag parity, no secrets in tracked files,
config/profiles use `os.environ/LLM_API_KEY`, dummy `ANTHROPIC_AUTH_TOKEN`, no remote‑to‑shell in
product scripts, bounded port scan, detached POSIX proxy (`nohup`+`disown`). Verified by
`tests/run-tests.ps1` (32/32) and `tests/run-tests.sh` (30/30).

---

## Correctness

**B‑01 — `.ps1` without BOM + Unicode → PowerShell 5.1 parse failure. 🔴 HIGH — FIXED.**
`start-claude.ps1` / `toggle-brain.ps1` failed to even parse under Windows PowerShell 5.1 on a
non‑UTF‑8 system locale (CP932 here): PS 5.1 reads a BOM‑less script as the ANSI codepage, mis‑decodes
the box‑drawing/emoji bytes, and the tokenizer desyncs. *Evidence:* `powershell -File start-claude.ps1
-Stop` errored at line 228; reading the same file as UTF‑8 + `Parser::ParseInput` → 0 errors; files
began `3c 23` (no BOM). *Fix (applied):* added a UTF‑8 BOM to the two non‑ASCII `.ps1`; added a
regression check ("ps1 PS5.1‑safe encoding") to both test runners; made `profiles/claude.json`
ASCII. *Re‑verified:* both scripts now run; suites green. See `buglist.md` B‑01.

**F‑05 — `Remove-Item Env:\ANTHROPIC_API_KEY` only affects a fresh session. 🟡 LOW — known.**
If VS Code / Claude Code is already running, the un‑set env does not reach it; the user must
reopen. Already documented (README/guideline note "fully quit and reopen"). No change.

## Security

**B‑02 — Windows proxy‑start interpolates the key into a command string. 🟠 MEDIUM — OPEN.**
`start-claude.ps1:452` and `toggle-brain.ps1:373` build a here‑string
`` `$env:LLM_API_KEY = '$Key' `` and run it via `Start-Process powershell -Command`. A key containing
a single quote breaks the literal (corrupting proxy start) and is a code‑injection smell. *Contrast:*
the bash side is safe — `LLM_API_KEY="$KEY" nohup "$LITELLM" …` (start-claude.sh:415,
toggle-brain.sh:254) passes the key as a real env var, never interpolated. *Recommended fix:* set
`$env:LLM_API_KEY = $Key` (and any fallback keys) in the **parent** before `Start-Process`, which the
child inherits, and drop the key line from the command string. *Not auto‑fixed:* the PS branch also
appends `$fallbackKeyCmds` (multi‑provider fallback) that needs a full read before refactoring —
flagged for the owner to keep the feature intact. Exploitability is low (the key is the user's own).

**F‑03 — `model`/`base_url` interpolated into generated YAML unquoted. 🟡 LOW — OPEN.**
The generated `config/litellm_config.yaml` inlines `$Model`/`$BaseUrl` without quoting; a value with
YAML‑special characters or a newline could corrupt the config. User‑controlled, non‑remote, low risk.
*Fix:* validate/quote these values, or write via a YAML emitter.

**PASS — secrets.** No secret patterns in any tracked file; `config`/`profiles` reference only
`os.environ/LLM_API_KEY`; `ANTHROPIC_AUTH_TOKEN` is the fixed dummy `litellm-proxy`; product scripts
never pipe remote content into a shell. (Requirement #4 satisfied; enforced by `tests/red-team`.)

## Performance / robustness

**F‑04 — Fixed‑interval readiness polling. 🟡 LOW — known.** `start-claude` polls
`/health/liveliness` up to 30×1 s; `toggle-brain` up to 15×1 s. Bounded and safe; exponential
backoff would shave a little startup latency (low ROI). Tracked in `spec.md §10`.

**PASS — loops/leaks.** Port probing is bounded (`+20`); no unbounded retries; the POSIX proxy is
detached with `nohup`+`disown` and logs to `litellm-proxy.log`; `--stop`/`-Stop` reap it by port.

## Follow‑ups

1. Apply B‑02 (env‑inherit key on Windows) once the multi‑provider fallback path is mapped.
2. Optionally address F‑03 (quote YAML values).
3. Consider adding `pwsh`/`bash` matrix execution of `tests/run-tests.*` to
   `.github/workflows/claude-review.yml`.
