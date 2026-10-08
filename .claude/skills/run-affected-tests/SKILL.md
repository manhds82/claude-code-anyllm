---
name: run-affected-tests
description: "Run only the tests a diff actually affects (per contracts/impact-map.yaml) plus always-run smoke, escalate to the full suite on hub changes, and write an honest report. The test stage (H3/H7)."
stage: test
agents: [targeted-tester, tester]
prompt_template: |
  Run the tests affected by the change for pipeline {pipeline_id}.

  1. git diff --name-only {base}..{head} → the changed files.
  2. Read contracts/impact-map.yaml (schema: .harness/schemas/impact-map.schema.json)
     and .harness/control/agent-config.yaml. Match changed files against the map's
     source globs → the union of affected test groups.
  3. Decide the tier:
     - Any changed file matches NO group, OR touches a hub (migration, config,
       lockfile, router, middleware, a re-exporting index/__init__) → FULL suite
       (agent-config.full_suite_cmd).
     - Otherwise → SCOPED: the affected groups' tests + always_run smoke
       (agent-config.unit_related_cmd for the changed files).
  4. Run it. Write artifacts/test/{pipeline_id}-test-report.md with:
     - PASS/FAIL/SKIP counted from THIS run — never copy a prior report, never
       infer green because nothing looked broken. Nothing ran → say nothing ran.
     - Which tier ran, and if scoped, WHICH groups were skipped and why
       (not in the diff's impact set). A report that tested a subset but reads as
       full is how a regression slips through.
     - On any FAIL, the last ~20 lines of that test's output.
  5. Any FAIL → verdict FAILED.

  Escalating to full is never wrong, only slower; skipping a suite that should
  have run is wrong. When unsure, run more.
inputs:
  pipeline_id:
    type: string
    required: true
  base:
    type: string
  head:
    type: string
output: test-report
---

# run-affected-tests

The **test** node of the DAG — until v1.6.0 the one stage with no dedicated skill
(the `tester` agent ran suites ad hoc, and CodeProvider's proposal flagged the
gap). It exists so "only test the affected area" is a *repeatable, honest*
procedure rather than a judgement call made fresh each change.

Pairs `targeted-tester` (runs the scoped/full decision) with `tester` (writes
suites when the affected area has none). The selection is driven by
`contracts/impact-map.yaml` + `.harness/control/agent-config.yaml`, both
project-owned — the skill ships in the bundle, the mapping and the runner command
belong to the project (C2, the two-layer Agent Pack split).

**Safety over speed, always.** A file outside every map group, or a hub change,
forces the full suite. The report names skipped groups out loud; a silent subset
that reads as full coverage is the exact failure this stage is meant to prevent.
