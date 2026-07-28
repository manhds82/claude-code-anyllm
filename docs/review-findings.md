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
| B‑02 | Security | 🟠 MEDIUM | ✅ Fixed | Windows proxy‑start interpolated the API key into a `-Command` string |
| B‑03 | Correctness | 🟠 MEDIUM | ✅ Fixed | bash: command substitution stripped the newline → 2+ fallback entries produced malformed YAML |
| F‑03 | Security | 🟡 LOW | ✅ Fixed | `model`/`base_url` interpolated into generated YAML unquoted |
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

**B‑02 — Windows proxy‑start interpolated the key into a command string. 🟠 MEDIUM — ✅ FIXED.**
`start-claude.ps1:452` and `toggle-brain.ps1:373` build a here‑string
`` `$env:LLM_API_KEY = '$Key' `` and run it via `Start-Process powershell -Command`. A key containing
a single quote breaks the literal (corrupting proxy start) and is a code‑injection smell. *Contrast:*
the bash side was already safe — `LLM_API_KEY="$KEY" nohup "$LITELLM" …` passes the key as a real env
var. *Fix (applied):* the key is now set on the **parent** process (`$env:LLM_API_KEY = $Key`) and the
child inherits a copy via `Start-Process`; the key line was removed from the command string, and the
parent session is restored in a `finally` block so the key is not left behind or inherited by the
editor launched later. The `$fallbackKeyCmds` string was **deleted entirely** — those keys were read
*from* the process environment in the first place, so the child already inherits them (the
interpolation was both unsafe and redundant). Guarded by the red‑team check
"key never interpolated into a command string".

**F‑03 — `model`/`base_url` interpolated into generated YAML unquoted. 🟡 LOW — ✅ FIXED.**
*Fix (applied):* user‑supplied scalars (`model_name`, `model`, `api_base`) are emitted as YAML
single‑quoted scalars with `'` doubled — `ConvertTo-YamlScalar` (PowerShell) / `yqs()` (bash) — in
`start-claude.*` and `toggle-brain.*`. `api_key` stays bare (it is our own fixed `os.environ/` marker).
*Verified:* `yqs "weird'name"` → `'weird''name'`; sample config parses under PyYAML. Guarded by the
policy‑ci check "config quotes user values (YAML scalars)".

**B‑03 — bash fallback entries lost their trailing newline. 🟠 MEDIUM — ✅ FIXED.**
`start-claude.sh` built `fallback_entries` with `"${fallback_entries}$(printf '…\n')"`. Command
substitution strips *all* trailing newlines, so with **two or more** fallback providers the entries
were concatenated onto one line, producing malformed YAML that LiteLLM would reject. *Fix (applied):*
append an explicit `$'\n'` after the substitution. *Verified:* simulating two fallback providers now
emits two correctly separated `- model_name:` blocks.

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

All product findings (B‑01, B‑02, B‑03, F‑03) are **fixed and regression‑guarded**; suites are green
(PowerShell 34/34, bash 32/32). Remaining, deliberately not changed:

1. **F‑04 / F‑05** — by design / already documented. The readiness polls are bounded and safe
   (backoff is low ROI); un‑setting `ANTHROPIC_API_KEY` cannot reach an already‑running editor, which
   the README/guideline already tell the user to restart.
2. Consider adding `pwsh`/`bash` matrix execution of `tests/run-tests.*` to
   `.github/workflows/claude-review.yml`.
3. Governance harness (`.harness/` bundle) findings are **out of scope for this repo** — owned by the
   harness project.
