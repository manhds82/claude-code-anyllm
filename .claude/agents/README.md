# Agent fleet — 15 agents

`contracts/agent.yaml` is the SSOT: it owns each agent's model profile, authority,
and its allowed/blocked tool lists. The `.md` files here hold the *instructions* an
agent runs on. When the two disagree, the contract wins — the `.md` cannot grant
itself a tool the contract blocks.

| Agent | Tier | Profile | Stage | Writes code? | Purpose |
|---|---|---|---|---|---|
| `boss` | 3 | planning | — | via delegation | Orchestrates, delegates, owns `pipeline-context.yaml` |
| `architect` | 2 | planning | — | no | Architecture, ADRs, trade-offs |
| `analyst` | 2 | planning | analysis | no | Requirement analysis, spec review |
| `researcher` | 2 | planning | — | no | Deep investigation, dependency/vuln research |
| `developer` | 2 | coding | implementation | **yes** | Implements changes per the analysis |
| `tester` | 2 | coding | test | **yes** (tests) | Writes and runs suites, produces the report |
| `devops` | 2 | coding | — | **yes** | CI/CD, deploys, infra-as-code |
| `reviewer` | 2 | review | verification | no | Verifies the implementation meets requirements |
| `writer` | 2 | summarization | — | **yes** (docs) | Documentation, changelogs, migration guides |
| `gatekeeper` | 2 | **planning-light** | **intake** | no | Pre-code triage — added v1.6.0 |
| `qa-reviewer` | 2 | review | **qa-gate** | no | Adversarial final gate — added v1.6.0 |
| `impact-analyzer` | 2 | **planning-light** | — | no | Agent Pack: diff → affected modules/routes/tests — added v1.6.0 |
| `code-reviewer` | 2 | review | — | no | Agent Pack: one-lens review (correctness/security/perf) — added v1.6.0 |
| `fix-agent` | 2 | coding | — | **yes** | Agent Pack: smallest fix per CONFIRMED finding, in-scope only — added v1.6.0 |
| `targeted-tester` | 2 | coding | test | **yes** (tests) | Agent Pack: runs only affected tests, escalates to full on hub changes — added v1.6.0 |

## The two gates (v1.6.0)

`gatekeeper` and `qa-reviewer` bracket the coding stages: one runs before any code
exists, the other after it does. Both are read-only by construction, because a gate
that can edit what it judges is not a gate.

- **`gatekeeper`** answers the question no other stage asks: *is this the right
  thing to build at all?* Before v1.6.0 the pipeline ran straight from a request
  into analysis, so a misread request produced a clean, well-reviewed, fully tested
  implementation of the wrong thing — and every later stage judged it against the
  same misreading, so nothing caught it. Runs on `planning-light` deliberately:
  intake fires on every request, and paying for the top planning model to make a
  triage call a small model makes well is the wrong trade.

- **`qa-reviewer`** is the last thing before a release tool may run, and is a
  *second adversarial* review rather than a stamp on the first. `verification` asks
  "does this meet the criteria"; `qa-gate` assumes it does not and goes looking.
  It holds `Bash` for exactly one reason — to run the test suites — because its
  defining rule is unenforceable otherwise: **if the suites were not actually run,
  the verdict is CHANGES_REQUIRED, never APPROVED.** An APPROVED resting on an
  unrun suite is worse than no gate at all: it launders "unknown" into "verified",
  and the deny hook then waves the release through.

To record a verdict, `qa-reviewer` holds `__workflow_gate__` — a *virtual* tool
with no executor behind it, constrained by schema to `side_effect: false` /
`risk_level: none`. That exists so recording an outcome never requires granting a
real write tool to the agent judging the code.

## The Agent Pack (v1.6.0) — review → fix → test on the blast radius

All nine consuming-project proposals of 2026-08-03 independently designed the same
loop, so it ships as a standard set rather than being rebuilt per project. Four
agents, orchestrated by the `impact-review` skill, with `qa-gate` as the final
step:

- **`impact-analyzer`** turns a diff into an impact map (affected modules, routes,
  tests) so the rest of the loop reads and runs only what changed — and forces a
  full run on a hub file or an unmapped path, because under-scoping silently is
  the one failure that makes selective testing unsafe.
- **`code-reviewer`** runs three-up, one lens each (correctness / security /
  performance), scoped to the map. Every finding carries a concrete failure
  scenario; a hunch it cannot make concrete is marked plausible, not asserted.
- **`fix-agent`** touches only CONFIRMED findings (each survived an adversarial
  verify), smallest diff, inside `guard-zones.json` and the impact map. Fixing an
  unconfirmed finding is the number-one way these loops introduce the bug they
  meant to catch — hence the verify step in front of it.
- **`targeted-tester`** runs the affected suites (project runner from
  `.harness/control/agent-config.yaml`), escalates to full on a hub change, and
  writes a report whose counts come from the actual run — never a copied or
  fabricated green.

Two-layer split (C2): the bundle ships the agents and the `impact-review` /
`run-affected-tests` skills; each project supplies only `agent-config.yaml` (its
test runner) and `contracts/impact-map.yaml` (its source→test mapping), both
project-owned so a re-install never overwrites them. That is what lets one common
pipeline serve a Vitest, pytest or PHPUnit repo without hardcoding any of them.

## Honest about enforcement (C10)

The tool lists in `contracts/agent.yaml` are enforced for Claude Code through
`.claude/settings.json` hooks and permission deny lists, which can genuinely block a
call. For any other assistant there is no hook mechanism, so the same lists are
guidance a model may ignore. Anything that must actually be prevented needs
server-side enforcement at the gateway — not a line in this table.
