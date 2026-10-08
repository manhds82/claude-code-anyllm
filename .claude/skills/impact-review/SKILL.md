---
name: impact-review
description: "Run the review→fix→test loop on a change, scoped to its blast radius: map impact, review through 3 lenses in parallel, adversarially verify each finding, fix only confirmed ones, test the affected area, then the QA gate. Bounded retries. (H3/H7)."
stage: verification
agents: [impact-analyzer, code-reviewer, fix-agent, targeted-tester, reviewer, qa-reviewer]
prompt_template: |
  Run the impact-scoped review→fix→test loop for pipeline {pipeline_id} on the
  diff {base}..{head}.

  1. IMPACT — impact-analyzer builds the impact map from git diff: affected
     modules/routes/tests, and force_full if a hub or unmapped path is touched.

  2. REVIEW (parallel, 3 lenses) — three code-reviewer runs, one each for
     correctness / security / performance, reading ONLY files in the impact map.
     Each finding carries file:line + a concrete failure scenario.

  3. VERIFY (adversarial) — for each finding, a run that TRIES TO REFUTE it.
     Survives refutation → CONFIRMED; refuted or non-reproducible → dropped. This
     is what stops the fixer from editing working code on a false finding — the
     number-one way these loops make things worse.

  4. FIX — fix-agent applies the smallest fix per CONFIRMED finding, inside
     guard-zones.json and the impact map only, one commit each, with a regression
     test. A fix that needs to leave scope is escalated, not smuggled in.

  5. TEST — invoke the run-affected-tests skill: scoped suites + always_run smoke,
     or full on a hub change. Report counts from the actual run.

  6. LOOP / GATE — if tests fail or new CONFIRMED findings remain, go back to 4.
     Bounded by casan-policies max_fix_retries (default 3); at the limit, stop and
     escalate to a human — never loop forever burning tokens. When clean, hand to
     the qa-gate skill (qa-reviewer) for the final adversarial verdict.

  Report: the impact map, findings (confirmed vs dropped), fixes applied, the test
  report, retry count, and the final verdict.

  7. RECORD (always, including on failure) — append the run to
     .harness/telemetry/pipeline-runs.jsonl so it survives this terminal:

       powershell -File .harness\scripts\powershell\harness-pipeline-log.ps1 `
         -Skill impact-review -PipelineId {pipeline_id} -Verdict <APPROVED|CHANGES_REQUIRED|REJECTED|ESCALATED|ABORTED> `
         -Found <n> -Confirmed <n> -Dropped <n> -Fixed <n> -Retries <n> `
         -Files <n> -TestsPassed <n> -TestsFailed <n> -Base {base} -Head {head}

       # bash: .harness/scripts/bash/harness-pipeline-log.sh --skill impact-review ...

     Report the ACTUAL counts from this run. The recorder rejects a record whose
     numbers cannot describe a real run -- more fixed than confirmed, or
     confirmed+dropped exceeding found -- so a padded record does not silently
     become a dashboard row.

     Record the run even when it ends ESCALATED or ABORTED. A loop that only logs
     its successes produces a success rate of 100%, which is worse than no
     number: it reads as evidence and is not.
inputs:
  pipeline_id:
    type: string
    required: true
  base:
    type: string
  head:
    type: string
output: verdict
---

# impact-review

The Agent Pack's orchestration skill — the review→fix→test loop that all nine
2026-08-03 consuming-project proposals independently designed. It ties together
the four new Agent Pack agents plus the existing `qa-gate`, and its whole design
principle is **narrow but safe**: work only on the change's blast radius (cheap,
fast) without ever under-scoping in a way that ships a bug.

Three safety chokepoints, in order, because each catches what the previous
cannot:

1. **Adversarial verify before any fix** — a plausible-but-false finding never
   reaches the fixer, so the loop cannot introduce the bug it was meant to catch.
2. **Bounded retries** — `max_fix_retries` from `casan-policies.yaml` caps the
   fix↔test loop; hitting the cap escalates to a human rather than looping.
3. **qa-gate re-runs the suites** — the final gate does not trust the tester's
   report; it re-executes, and an unrun suite yields CHANGES_REQUIRED, never
   APPROVED.

Impact selection and the test runner come from project-owned config
(`contracts/impact-map.yaml`, `.harness/control/agent-config.yaml`); the skill and
agents ship in the bundle. That two-layer split (C2) is what lets one common
pipeline serve a Vitest repo, a pytest repo and a PHPUnit repo without hardcoding
any of them.
