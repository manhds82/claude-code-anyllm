---
name: verify-implementation
description: "Verify an implementation against its acceptance criteria and the judge rubric, run tests, and emit an APPROVED/CHANGES_REQUIRED/REJECTED verdict — the verification stage (H3)."
stage: verification
agents: [reviewer, tester]
prompt_template: |
  Verify the implementation for pipeline {pipeline_id}.

  Inputs:
  - Analysis (acceptance criteria): {analysis_doc}
  - Implementation diff: {implementation_diff}

  Steps:
  1. Check EACH numbered acceptance criterion from the analysis — met / not met, with evidence.
  2. Run the test suites; record passed/failed/skipped (do not fabricate — run them).
  3. Score against the judge rubric (.harness/eval/judge/judge-rubric.md) —
     give EACH of the 5 dimensions a 0-100 score: correctness / maintainability /
     security / performance / traceability. Overall = their average unless you
     justify a weighting.
  4. Emit a verdict per the hard-gate rules:
     APPROVED (>=80 and no dim <60) | CHANGES_REQUIRED | REJECTED (overall <60).
  5. Write: artifacts/verification/{pipeline_id}-verdict.md, AND put the 5 scores
     into the evidence bundle's `review_verdict.rubric_scores` (H3 depth — the
     Portal ingests them into the per-dimension Prompt Score view). Never
     fabricate a dimension score; base each on observed evidence.

  Be adversarial on security & correctness; a plausible-but-unverified claim is
  a CHANGES_REQUIRED, not an APPROVED.
inputs:
  pipeline_id:
    type: string
    required: true
  analysis_doc:
    type: string
  implementation_diff:
    type: string
output: verdict
---

# verify-implementation

The **verification** node of the DAG (review profile). Feeds the hard-gate
(`hard-gate.ps1`): APPROVED continues, CHANGES_REQUIRED loops back to
implementation (retry counter), REJECTED halts for human intervention (H3/H5).

Pairs `reviewer` (judges) with `tester` (actually runs suites) so the verdict
rests on executed tests, not on reading the diff alone.
