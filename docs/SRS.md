# Software Requirements Specification — claude-code-anyllm

> **Status:** Baseline v1.0 · **Last updated:** 2026-07-22
> **Audience:** new contributors, reviewers, and the governance harness (CASAN).
> **Companion:** [spec.md](spec.md) (architecture & design), [../README.md](../README.md) (quick start),
> [../guideline.en.html](../guideline.en.html) / [../guideline.vi.html](../guideline.vi.html) (end‑user guide).

---

## 1. Purpose

`claude-code-anyllm` lets a developer use **Claude Code** (Anthropic's coding CLI / VS Code
extension) while the model actually answering is **any OpenAI‑compatible LLM** — FPT Cloud,
OpenAI, OpenRouter, Groq, DeepSeek, a local Ollama, etc. It does this without modifying Claude
Code and without exposing a real Anthropic key, by running a **local LiteLLM proxy** that
translates between the Anthropic Messages API and the provider's OpenAI API and pointing Claude
Code's `ANTHROPIC_*` environment variables at that proxy.

## 2. Scope

**In scope**

- Cross‑platform launcher scripts: **Windows PowerShell** (`*.ps1`) and **macOS/Linux bash** (`*.sh`),
  kept at behavioural parity (convention **C7**).
- One‑time environment setup (Python venv + `litellm[proxy]`), and pinning the Claude Code CLI to
  the **stable** release channel.
- Starting/stopping the local proxy, generating its config, and opening the editor already wired to it.
- Choosing the provider/model at runtime; listing available models; a lightweight benchmark and a
  provider "dashboard"; validating that provider keys are present.
- Switching Claude Code's "brain" between **real Anthropic** and the **proxy** via named profiles
  (`toggle-brain`).
- Secure key handling: the API key is read from an environment variable or a hidden prompt and is
  **never** written to a git‑tracked file.

**Out of scope**

- Hosting/operating the upstream LLM provider.
- Modifying Claude Code itself, or the LiteLLM package.
- Windows CMD as a first‑class launcher (only a thin `toggle-brain.bat` shim exists).
- The governance harness internals (`.harness/`) — reusable infrastructure documented separately.

## 3. Actors

| Actor | Description |
|-------|-------------|
| **Developer / user** | Runs the scripts on their workstation to drive Claude Code with a chosen LLM. |
| **LiteLLM proxy** | Local process that speaks Anthropic on the inbound side and OpenAI on the outbound side. |
| **LLM provider** | Any OpenAI‑compatible `/v1` endpoint (FPT, OpenAI, …). |
| **Claude Code** | The Anthropic CLI/extension whose `ANTHROPIC_*` env is redirected to the proxy. |
| **Governance harness (CASAN)** | Reads `docs/`, `contracts/`, and `.harness/` policies to gate quality. |

## 4. Functional requirements

IDs are stable; tests reference them (see `tests/`).

### FR‑SETUP — one‑time install (`setup-litellm.{ps1,sh}`)
- **FR‑SETUP‑1** Detect Python 3.11/3.12 (Windows: `py` launcher; POSIX: `python3.x`); create a
  project‑local `.venv`; install `litellm[proxy]`; verify the `litellm` executable exists.
- **FR‑SETUP‑2** Be idempotent: if already installed, report and exit 0; `-Force`/`--force`
  reinstalls from scratch.
- **FR‑SETUP‑3** Pin Claude Code to the stable channel via `claude install stable` **only if** the
  `claude` CLI is on `PATH`; otherwise skip with a warning (never fail setup).
- **FR‑SETUP‑4** Never require a hard‑coded username or path; the venv lives in the project.

### FR‑RUN — start proxy + open editor (`start-claude.{ps1,sh}`)
- **FR‑RUN‑1** Read three settings — **base URL, model, API key** — from the top‑of‑file config,
  runtime flags, or (for the key) the `LLM_API_KEY` environment variable.
- **FR‑RUN‑2** Regenerate `config/litellm_config.yaml` on every run from base URL + model + alias,
  UTF‑8 **without BOM**; the config references `api_key: os.environ/LLM_API_KEY` (no literal key).
- **FR‑RUN‑3** Auto‑install LiteLLM (delegates to setup) if it is missing.
- **FR‑RUN‑4** Find a free port starting at 4000 (auto‑advance up to +20) and start the proxy.
- **FR‑RUN‑5** Wait for the proxy `/health/liveliness` endpoint before continuing (bounded).
- **FR‑RUN‑6** Export `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (a dummy token),
  `ANTHROPIC_MODEL`, and the `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` aliases; remove any real
  `ANTHROPIC_API_KEY` from the session; then open VS Code (or print the env for manual use).
- **FR‑RUN‑7** `-Stop`/`--stop` terminates the proxy on the given port.

### FR‑PROVIDER — provider/model utilities (`start-claude.{ps1,sh}`)
- **FR‑PROV‑1** `-List`/`--list` queries the endpoint's `/v1/models` and prints available model ids.
- **FR‑PROV‑2** `-Provider`/`--provider`, `-ListProviders`/`--list-providers` select/enumerate
  known providers; `-CheckKeys`/`--check-keys` reports which providers have a key configured.
- **FR‑PROV‑3** `-Benchmark`/`--benchmark` runs a lightweight latency/tool‑calling probe;
  `-Dashboard`/`--dashboard` summarises provider status. These must be read‑only and must not leak keys.

### FR‑TOGGLE — brain switching (`toggle-brain.{ps1,sh}`)
- **FR‑TOGGLE‑1** A **profile** is a JSON file in `profiles/` whose `env` object is applied by
  copying it to `~/.claude/settings.json`.
- **FR‑TOGGLE‑2** `-Mode claude` selects the native‑Anthropic profile (empty `env`); `-Mode proxy`
  selects a proxy profile (default `fpt`).
- **FR‑TOGGLE‑3** `-Status` reports the current brain (claude/proxy/custom/unknown) and whether the
  proxy is listening; `-ListProfiles` enumerates profiles; `-StartProxy`/`-StopProxy` manage the proxy.
- **FR‑TOGGLE‑4** Detect the current mode from `settings.json` (`ANTHROPIC_BASE_URL` pointing at
  `localhost` ⇒ proxy; empty env ⇒ claude).

### FR‑KEY — secret handling (all scripts)
- **FR‑KEY‑1** The API key precedence is: explicit flag → `LLM_API_KEY` env → hidden prompt.
- **FR‑KEY‑2** The key MUST NOT be persisted to any git‑tracked file (script, config, or profile).
- **FR‑KEY‑3** The key is passed to the proxy process only via the `LLM_API_KEY` environment variable.

## 5. Non‑functional requirements

| ID | Requirement |
|----|-------------|
| **NFR‑SEC‑1** | No secret, API key, or token is committed to the repository (verified by `tests/red-team`). |
| **NFR‑SEC‑2** | `ANTHROPIC_AUTH_TOKEN` sent to the proxy is a fixed dummy string, never a real key. |
| **NFR‑SEC‑3** | Config/profile files contain only `os.environ/...` key references, never literals. |
| **NFR‑PORT‑1** | Scripts run with no hard‑coded username; `.venv` and paths are project‑relative. |
| **NFR‑X‑PLAT‑1** | Every user‑facing flag exists in both the PowerShell and bash launcher (parity). |
| **NFR‑X‑PLAT‑2** | `.sh` files are stored with **LF** endings; `.ps1` with CRLF (`.gitattributes`). |
| **NFR‑PERF‑1** | Readiness/port waits are bounded (no unbounded loops); startup adds ≤ a few seconds of overhead beyond the proxy's own boot. |
| **NFR‑ROBUST‑1** | Missing prerequisites (Python, LiteLLM, `claude`, a free port) degrade gracefully with actionable messages, never a stack trace. |
| **NFR‑QUAL‑1** | All `.ps1` parse without syntax errors and all `.sh` pass `bash -n` (verified by `tests/policy-ci`). |
| **NFR‑GOV‑1** | Config is data, not code (**C2**); models are pinned to an explicit ladder (**C4**); side‑effects are honest about local‑vs‑gateway enforcement (**C10**). |

## 6. Constraints & assumptions

- Target OS: Windows 10/11 (PowerShell 5.1+), macOS, mainstream Linux with bash.
- Requires Python 3.11/3.12 and network egress to the chosen provider and to `claude.ai`/`github`
  for optional CLI install.
- The upstream model **must support tool/function calling**, otherwise Claude Code can only emit
  text and cannot edit files (documented limitation, surfaced by the benchmark/tool‑test).
- Local hooks are **defence‑in‑depth**; hard security guarantees require the server‑side gateway
  (**C10**). This SRS does not claim the local scripts are a hard security boundary.

## 7. Acceptance criteria (traceable to tests)

A change is acceptable when: all `tests/policy-ci` checks pass (parse, JSON validity, config‑uses‑env,
gitignore/gitattributes, cross‑platform flag parity), all `tests/red-team` checks pass (no secrets in
tracked files, dummy auth token, no literal key in config/profiles), and the documented smoke flows
(`--help`, `--stop`, `--list`, `-Status`, `-ListProfiles`) exit cleanly. See [spec.md §8](spec.md) and
`tests/run-tests.ps1` / `tests/run-tests.sh`.
