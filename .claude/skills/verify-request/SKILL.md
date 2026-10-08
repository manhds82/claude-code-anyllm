---
name: verify-request
description: "Triage a request before any code is written — ground its intent, plane, risk class and approval needs, and return ready / needs_clarify / blocked. The intake stage (H1)."
stage: intake
agents: [gatekeeper]
prompt_template: |
  Triage this request for pipeline {pipeline_id} BEFORE any code is written.

  Request: {raw_request}

  Produce seven fields, each GROUNDED in something you actually read. If a field
  cannot be grounded, say so — an invented field is worse than an absent one,
  because every stage after you treats it as established.

  1. intent — what the requester actually wants, one sentence, your own words.
     If your restatement and their wording could describe different work, that is
     needs_clarify, not a guess.
  2. plane — assistant_workflow or product_runtime. Check the `governs:` field
     convention in .harness/control/*.yaml.
  3. risk_class — name the matching entry in .harness/control/risk-registry.yaml
     or risk-policy.yaml. Do not improvise a severity.
  4. approval_required — per contracts/approval-flow.yaml.
  5. guard_zone_ok — do the paths this would touch fall in a protected zone in
     .harness/control/guard-zones.json?
  6. duplication — has this already been done? Search before answering.
  7. verdict — ready | needs_clarify (at most 3 questions, each one that actually
     changes what gets built) | blocked (name the specific rule and file).

  Write artifacts/intake/{pipeline_id}-request-intake.md. Do NOT write code, do
  NOT call a side-effect tool, and do NOT modify pipeline-context.yaml — the Boss
  owns that file and records your outcome.
inputs:
  raw_request:
    type: string
    required: true
  pipeline_id:
    type: string
output: intake-doc
---

# verify-request

The **intake** node of the DAG (`planning-light` profile) — the first stage, and
the only one positioned to ask whether the request itself is sound.

Before v1.6.0 the pipeline ran straight from a request into analysis. A misread
or under-specified request therefore produced a clean, well-reviewed, fully
tested implementation of *the wrong thing*, and every later stage judged it
against the same misreading, so nothing caught it. This stage exists for that
failure and no other.

Feeds `gate.analysis` via `gate_rules.intake_verdict_not_ready: pause` in
`contracts/workflow.yaml` — a verdict other than `ready` pauses rather than
halts, because the fix is usually three answers from a human, not a rollback.

Runs on a deliberately cheap profile: intake fires on every request, and taxing
the whole pipeline with the top planning model for a triage decision a small
model answers well is the wrong trade.
