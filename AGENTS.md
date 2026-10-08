<!-- BEGIN harness-governance -->
<!-- standard-governance v1.8.11 - MANAGED BLOCK. Edits inside are replaced on the next install; put your own project rules OUTSIDE this block. -->

<!--
  Harness AI Toolkit — Common Governance Reference
  Copyright (c) 2026 Dau Sy Manh <manhds@>. All rights reserved.
  Author / Maintainer: Dau Sy Manh <manhds@>
  Bundle: standard-governance

  This file ships INSIDE the governance bundle so it lands in every project
  that installs it (as `CLAUDE.harness.md`, a name distinct from your own
  `CLAUDE.md` so nothing is overwritten). It is a REFERENCE to compare against
  and copy from — not your project's live memory file.
-->

# Governance Reference — the rules every assistant in this repo follows

> **Attribution:** Governance harness authored by **Dau Sy Manh**
> (`manhds@`). When a review/audit skill inspects a project, this header
> and the bundle `maintainer` field identify the source.

**These rules are assistant-agnostic.** Nothing below is specific to one vendor —
only the *file name* an assistant reads is. The installer projects this text into
each guide file your tools use, wrapped in a pair of HTML-comment markers named
`BEGIN harness-governance` / `END harness-governance`:

| File | Read by |
|------|---------|
| `CLAUDE.md` | Claude Code |
| `AGENTS.md` | the cross-tool convention — OpenAI Codex, Cursor, Jules, … |
| `.github/copilot-instructions.md` | GitHub Copilot |

The list lives in `.harness/control/casan-policies.yaml` →
`governance.guide_targets`, with commented entries for Cursor rules, Windsurf,
Cline, Continue, Aider and Firebase Studio — enabling one is uncommenting a line.
Write your own project rules **outside** the managed block; updates only replace
what is inside it. Run the installer with `-MergeGuides` / `--merge-guides`.

> **What this actually buys you.** Only Claude Code *enforces* these rules, via
> `.claude/settings.json` hooks and permission deny lists that can block a tool
> call. Every other assistant has no hook mechanism — for them this text is
> guidance a model may ignore. If you need those assistants genuinely
> constrained, the control has to sit outside the assistant: a server-side
> gateway/PDP, CI that fails the build (`policy-ci`), and branch protection with
> `CODEOWNERS` over `.harness/** .claude/** contracts/**`. Treat this file as a
> shared contract, not as a boundary.

---

## Guiding Principles

- **Hooks > rules:** enforceable hooks beat static conventions in prose.
- **Execution ≠ control:** the tool that executes a side-effect is not the thing
  that decides whether it's allowed; keep the decision in policy/config.
- **No false safety:** local hooks are defense-in-depth. Anything truly
  high-risk needs server-side enforcement at a gateway — say so honestly.
- **Lowest layer sets the ceiling:** the weakest governance layer caps the whole
  system's assurance; don't advertise more safety than the weakest link gives.

## Key Conventions (C1–C10)

- **C1 — Native layout:** use the agent tool's native config dir (`.claude/`);
  project memory lives in `CLAUDE.md`.
- **C2 — Config in data, not code:** guard/hook scripts **read** policy from
  YAML/JSON — never hardcode rules inside scripts.
- **C3 — Registered side-effects:** every side-effect-capable tool has an entry
  in the tool registry; unknown tools are denied by default.
- **C4 — Explicit model ladder:** pin the exact models you allow (e.g. the
  Claude family: Opus 5.5 / Sonnet 5.5 / Haiku 4.5). Any on-prem/OSS
  tier is a separate ladder and must not be mislabeled as the vendor's model.
- **C5 — No hardcoded secrets:** never commit secrets/API keys; source them from
  env or a vault (file-based `*_FILE` secrets for containers).
- **C6 — Side-effects via approved path only:** deny-by-default for dangerous
  operations (destructive shell, deploys, DB writes, outbound fetch) unless they
  run through the approved workflow.
- **C7 — One primary script language + bash parity:** pick a primary shell for
  harness scripts (PowerShell here) and keep a bash counterpart; use absolute
  paths inside harness scripts. Application code (web/back-end) is a separate
  layer and is not bound by this.
- **C8 — Schema-validatable config:** every JSON/YAML policy file is validatable
  by a JSON Schema kept alongside it.
- **C9 — Immutable logging:** every side-effect tool call appends one line to an
  append-only ledger (identity + input/output hash); the chain is tamper-evident.
- **C10 — Honest about enforcement:** local hooks are defense-in-depth; label
  high-risk actions as "needs server-side enforcement" rather than implying the
  local hook is a hard boundary.
- **C11 — Operator handoff via a runnable script.** When something must run on the
  operator's own machine or a server — a config change, a service restart, a
  build, a deploy, any step the assistant should not or cannot do itself — do not
  hand over a loose list of shell lines to paste. Generate a single ready-to-run
  **PowerShell `.ps1`** (PowerShell is the operator's primary shell; loose
  cross-shell snippets have failed on their machine) and tell them exactly how to
  run it. **Target Windows PowerShell 5.1** — the operator runs `powershell`, NOT
  `pwsh` (PowerShell 7): give the invocation as `powershell -File <path>`, and
  write the script in 5.1-compatible syntax (no `??` null-coalescing, no ternary
  `? :`, no `pwsh`-only cmdlets). A script that needs PowerShell 7 fails on their
  machine with "pwsh is not recognized". The script must be self-contained and
  idempotent where possible:
  - It `cd`s to the correct project directory itself (absolute path) — the
    operator should never have to know where to stand.
  - It prints what it is about to do, does it, and verifies the result
    (health check / status) so a failure is visible, not silent.
  - **Build and deploy are operator-run by default.** The assistant prepares the
    `.ps1` and gives the exact invocation; the operator runs it. Do not perform a
    build or deploy on the operator's behalf unless they have explicitly said to.
  - Every time you ask the operator to do anything, give the concrete command,
    including the `cd`, so it can be run without further thought.

  And when you ask the operator to **decide**, never ask abstractly. State each
  option concretely (what it does, its cost, its risk), then **recommend one and
  say why** — the operator should be choosing between spelled-out options, not
  inventing them.
- **C12 — A gate must prove it ran.** Any blocking mechanism — a CI workflow, a
  hook, an approval step, an eval suite — has to leave evidence that it
  executed. A gate with no execution trace is **unproven**, and unproven must be
  reported as unproven, never as green. "We have no evidence it ran" and "it ran
  and passed" are opposite claims; a dashboard that renders them the same way is
  worse than no dashboard, because absence of a gate is visible while a dead one
  reads as coverage. Where execution genuinely cannot be observed from where you
  are standing (a CI run is a server-side fact), say *that* — "cannot verify
  from here" is compliant; assuming good is not. `harness doctor` asserts this.
- **C13 — Inference must cite its source, and refuse a weak one.** When a script
  infers a value rather than being told it — the default branch, the test
  runner, the tech stack — it must carry *where the value came from* alongside
  the value, and it must decline to act confidently when the only available
  source is stale or ambiguous. Provenance is not documentation; it is what lets
  a caller downstream decide whether the value is good enough. `refs/remotes/*/HEAD`
  is a local cache written at clone time: one repo's pointed at a temporary
  branch while its real default was `main`, and trusting it pinned CI to a
  branch that was later deleted. Prefer asking the authority (the remote, the
  config file, the lockfile); treat a guess as a guess, and let a guessed value
  produce a warning rather than a pass.
- **C14 — A warning channel must keep its credibility.** A diagnostic log,
  alert, or health badge that raises false alarms is a **P0 defect**, not an
  annoyance. Its entire value is that someone still reads it on the day it
  matters, and every false positive spends that down. Treat "the log reports
  successes as failures" with the same urgency as a broken build, and when
  cleaning one up, remove only the entries you can *prove* are false — deleting
  genuine diagnostics to quiet a noisy file trades a cosmetic problem for a
  blind spot. Corollary: a screen that renders "no data" as green is the same
  bug in another medium.
- **C15 — Every task ends with a handoff.** Before declaring a task done,
  update the project's `Handoff.md` so the next session (any assistant, any
  person) can start without re-deriving state: what is true NOW (dated, with
  measured numbers and where they came from), what comes NEXT, what is OPEN
  (each item with an `until:` condition that retires it) and what to AVOID.
  Dated handoff notes (`docs/HANDOFF-*.md`) that a newer one supersedes are
  **merged, then deleted**: copy every still-live OPEN/AVOID item into
  `Handoff.md` first, then delete the old file — git keeps its history.
  Never delete evidence (`docs/_parts/`, logs, XML reports): a handoff
  summarises evidence, it does not replace it. Claude Code reminds you once at
  `Stop` when files changed this session but `Handoff.md` did not, and
  `harness doctor` warns when it falls behind the latest commit
  (`casan-policies.yaml` → `handoff`).

## Plane separation — what these policies do NOT govern

The harness governs the **assistant plane**: the AI/CI workflow that *builds*
this repo — which agents run, which models they plan/code/review with, which
tools they may call, how a pipeline stage retries. It does **not** govern the
**product plane**: whatever your shipped application does at runtime.

This matters most where the two look alike. A policy pack declares model IDs
under something like `orchestration.model_fallback`, which reads exactly like
"the model fallback chain" — so in a repo whose *product* also calls LLMs,
pointing the product's gateway at it looks like a sensible upgrade. It is an
outage: an assistant-plane model ID sent to a different provider's endpoint
fails every call, and it surfaces as a **bad key**, not a bad model name, so
whoever debugs it goes hunting through credentials.

Two rules follow:

- Every policy layer states its plane in a machine-readable field
  (`governs: assistant_workflow` or `governs: product_runtime`) — in a field,
  not in a comment, so a check can assert it.
- Product code neither hardcodes an assistant-plane model ID **nor reads the
  harness config directory at all**. The second half is the one that matters:
  it catches the runtime-lookup form, where the product loads the policy file
  and pulls the chain out of it — which a grep for model IDs never sees.

Your product's own model choices belong in your product's own config, per
provider. policy-ci asserts the separation; keep the two apart on purpose.

## Model Reference (adjust to your licensed models)

| Profile       | Opus 5.5    | Sonnet 5.5  | Haiku 4.5   |
|---------------|-------------|-------------|-------------|
| planning      | Primary     | Fallback    | —           |
| coding        | Fallback    | Primary     | —           |
| review        | Fallback    | Primary     | —           |
| summarization | —           | Fallback    | Primary     |

---

*Governance harness · standard-governance bundle · © 2026 Dau Sy Manh
<manhds@>.*

<!-- END harness-governance -->
