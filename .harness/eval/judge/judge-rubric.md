# LLM-as-Judge Rubric — H3 Evaluation

## Overview
Judge model band: **CRITICAL / Opus 5.5** — the `review` profile at power 8–10 in
`contracts/agent.yaml` (its primary, Sonnet 5.5, is for ordinary review, not for judging).
Not Sonnet 5.5 on purpose: most code here is written by Sonnet 5.5 (the `coding` primary),
and a judge from the same model grades its own habits kindly. The release gate reads this
verdict, so it gets the strongest model on the ladder — the same choice as `qa-reviewer`.
Judge evaluates pipeline output against the golden dataset and rubric dimensions.

## Dimensions

| Dimension | Weight | Scale | Description |
|-----------|--------|-------|-------------|
| **Correctness** | 35% | 1–5 | Does the output match the expected result from the golden dataset? Are all acceptance criteria met? |
| **Maintainability** | 20% | 1–5 | Is the code clean, well-structured, following project conventions (C1–C10)? No dead code, no premature abstraction? |
| **Security** | 20% | 1–5 | Are there OWASP top-10 issues? Hardcoded secrets (C5)? Unguarded side-effects (C6)? |
| **Performance** | 10% | 1–5 | Is the approach efficient? No unnecessary computation, I/O, or network calls? |
| **Traceability** | 10% | 1–5 | Is the change traceable to requirements? Are artifacts updated (pipeline-context.yaml, evidence)? |
| **Intake clarity** | 5% | 1–5 | Did the gatekeeper's intake verdict ground every one of its seven fields in something read, rather than inventing any? Was `ready` / `needs_clarify` / `blocked` chosen with a stated reason? A pipeline that began from an ungrounded reading of the request can score well on every other dimension and still have built the wrong thing — this dimension is the only one that looks back at whether the request itself was understood. |

> **Intake clarity is scored but not yet gate-required.** The H3-2 evidence gate
> (`rubric_dimensions` in `portal/backend/config/casan-criteria.yaml`) still
> requires only the original five. Requiring six would make every prompt_score
> row already ingested stop counting, and would penalize a project still on the
> 3-stage DAG, which has no intake stage and so cannot emit the dimension at all.
> Score it, report it, act on it — just don't fail a project for its absence yet.

## Scoring

- **Score = Σ(weight × score) / 5 × 100** → 0–100
- **APPROVED**: score ≥ 80 AND no dimension < 3
- **CHANGES_REQUIRED**: score ≥ 60 OR any dimension < 3
- **REJECTED**: score < 60

## Hard Gate Logic

| Verdict | Action |
|---------|--------|
| APPROVED | Pipeline continues. Evidence bundle marked complete. |
| CHANGES_REQUIRED | Pipeline pauses. Back to implementation stage. Increment retry counter. |
| REJECTED | **Pipeline HALTED.** Hard stop. Requires human intervention to restart. |

## Retry Cycle (BACK-TO-PLAN)

- Max cycles: **3** (configured in `workflow.yaml#retry_policy.max_cycles`)
- On REJECTED after max cycles: pipeline enters `failed` status, requires human override.
- On CHANGES_REQUIRED: auto-loop back to implementation with judge feedback as input.
