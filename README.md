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

## Configure it for your provider

Open the launcher for your OS and edit the block marked `EDIT THESE FOR YOUR PROVIDER`:

```powershell
# start-claude.ps1  (Windows)
[string]$BaseUrl = "https://mkp-api.fptcloud.com/v1"   # OpenAI-compatible /v1 endpoint
[string]$Model   = "DeepSeek-V4-Flash"                 # model name (see -List)
[string]$Key     = ""                                  # blank = prompt at runtime (not stored)
```

```bash
# start-claude.sh  (macOS / Linux)
BASE_URL="https://mkp-api.fptcloud.com/v1"   # OpenAI-compatible /v1 endpoint
MODEL="DeepSeek-V4-Flash"                     # model name (see --list)
KEY=""                                        # blank = prompt at runtime (not stored)
```

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

## Commands

| I want to…                  | Windows (PowerShell)                       | macOS / Linux (bash)                          |
|-----------------------------|-------------------------------------------|-----------------------------------------------|
| Install (once)              | `.\setup-litellm.ps1`                     | `./setup-litellm.sh`                          |
| Run                         | `.\start-claude.ps1`                      | `./start-claude.sh`                           |
| Change key/model — permanent| Edit `$Key` / `$Model` in `start-claude.ps1` | Edit `KEY` / `MODEL` in `start-claude.sh` |
| Change model — one run      | `-Model "..."`                            | `--model "..."`                               |
| Change key — one run        | `-Key "..."`                              | `--key "..."`                                 |
| Switch provider — one run   | `-BaseUrl "..." -Model "..." -Key "..."`  | `--base-url "..." --model "..." --key "..."`  |
| List available models       | `-List`                                   | `--list`                                       |
| Change the proxy port       | `-Port 4010`                              | `--port 4010`                                  |
| Stop the proxy              | `-Stop`                                   | `--stop`                                        |
| Proxy only (no VS Code)     | `-NoVSCode`                               | `--no-vscode`                                   |

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

## Project structure

```
claude-code-anyllm/
├─ setup-litellm.ps1          # install LiteLLM — Windows  (run once)
├─ setup-litellm.sh           # install LiteLLM — macOS/Linux  (run once)
├─ start-claude.ps1           # start proxy + open VS Code — Windows
├─ start-claude.sh            # start proxy + open VS Code — macOS/Linux
├─ guideline.en.html          # detailed guide (English)
├─ guideline.vi.html          # detailed guide (Tiếng Việt)
├─ README.md                  # this file
├─ .gitattributes             # keeps .sh as LF, .ps1 as CRLF
├─ config/
│  └─ litellm_config.yaml     # generated each run; committed as a working example
└─ .venv/                     # LiteLLM environment (created by setup) — git-ignored
```

## License

[MIT](LICENSE) — do whatever you want, no warranty.
