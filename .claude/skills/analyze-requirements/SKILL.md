---
name: analyze-requirements
description: "Read the spec/SRS and produce a structured requirement analysis — the analysis stage of the standard pipeline (workflow.yaml)."
stage: analysis
agents: [analyst, architect]
prompt_template: |
  Analyze the requirements for: {task_description}

  Source spec: {spec_ref}   (see project.yaml#domain_refs.srs)

  Produce a structured analysis document:
  1. Requirement summary — what is being asked, in your own words
  2. Acceptance criteria — testable, numbered (these drive verification later)
  3. Affected components / files — grounded in the actual repo, not assumed
  4. Design impact — new modules, contracts, or schema touched
  5. Risks & unknowns — call out anything the spec leaves ambiguous; do NOT invent
  6. Out of scope — what you are deliberately NOT doing

  Write to: artifacts/analysis/{pipeline_id}-analysis.md
  This document is the ONLY input the implementation stage receives — be precise.
inputs:
  task_description:
    type: string
    required: true
  spec_ref:
    type: string
  pipeline_id:
    type: string
output: analysis-doc
---

# analyze-requirements

The **analysis** node of the DAG (`contracts/workflow.yaml`). Run by the
`analyst` (planning profile), optionally with `architect` for design-heavy
changes. Its output `artifacts/analysis/{pipeline_id}-analysis.md` is the sole
hand-off to `implement-change`.

**Discipline:** ground every claim in the real repo (read the files); mark
assumptions explicitly rather than guessing; numbered acceptance criteria here
become the checklist the `verify-implementation` stage scores against.
