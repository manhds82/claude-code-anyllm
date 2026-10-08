---
name: implement-change
description: "Implement code changes per the analysis document — the implementation stage of the standard pipeline, guard-zone and side-effect aware."
stage: implementation
agents: [developer]
prompt_template: |
  Implement the change described in: {analysis_doc}

  Rules (H2/H4/C6):
  1. Only touch paths allowed by .harness/control/guard-zones.json for your role.
  2. No side-effect tool (deploy/db/http_fetch/run_command) outside the approved
     workflow DAG — if you need one, stop and request it, don't improvise.
  3. Match surrounding code style; no dead code, no premature abstraction.
  4. Never hardcode secrets (C5) — the secret-scan hook will block you anyway.

  Produce a diff summary: artifacts/implementation/{pipeline_id}-diff.md
  listing files changed, why each change, and which acceptance criteria it covers.
inputs:
  analysis_doc:
    type: string
    required: true
  pipeline_id:
    type: string
output: code-diff
---

# implement-change

The **implementation** node of the DAG. Run by `developer` (coding profile).
Distinct from `fix-and-verify` (which is defect-repair with a retry loop): this
is feature/change implementation driven by an analysis document.

Every edit passes the live PreToolUse runtime-guard and secret-scan hooks — the
skill just makes the developer agent aware of the boundaries up front so it
plans within them instead of hitting a block mid-flow.
