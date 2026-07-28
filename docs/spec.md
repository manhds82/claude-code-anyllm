# Architecture & Design Spec — claude-code-anyllm

> **Status:** Baseline v1.0 · **Last updated:** 2026-07-22
> **Companion:** [SRS.md](SRS.md) (requirements). Requirement IDs (FR‑*, NFR‑*) are referenced inline.

---

## 1. System context

```
                 ┌──────────────────────────────────────────────┐
   you  ───────► │  Claude Code (VS Code ext / CLI)             │
                 │  reads ANTHROPIC_BASE_URL / _AUTH_TOKEN /     │
                 │  _MODEL from env or ~/.claude/settings.json   │
                 └───────────────┬──────────────────────────────┘
                                 │  Anthropic Messages API
                                 ▼
                 ┌──────────────────────────────────────────────┐
                 │  LiteLLM proxy  (localhost:4000)             │
                 │  config/litellm_config.yaml (generated)      │
                 │  key via  os.environ/LLM_API_KEY             │
                 └───────────────┬──────────────────────────────┘
                                 │  OpenAI /v1 API
                                 ▼
                 ┌──────────────────────────────────────────────┐
                 │  Provider  (FPT / OpenAI / OpenRouter / …)   │
                 └──────────────────────────────────────────────┘
```

The launcher scripts are the control plane; the running system is just *Claude Code → LiteLLM →
provider*. No custom long‑running service is added — the proxy is stock LiteLLM.

## 2. Components (file map)

| Component | Files | Responsibility |
|-----------|-------|----------------|
| **Installer** | `setup-litellm.ps1`, `setup-litellm.sh` | Create `.venv`, install `litellm[proxy]`, pin `claude` stable (FR‑SETUP). |
| **Launcher** | `start-claude.ps1`, `start-claude.sh` | Generate config, start proxy, wait for health, wire + open editor; provider/model utilities (FR‑RUN, FR‑PROVIDER). |
| **Brain toggle** | `toggle-brain.ps1`, `toggle-brain.sh`, `toggle-brain.bat` | Swap `~/.claude/settings.json` between profiles (FR‑TOGGLE). |
| **Profiles** | `profiles/claude.json`, `profiles/fpt.json` | Declarative `env` blocks applied to Claude Code. |
| **Proxy config** | `config/litellm_config.yaml` | *Generated each run*; maps the alias → `openai/<model>` at the provider. |
| **End‑user docs** | `guideline.en.html`, `guideline.vi.html`, `README.md` | How to install/run/change key & model. |
| **Engineering docs** | `docs/SRS.md`, `docs/spec.md` | Requirements + this design. |
| **Tests** | `tests/run-tests.ps1`, `tests/run-tests.sh` | `policy-ci` + `red-team` suites. |
| **Governance harness** | `.harness/`, `contracts/`, `CLAUDE.md` | CASAN policies, schemas, hooks, ledger (infrastructure). |

**Naming convention (C7):** PowerShell is the primary shell; every `*.ps1` has a `*.sh` counterpart
kept at behavioural parity. Flags map 1:1 (`-Model` ↔ `--model`, `-Stop` ↔ `--stop`, …).

## 3. Key runtime flow — `start-claude`

1. **Resolve settings** — base URL, model, key from flags → file defaults → (key only) `LLM_API_KEY`
   env → hidden prompt (FR‑RUN‑1, FR‑KEY‑1).
2. **Ensure LiteLLM** — if the venv/executable is missing, delegate to `setup-litellm` (FR‑RUN‑3).
3. **Write config** — regenerate `config/litellm_config.yaml`, UTF‑8 **no BOM**, key referenced as
   `os.environ/LLM_API_KEY` only (FR‑RUN‑2, NFR‑SEC‑3).
4. **Pick a port** — probe from 4000 upward (bounded to +20) for a free listener (FR‑RUN‑4, NFR‑PERF‑1).
5. **Start proxy** — Windows: a separate PowerShell window; POSIX: `nohup … &` writing
   `litellm-proxy.log`. The key is injected as `LLM_API_KEY` into the proxy process only (FR‑KEY‑3).
6. **Wait for readiness** — poll `/health/liveliness` with a bounded loop, then continue even if not
   confirmed (with a warning) (FR‑RUN‑5, NFR‑ROBUST‑1).
7. **Wire Claude Code** — set `ANTHROPIC_BASE_URL`, dummy `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`
   and the three `ANTHROPIC_DEFAULT_*_MODEL` aliases; `unset`/`Remove-Item` any real
   `ANTHROPIC_API_KEY`; open the editor (FR‑RUN‑6, NFR‑SEC‑2).

## 4. Config generation (single source of truth)

The proxy config is **derived, never hand‑edited**:

```yaml
model_list:
  - model_name: <alias>                 # what Claude Code asks for (ANTHROPIC_MODEL)
    litellm_params:
      model: openai/<provider-model>    # the real model at the provider
      api_base: <base-url>              # provider /v1 endpoint
      api_key: os.environ/LLM_API_KEY   # NEVER a literal key (NFR-SEC-3)
```

Because it is regenerated every run, `config/litellm_config.yaml` may show as modified in `git`
after changing model/provider — expected churn, documented in the README.

## 5. Brain‑toggle design

`toggle-brain` treats `~/.claude/settings.json` as the switch. Each `profiles/<name>.json` carries an
`env` object; switching = `Copy-Item profile → settings.json`. Mode is *inferred* from the live
settings: `ANTHROPIC_BASE_URL` starting with `http://localhost` ⇒ **proxy**; empty `env` ⇒
**claude**; anything else ⇒ **custom** (FR‑TOGGLE‑4). Proxy lifecycle (start/stop/status) reuses the
same port + health logic as the launcher.

## 6. Secret model (NFR‑SEC)

- **Boundaries.** The key exists in exactly three transient places: a runtime flag, the
  `LLM_API_KEY` env var, or an in‑memory hidden prompt. It is handed to the proxy through the
  environment and referenced from config as `os.environ/LLM_API_KEY`.
- **Never persisted.** No script writes the key to a file; profiles and the generated config hold
  only env references; `.gitignore` excludes `.env`, `*.key`, the generated config's churn is benign
  (no secret in it).
- **Dummy inbound token.** Claude Code → proxy uses `ANTHROPIC_AUTH_TOKEN="litellm-proxy"`; the real
  provider key lives only at the proxy.
- **Honest enforcement (C10).** These are local, defence‑in‑depth measures. Hard prevention of
  egress/secret‑exfil belongs to the server‑side gateway described in `.harness/control/`.

## 7. Cross‑platform strategy (C7 / NFR‑X‑PLAT)

- Two implementations per tool, parity‑checked by tests (flag sets must match).
- `.gitattributes` pins `*.sh eol=lf`, `*.ps1 eol=crlf` so a Windows‑authored `.sh` still runs on
  POSIX (NFR‑X‑PLAT‑2).
- Path handling is relative to the script directory (`$PSScriptRoot` / `dirname "$0"`); no usernames.

## 8. Testing strategy

Tests are **deterministic, offline, and side‑effect‑free** (they never launch a proxy, hit a
provider, or open an editor). Two suites, matching the harness `regression_suites_required`
(`.harness/control/casan-policies.yaml`):

- **`policy-ci`** (correctness/governance): every `.ps1` parses (AST), every `.sh` passes `bash -n`,
  `profiles/*.json` are valid JSON with a `description`, the generated config references
  `os.environ/LLM_API_KEY` and defines a `model_name`, `.gitignore`/`.gitattributes` cover the
  required entries, and the PowerShell↔bash flag sets are at parity.
- **`red-team`** (security): no secret patterns (`sk-…`, `ghp_…`, `AKIA…`, literal `api_key: "…"`) in
  any tracked file, config/profiles carry no literal key, `ANTHROPIC_AUTH_TOKEN` is the dummy, and
  product scripts do not pipe untrusted remote content into a shell.

Run: `pwsh -File tests/run-tests.ps1` (primary) or `bash tests/run-tests.sh` (parity). Both print a
per‑suite PASS/FAIL summary and exit non‑zero on any failure — suitable for
`.harness` `suite_commands` and the `.github/workflows/claude-review.yml` CI.

## 9. Governance integration (CASAN)

- `docs/SRS.md` + `docs/spec.md` populate the H1 context `srs_path` / `spec_path`
  (`.harness/context/pipeline-context.yaml`) so sub‑agents discover inputs without re‑scanning.
- The two test suites satisfy H3 `regression_suites_required`; their commands are wired into
  `.harness/control/casan-policies.yaml → evaluation.suite_commands`.
- Model ladder (**C4**), config‑as‑data (**C2**), registered side‑effects (**C3**), and honest
  enforcement (**C10**) are inherited from `CLAUDE.md` and the harness control files.

## 10. Known limitations / future work

- Readiness waits use fixed‑interval polling (bounded); could switch to exponential backoff (perf,
  low ROI). Tracked in `buglist.md`.
- Tool‑calling capability of a provider model is only discoverable by running the benchmark; there is
  no static capability registry.
- Windows CMD is only a thin shim; PowerShell is the supported Windows path.
