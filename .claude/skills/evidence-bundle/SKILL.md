---
name: evidence-bundle
description: "Assemble the 8-part Definition-of-Done evidence bundle for a change and append it to the hash-chain ledger — the governance/audit close-out (H5)."
stage: governance
agents: [reviewer, writer]
prompt_template: |
  Assemble the evidence bundle for change {change_id}.

  Gather the 8 DoD parts (§18.3):
  1. requirement_trace  — spec_ref + requirement ids the change satisfies
  2. design_impact      — components touched, design doc ref
  3. code_diff          — files changed, diff ref, diff hash
  4. test_report        — passed/failed/skipped/coverage + report ref
  5. security_scan      — scanner, findings, high/critical count, pass?
  6. review_verdict     — verdict + score + reviewer + feedback + rubric_scores
                          (copy ALL 5 judge dimensions from the verification
                          verdict verbatim: correctness / maintainability /
                          security / performance / traceability, each 0-100.
                          Omit the key entirely if the judge emitted none --
                          never invent a dimension score. The Portal ingests
                          these into the per-dimension Prompt Score view.)
  7. approval_record    — required? approved_by / at / ref
  8. cost_telemetry     — tokens, est cost, duration

  Then append to the ledger (immutable, hash-chained):
    evidence-ledger.ps1 bundle -EntryFile <json>
    evidence-ledger.ps1 append -EntryFile <json>

  Do NOT fabricate any part — if a section has no real data yet, mark it PENDING.
inputs:
  change_id:
    type: string
    required: true
output: evidence-bundle
---

# evidence-bundle

The audit close-out (H5). Run by `reviewer` + `writer` after a change passes
verification. Produces the 8-part bundle and appends it to
`.harness/ledger/chain.jsonl` via `evidence-ledger.ps1` (append-only,
tamper-evident). This is what the Portal's Action Log / Prompt Score viewers
later ingest (M3).

**Honesty (C10):** every part must trace to a real artifact; PENDING is an
acceptable value, a fabricated pass is not.
