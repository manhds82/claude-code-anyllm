# claude-code-anyllm

> Use **Claude Code** inside VS Code, but powered by **any OpenAI-compatible LLM** — FPT Cloud, OpenAI, OpenRouter, Groq, DeepSeek, a local Ollama, anything. One script does the whole thing — **PowerShell on Windows, bash on macOS/Linux**.

Just set three things — **base URL**, **model**, **API key** — and run. A local [LiteLLM](https://github.com/BerriAI/litellm) proxy translates between Claude Code's Anthropic API and your provider.

```
VS Code (Claude Code)  ──►  LiteLLM proxy (localhost:4000)  ──►  your provider's /v1 endpoint
```

---

## Why

Claude Code is a great agent UI, but it talks the Anthropic API. Most other LLMs speak the OpenAI API. This repo bridges the two with a tiny, local proxy so you can drive Claude Code with whatever model you have a key for — without leaking a real Anthropic key and without editing Claude Code itself.

## Requirements

- **Windows** (PowerShell), **macOS**, or **Linux** (bash).
- **VS Code** with the **Claude Code** extension (or the Claude Code CLI).
- **Python 3.11 or 3.12** — Windows: `py -3.12 --version` ([python.org](https://www.python.org/downloads/), tick *Add to PATH*); macOS: `brew install python@3.12`; Linux: `sudo apt install python3 python3-venv`.
- **curl** (preinstalled on Windows 10+/macOS; `sudo apt install curl` on Linux) — used by `--list`.
- An **API key** + **base URL** for any OpenAI-compatible provider.

## Quick start

**Windows (PowerShell):**

```powershell
git clone https://github.com/manhds82/claude-code-anyllm.git
cd claude-code-anyllm
.\setup-litellm.ps1     # install the proxy (once)
.\start-claude.ps1      # edit BaseUrl/Model/Key at the top first, or pass -Key at runtime
```

**macOS / Linux (bash):**

```bash
git clone https://github.com/manhds82/claude-code-anyllm.git
cd claude-code-anyllm
chmod +x *.sh           # first time only
./setup-litellm.sh      # install the proxy (once)
./start-claude.sh       # edit BASE_URL/MODEL/KEY at the top first, or pass --key at runtime
```

The script installs the proxy if needed, starts it, waits until it's ready, then opens VS Code already wired to it. On **Windows** the proxy runs in its own window (close it to stop); on **macOS/Linux** it runs in the background and logs to `litellm-proxy.log`. **Stop it** any time with `-Stop` (Windows) / `--stop` (macOS/Linux).

> **Windows:** if PowerShell blocks the script, run `Set-ExecutionPolicy -Scope Process Bypass`.
> **macOS/Linux:** if you get *permission denied*, run `chmod +x *.sh` (or `bash start-claude.sh`).

## Zero-install — `npx claude-bridge`

Have Node ≥ 18? Skip the clone entirely:

```bash
npx claude-bridge                    # interactive provider menu
npx claude-bridge --provider groq    # jump straight to a provider
npx claude-bridge --update           # pull latest from GitHub
```

First run clones the repo to `~/.claude-bridge` automatically. All flags pass through to `start-claude.ps1` / `start-claude.sh`. For the full dev workflow (per-project launcher, etc.) use `git clone` above.

## Pick a provider at start time (multiple keys, one script)

Have keys for more than one provider — FPT, NVIDIA, Gemini, GitHub, Groq...? `config/providers.conf` lists them all; run the launcher with no arguments and pick one from a menu, or jump straight to one with `-Provider`/`--provider`:

```powershell
.\start-claude.ps1                # interactive menu (shows which providers have a key set)
.\start-claude.ps1 -Provider nvidia
.\start-claude.ps1 -ListProviders  # see every provider id + which env var it reads
```

```bash
./start-claude.sh                 # interactive menu
./start-claude.sh --provider nvidia
./start-claude.sh --list-providers
```

Each line in `config/providers.conf` is `id|label|base_url|model|key_env` — each provider reads its key from its **own** env var, so you only set the ones you actually have:

| id       | Provider                    | Model                          | Set the key with |
|----------|------------------------------|--------------------------------|-------------------|
| `fpt`    | FPT Cloud                    | `DeepSeek-V4-Flash`            | `LLM_API_KEY_FPT` |
| `nvidia` | NVIDIA NIM                   | `qwen/qwen2.5-coder-32b-instruct` | `LLM_API_KEY_NVIDIA` |
| `gemini` | Google Gemini                | `gemini-2.5-flash`             | `LLM_API_KEY_GEMINI` |
| `github` | GitHub Models                 | `gpt-4o-mini`                  | `LLM_API_KEY_GITHUB` |
| `groq`   | Groq                          | `llama-3.3-70b-versatile`      | `LLM_API_KEY_GROQ` |

```powershell
# Windows — set whichever ones you have, then open a new terminal
setx LLM_API_KEY_NVIDIA "nvapi-..."
setx LLM_API_KEY_GEMINI "AIza..."
```

```bash
# macOS / Linux — add whichever ones you have to ~/.zshrc or ~/.bashrc
export LLM_API_KEY_NVIDIA="nvapi-..."
export LLM_API_KEY_GEMINI="AIza..."
```

Add your own provider by adding one line to `config/providers.conf` — no code changes needed.

### Auto-failover

Set keys for **more than one provider** and the proxy automatically retries the next one on rate-limit or error — no extra config needed. The generated YAML groups all available providers under the same `model_name`; LiteLLM's router picks the next one when one fails.

```
[OK] Auto-failover: Groq → Gemini Flash   ← shown at startup if fallbacks are available
``` `-BaseUrl`/`-Model`/`-Key` (or `--base-url`/`--model`/`--key`) still work exactly as before and always override the selected provider, so nothing below changes.

## Configure it for your provider

Open the launcher for your OS and edit the block marked `EDIT THESE FOR YOUR PROVIDER`:

```powershell
# start-claude.ps1  (Windows)
[string]$BaseUrl = "https://mkp-api.fptcloud.com/v1"   # OpenAI-compatible /v1 endpoint
[string]$Model   = "DeepSeek-V4-Flash"                 # model name (see -List)
[string]$Key     = ""                                  # blank = read $env:LLM_API_KEY, else prompt
```

```bash
# start-claude.sh  (macOS / Linux)
BASE_URL="https://mkp-api.fptcloud.com/v1"   # OpenAI-compatible /v1 endpoint
MODEL="DeepSeek-V4-Flash"                     # model name (see --list)
KEY=""                                        # blank = read $LLM_API_KEY, else prompt
```

> **Recommended — keep your key out of the file.** Leave `$Key` / `KEY` blank and set the key once as an environment variable named `LLM_API_KEY`; the script reads it automatically, so the key never lives in a tracked file:
>
> - **Windows (persistent):** `setx LLM_API_KEY "your-key"` — then open a new terminal
> - **Windows (this session only):** `$env:LLM_API_KEY = "your-key"`
> - **macOS / Linux:** add `export LLM_API_KEY="your-key"` to `~/.zshrc` or `~/.bashrc`

Examples — pick a model that **supports tool / function calling** (otherwise Claude Code can only reply with text, not edit files):

| Provider   | `BaseUrl`                            | Example `Model`               |
|------------|--------------------------------------|-------------------------------|
| FPT Cloud  | `https://mkp-api.fptcloud.com/v1`    | `DeepSeek-V4-Flash`           |
| OpenAI     | `https://api.openai.com/v1`          | `gpt-4o`                      |
| OpenRouter | `https://openrouter.ai/api/v1`       | `anthropic/claude-3.5-sonnet` |
| Groq       | `https://api.groq.com/openai/v1`     | `llama-3.3-70b-versatile`     |
| DeepSeek   | `https://api.deepseek.com/v1`        | `deepseek-chat`               |
| Ollama (local) | `http://localhost:11434/v1`      | `qwen2.5-coder` (any key)     |

Not sure what models exist? Ask the endpoint — `.\start-claude.ps1 -List` (Windows) or `./start-claude.sh --list` (macOS/Linux).

## Pin a stable Claude Code CLI

Newer Claude Code builds occasionally misbehave behind a proxy, so `setup-litellm.ps1` / `setup-litellm.sh` run **`claude install stable`** once — pinning Claude Code to the **stable** channel. The pin **sticks** across auto-updates, so it's a one-time step (re-run `claude install stable` any time a bad version slips in). The command is identical on Windows, macOS, and Linux.

This step needs the **standalone `claude` CLI** on your PATH (the VS Code extension alone doesn't provide it). If setup reports it was skipped, install the CLI first:

```bash
# macOS / Linux
curl -fsSL https://claude.ai/install.sh | bash -s stable
```

```powershell
# Windows PowerShell
& ([scriptblock]::Create((irm https://claude.ai/install.ps1))) stable
```

Want to freeze updates entirely? Add `"env": { "DISABLE_AUTOUPDATER": "1" }` to your Claude Code `settings.json`.

## Commands

| I want to…                  | Windows (PowerShell)                       | macOS / Linux (bash)                          |
|-----------------------------|-------------------------------------------|-----------------------------------------------|
| Install (once)              | `.\setup-litellm.ps1`                     | `./setup-litellm.sh`                          |
| Run (interactive menu)      | `.\start-claude.ps1`                      | `./start-claude.sh`                           |
| Run — pick a provider by id | `-Provider nvidia`                        | `--provider nvidia`                           |
| List providers + key status | `-ListProviders`                          | `--list-providers`                            |
| Test all provider keys      | `-CheckKeys`                              | `--check-keys`                                |
| Benchmark provider (latency + tool call) | `-Benchmark`             | `--benchmark`                                 |
| Open dashboard in browser   | `-Dashboard`                              | `--dashboard`                                 |
| Open a different project    | `-OpenDir "C:\MyProjects\myapp"`          | `--open-dir ~/myapp`                          |
| Change key/model — permanent| Edit `$Key` / `$Model` in `start-claude.ps1` | Edit `KEY` / `MODEL` in `start-claude.sh` |
| Change model — one run      | `-Model "..."`                            | `--model "..."`                               |
| Change key — one run        | `-Key "..."`                              | `--key "..."`                                 |
| Switch provider — one run   | `-BaseUrl "..." -Model "..." -Key "..."`  | `--base-url "..." --model "..." --key "..."`  |
| List available models       | `-List`                                   | `--list`                                       |
| Change the proxy port       | `-Port 4010`                              | `--port 4010`                                  |
| Stop the proxy              | `-Stop`                                   | `--stop`                                        |
| Proxy only (no VS Code)     | `-NoVSCode`                               | `--no-vscode`                                   |

## Use with an existing project

By default `start-claude.ps1` / `start-claude.sh` opens VS Code in its own folder. To open **your** project instead, pass `-OpenDir` / `--open-dir`:

```powershell
# Windows — open a different project for this run
.\start-claude.ps1 -Provider fpt -OpenDir "C:\MyProjects\myapp"
```

```bash
# macOS / Linux
./start-claude.sh --provider fpt --open-dir ~/myprojects/myapp
```

**Even simpler — one tiny file per project:** copy `open-with-claude.ps1` (Windows) or `open-with-claude.sh` (macOS/Linux) from this repo into your project, edit the `$ClaudeSetup` / `CLAUDE_SETUP` path at the top once, and from then on just run:

```powershell
# from your project folder
.\open-with-claude.ps1              # interactive provider menu
.\open-with-claude.ps1 -Provider fpt
```

```bash
./open-with-claude.sh
./open-with-claude.sh --provider fpt
```

The proxy starts, VS Code opens in **your** project. No `.venv` duplication — everything still runs from the single central installation.

## Use with Cursor, Windsurf, or Continue.dev

The proxy speaks the OpenAI API, so any editor that accepts a custom base URL works — not just VS Code. Start the proxy first without opening VS Code:

```powershell
.\start-claude.ps1 -Provider groq -NoVSCode   # Windows
```
```bash
./start-claude.sh --provider groq --no-vscode  # macOS / Linux
```

Then configure your editor:

**Cursor** — open Settings, find the Anthropic / Claude section, set a custom endpoint:
```json
{
  "cursor.cpp.anthropicBaseUrl": "http://localhost:4000",
  "cursor.cpp.anthropicApiKey": "dummy"
}
```

**Windsurf** — Cascade settings → set the Anthropic base URL to `http://localhost:4000`, key to `dummy`.

**Continue.dev** — add a model block to `.continue/config.json`:
```json
{
  "models": [{
    "title": "Proxy (Groq / FPT / ...)",
    "provider": "anthropic",
    "apiBase": "http://localhost:4000",
    "apiKey": "dummy",
    "model": "claude-sonnet-4-6"
  }]
}
```

Pick a model from the provider's list with `-List` / `--list` to find the exact names your endpoint exposes.

## 🧠 Brain toggle — persistent profile switching

Toggle Claude Code between **real Anthropic** and **proxy mode** with a single command. Unlike `start-claude.ps1` (which sets env vars for one session), this writes a **persistent profile** to `~/.claude/settings.json` so the change survives VS Code restarts.

```powershell
# Windows
.\toggle-brain.ps1 -Status          # → see what brain is active
.\toggle-brain.ps1 -Mode claude     # → switch to real Anthropic
.\toggle-brain.ps1 -Mode proxy      # → switch to proxy LLM
.\toggle-brain.ps1 -Mode proxy -StartProxy -Key "sk-..."   # switch + start proxy
.\toggle-brain.ps1 -StopProxy       # → stop the proxy
.\toggle-brain.ps1 -ListProfiles    # → see available profiles
```

```bash
# macOS / Linux
./toggle-brain.sh status            # → see what brain is active
./toggle-brain.sh claude            # → switch to real Anthropic
./toggle-brain.sh proxy             # → switch to proxy LLM
./toggle-brain.sh proxy --start --key "sk-..."   # switch + start proxy
./toggle-brain.sh stop              # → stop the proxy
./toggle-brain.sh profiles          # → see available profiles
```

**How it works:** `toggle-brain.ps1` copies a profile from `profiles/` (e.g. `claude.json` or `fpt.json`) to `~/.claude/settings.json`. Each profile sets the environment variables Claude Code reads at startup. The `profiles/` folder is extensible — add any `.json` file with the same `{"env": {...}}` structure.

| Profile | Effect |
|---------|--------|
| `claude.json` | Empty `env` block — Claude Code uses its real Anthropic API key |
| `fpt.json` | Sets `ANTHROPIC_BASE_URL` → `localhost:4000` — routes through LiteLLM proxy |

Double-click `toggle-brain.bat` (Windows) to see usage, or pass an argument like `toggle-brain.bat proxy`.

## How it works

- The script (`start-claude.ps1` / `start-claude.sh`) **regenerates** `config/litellm_config.yaml` on every run from your base URL / model. Don't edit that file by hand.
- The key is passed via the `LLM_API_KEY` environment variable, so it's **never written into a file**.
- It points Claude Code at the proxy with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (a dummy token) and `ANTHROPIC_MODEL`, and routes the background models (`ANTHROPIC_DEFAULT_HAIKU/SONNET/OPUS_MODEL`) to the same alias so background calls don't fail.
- It removes any real `ANTHROPIC_API_KEY` from the session so Claude Code can't fall back to Anthropic.

## Troubleshooting

| Symptom                                   | Fix                                                                 |
|-------------------------------------------|---------------------------------------------------------------------|
| PowerShell blocks the script (Windows)    | `Set-ExecutionPolicy -Scope Process Bypass`, then rerun.            |
| `permission denied` (macOS/Linux)         | `chmod +x *.sh`, or run `bash start-claude.sh`.                     |
| `bad interpreter`/`\r` error (macOS/Linux)| Line endings got converted to CRLF — `sed -i 's/\r$//' *.sh` (the bundled `.gitattributes` prevents this on a fresh clone). |
| Model only replies with text, won't edit files | The model lacks tool calling — pick another model.            |
| Port 4000 is busy                         | Script auto-advances; or pass `-Port 4010` / `--port 4010`.         |
| Proxy crashes with `UnicodeDecodeError`   | A stray `.env` — rename it: `config/.env` → `config/.env.bak`.      |
| Token-count errors                        | Set `CLAUDE_CODE_DISABLE_TOKEN_COUNTING=1` in the run shell.        |
| "Proxy ready" never appears               | Check the real error — proxy window (Windows) or `litellm-proxy.log` (macOS/Linux). |
| LiteLLM not found                         | `.\setup-litellm.ps1` / `./setup-litellm.sh` (add `-Force`/`--force` to reinstall). |

See the full, illustrated guide: **[English](guideline.en.html)** · **[Tiếng Việt](guideline.vi.html)**.

## Docker — one command, no Python required

Run the proxy in a container — useful for team servers, NAS boxes, or any machine where you don't want to install Python:

```bash
# Build and start (Groq by default)
LLM_API_KEY_GROQ="gsk_..." docker compose up -d

# Point Claude Code at the proxy (from your dev machine):
export ANTHROPIC_BASE_URL="http://server-ip:4000"
export ANTHROPIC_AUTH_TOKEN="dummy"
```

Or build and run directly:

```bash
docker build -t claude-bridge .
docker run -d -p 4000:4000 \
  -e LLM_API_KEY="your-key" \
  -e BASE_URL="https://api.groq.com/openai/v1" \
  -e MODEL="llama-3.3-70b-versatile" \
  claude-bridge
```

Edit `docker-compose.yml` to switch providers — uncomment a different `BASE_URL`/`MODEL`/`LLM_API_KEY` block.

## GitHub Actions — free automatic PR review

Copy `.github/workflows/claude-review.yml` from this repo into any of your own repos. Add `GROQ_API_KEY` to **Settings → Secrets and Variables → Actions** and every pull request is reviewed automatically using Groq's free tier.

The workflow starts a LiteLLM proxy in the CI container, runs Claude Code CLI against the PR diff, and posts the result as a comment. No Anthropic key needed.

> To use a different provider: edit the `model`, `api_base`, and secret name in the workflow file.

## Project structure

```
claude-code-anyllm/
├─ setup-litellm.ps1          # install LiteLLM — Windows  (run once)
├─ setup-litellm.sh           # install LiteLLM — macOS/Linux  (run once)
├─ start-claude.ps1           # start proxy + open VS Code — Windows
├─ start-claude.sh            # start proxy + open VS Code — macOS/Linux
├─ toggle-brain.ps1           # persistent brain toggle — Windows
├─ toggle-brain.bat           # double-click launcher for toggle-brain.ps1
├─ toggle-brain.sh            # persistent brain toggle — macOS/Linux
├─ open-with-claude.ps1       # per-project launcher template — Windows (copy to your project)
├─ open-with-claude.sh        # per-project launcher template — macOS/Linux (copy to your project)
├─ Dockerfile                 # Docker image (proxy only, no Python install needed)
├─ docker-compose.yml         # docker compose up -d  — picks provider from env
├─ docker-entrypoint.sh       # generates config + starts proxy inside container
├─ guideline.en.html          # detailed guide (English)
├─ guideline.vi.html          # detailed guide (Tiếng Việt)
├─ README.md                  # this file
├─ .gitattributes             # keeps .sh as LF, .ps1 as CRLF
├─ profiles/
│  ├─ claude.json             # profile: real Anthropic account
│  └─ fpt.json                # profile: FPT/DeepSeek via proxy
├─ config/
│  ├─ providers.conf          # provider list (id|label|base_url|model|key_env)
│  └─ litellm_config.yaml     # generated each run; committed as a working example
├─ logs/                      # usage.csv — one row per session (git-ignored)
└─ .venv/                     # LiteLLM environment (created by setup) — git-ignored
```

## License

[MIT](LICENSE) — do whatever you want, no warranty.
