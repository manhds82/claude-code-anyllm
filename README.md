# claude-code-anyllm

> Use **Claude Code** inside VS Code, but powered by **any OpenAI-compatible LLM** — FPT Cloud, OpenAI, OpenRouter, Groq, DeepSeek, a local Ollama, anything. One PowerShell script does the whole thing.

Just set three things — **base URL**, **model**, **API key** — and run. A local [LiteLLM](https://github.com/BerriAI/litellm) proxy translates between Claude Code's Anthropic API and your provider.

```
VS Code (Claude Code)  ──►  LiteLLM proxy (localhost:4000)  ──►  your provider's /v1 endpoint
```

---

## Why

Claude Code is a great agent UI, but it talks the Anthropic API. Most other LLMs speak the OpenAI API. This repo bridges the two with a tiny, local proxy so you can drive Claude Code with whatever model you have a key for — without leaking a real Anthropic key and without editing Claude Code itself.

## Requirements

- **Windows** with PowerShell (the one built into Win 10/11 is fine).
- **VS Code** with the **Claude Code** extension (or the Claude Code CLI).
- **Python 3.11 or 3.12** — check with `py -3.12 --version`. Get it from [python.org](https://www.python.org/downloads/) (tick *Add to PATH*).
- An **API key** + **base URL** for any OpenAI-compatible provider.

## Quick start

```powershell
# 1. Clone
git clone https://github.com/<your-username>/claude-code-anyllm.git
cd claude-code-anyllm

# 2. Install the proxy (once)
.\setup-litellm.ps1

# 3. Point it at your provider — edit the 3 lines at the top of start-claude.ps1
#    ($BaseUrl, $Model, $Key)  ... or pass them at runtime in the next step.

# 4. Run
.\start-claude.ps1
```

The script starts the proxy in its own window, waits until it's ready, then opens VS Code already wired to it. **Stop the proxy** by closing that window or running `.\start-claude.ps1 -Stop`.

> If PowerShell blocks the script (execution policy), run `Set-ExecutionPolicy -Scope Process Bypass` and try again.

## Configure it for your provider

Open **`start-claude.ps1`** and edit the block marked `EDIT THESE FOR YOUR PROVIDER`:

```powershell
[string]$BaseUrl = "https://mkp-api.fptcloud.com/v1"   # OpenAI-compatible /v1 endpoint
[string]$Model   = "DeepSeek-V4-Flash"                 # model name (see -List)
[string]$Key     = ""                                  # blank = prompt at runtime (not stored)
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

Not sure what models exist? Ask the endpoint:

```powershell
.\start-claude.ps1 -List
```

## Commands

| I want to…                       | Do this                                            |
|----------------------------------|----------------------------------------------------|
| Install (once)                   | `.\setup-litellm.ps1`                              |
| Run                              | `.\start-claude.ps1`                               |
| Change key — permanently         | Edit `$Key` in `start-claude.ps1`                  |
| Change key — one run             | `-Key "..."`                                       |
| Never store the key              | Leave `$Key = ""` → prompted each run              |
| Change model — permanently       | Edit `$Model` in `start-claude.ps1`                |
| Change model — one run           | `-Model "..."`                                     |
| Change provider — one run        | `-BaseUrl "..." -Model "..." -Key "..."`           |
| List available models            | `-List`                                            |
| Change the proxy port            | `-Port 4010`                                        |
| Stop the proxy                   | `-Stop`                                             |
| Start proxy only (no VS Code)    | `-NoVSCode`                                         |

## How it works

- The script **regenerates** `config/litellm_config.yaml` on every run from your `$BaseUrl` / `$Model`. Don't edit that file by hand.
- The key is passed via the `LLM_API_KEY` environment variable, so it's **never written into a file**.
- It points Claude Code at the proxy with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (a dummy token) and `ANTHROPIC_MODEL`, and routes the background models (`ANTHROPIC_DEFAULT_HAIKU/SONNET/OPUS_MODEL`) to the same alias so background calls don't fail.
- It removes any real `ANTHROPIC_API_KEY` from the session so Claude Code can't fall back to Anthropic.

## Troubleshooting

| Symptom                                   | Fix                                                                 |
|-------------------------------------------|---------------------------------------------------------------------|
| PowerShell blocks the script              | `Set-ExecutionPolicy -Scope Process Bypass`, then rerun.            |
| Model only replies with text, won't edit files | The model lacks tool calling — pick another model.            |
| Port 4000 is busy                         | Script auto-advances; or pass `-Port 4010`.                         |
| Proxy crashes with `UnicodeDecodeError`   | A stray `.env` — `Rename-Item config\.env config\.env.bak`.        |
| Token-count errors                        | In the run window: `$env:CLAUDE_CODE_DISABLE_TOKEN_COUNTING = "1"`. |
| "Proxy ready" never appears               | Check the LiteLLM window for the real error (bad key/model/network).|
| LiteLLM not found                         | `.\setup-litellm.ps1` (add `-Force` to reinstall).                  |

See the full, illustrated guide: **[English](guideline.en.html)** · **[Tiếng Việt](guideline.vi.html)**.

## Project structure

```
claude-code-anyllm/
├─ setup-litellm.ps1          # install LiteLLM (run once)
├─ start-claude.ps1           # start proxy + open VS Code (daily driver)
├─ guideline.en.html          # detailed guide (English)
├─ guideline.vi.html          # detailed guide (Tiếng Việt)
├─ README.md                  # this file
├─ config/
│  └─ litellm_config.yaml     # AUTO-GENERATED each run — git-ignored
└─ .venv/                     # LiteLLM environment (created by setup) — git-ignored
```

## License

[MIT](LICENSE) — do whatever you want, no warranty.
