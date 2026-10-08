# Handoff — claude-code-anyllm

_Updated: 2026-10-08 (session: harness 1.8.11 push + Harness Gate green)_

## NOW (true as of 2026-10-08)

- `main` == `origin/main` at `717ab65` (`manhds82/claude-code-anyllm`, **PUBLIC** repo).
- **Harness Gate is green on `717ab65`** — run 37749945301, all 4 jobs executed and passed:
  doctor, policy-ci, secret-scan, golden. CI (tests + PR review) green too (run 37749945495).
  Source: `gh run list --commit 717ab65…` / `gh run view 37749945301`, read 2026-10-08.
- Local re-run before push: golden 36/36 (8 deny cases still deny), policy-ci 53 pass / 0 fail / 2 warn.
- Commits landed this session (in order — install before gate, B-79):
  - `48d62c2` standard-governance 1.8.11 install. Squashed from three unpushed commits
    (d90a063 bundle 1.6.18, 374df9c untrack .harness, 2a60ca9 install) so that machine
    state from d90a063 (`.harness/portal-sync.json` with work email + portal URL, ledger,
    telemetry) never reached the public history. `.harness/` is tracked again (148 files).
  - `c72502f` `.github/workflows/harness-gate.yml` (1.8.11 template).
  - `5e2973d` UTF-8 BOM on `open-with-claude.ps1` (policy-ci `bom:powershell-has-utf8-bom`).
  - `717ab65` `\b` anchors on the recursive-delete and ledger-tamper deny patterns in
    `.harness/control/risk-policy.yaml` (golden H4 cases; they also made the local guard
    deny plain prose such as "confirm …").
- Pushing: git uses `gh auth git-credential` with the **active** gh account. The repo owner is
  `manhds82`; the default active account is `manhdauvn09-manhds` (403 on push). Switch with
  `gh auth switch --hostname github.com --user manhds82`, push, switch back.

## NEXT

- Decide what to do with the remaining dirty files (see OPEN), then commit them one at a time.
- Merge the rest of `.harness/control/risk-policy.yaml.new` (deliberately left out; it has
  new `-EncodedCommand` handling and loosens `[^\n]*` to `.*` — review before adopting).

## OPEN

- **Hardcoded API key in `start-claude.ps1`** (uncommitted working-tree change, `$Key` default
  plus a new BaseUrl/Model). Violates C5. Do not commit it; rotate the key if it was ever
  shared. — until: `$Key` default is `""` again and the key has been rotated.
- `config/litellm_config.yaml` uncommitted: adds an alias `claude-sonnet-4-6` that routes to
  `DeepSeek-V4-Flash` via `LLM_API_KEY_FPT`, plus router retries and a local cache. Product
  plane; the alias name looks like an Anthropic model ID but isn't one. — until: committed
  or discarded by the owner.
- Untracked, not yet decided: `CLAUDE.harness.md`, `contracts/` (incl. `project.yaml.new`
  whose name/description are the toolkit's, not this project's), `docs/casan_harness_assessment.md`,
  `docs/harness-rules-and-assessment-20260719.html`. — until: each is committed or deleted.
- policy-ci WARN `C6:tool-defaults-match-registry`: `risk-policy.yaml` tool_deny_defaults
  disagree with `tool-registry.json` for deploy, http_fetch, mysql_query, run_command.
  — until: risk-policy.yaml matches the registry and the warning is gone.
- Local branch `backup/pre-aprime-20261008` (old 2a60ca9, contains the leaky d90a063).
  Never push it. — until: owner deletes it.
- CI annotations: actions/checkout@v4 + setup-python@v5 on deprecated Node 20; `ubuntu-latest`
  moves to Ubuntu 26 from 2026-10-19. — until: actions bumped and a gate run after 2026-10-19 is green.

## AVOID

- `git add -A` / `git add .` — the tree holds a secret and machine state.
- Pushing the gate workflow before the install it depends on (B-79).
- Committing `.harness/portal-sync.json`, `.harness/ledger/`, `.harness/telemetry/`, `.harness/context/`.
- Typing literal destructive-command text in shell commands or `-m` messages: the guard
  matches it even inside quotes. Use `git commit -F <file>`.
