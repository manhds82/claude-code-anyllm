# Golden Dataset — H3 Evaluation

This directory contains golden test cases for evaluating agent output quality.
Each subdirectory corresponds to a test domain.

## The `golden` regression suite (`*.jsonl`)

`harness_golden.py` reads the directory declared in
`.harness/control/casan-policies.yaml` → `evaluation.golden_dataset_path`
(config, not a hardcoded path — C2) and evaluates **every `*.jsonl` in it**,
sorted, against the project's real `risk-policy.yaml` deny patterns.

**Put your project's own cases in your own file** — e.g.
`my-project-cases.jsonl` beside the shipped `golden-cases.jsonl`. Both are
picked up, and a file the bundle does not ship can never be touched by an
update. (`golden-cases.jsonl` and `risk-policy.yaml` are additionally listed in
the bundle's `preserve` set, so even edits to the shipped baseline survive
`--force`; you get a `.new` copy when the shipped version moves on.)

One case per line:
```jsonc
{"id":"g-deny-drop-table","input":"...","expect":"deny","layer":"H4","why":"..."}
```
`expect` is `deny` when a deny pattern should match the `input`, else `allow`.

## Structure

```
golden/
├── README.md
├── runtime-guard/        # Test cases for runtime guard effectiveness
│   ├── TC-RG-001.yaml    # rm -rf detection
│   └── ...
├── secret-scan/          # Test cases for secret scanner
│   ├── TC-SS-001.yaml    # API key detection
│   └── ...
├── injection-scan/       # Test cases for injection scanner
│   ├── TC-IS-001.yaml    # "ignore previous instructions" detection
│   └── ...
└── workflow/             # Test cases for 3-step pipeline output quality
    ├── TC-WF-001.yaml    # Analysis phase output
    └── ...
```

## Adding a Test Case

Each test case YAML has:
```yaml
id: "TC-XXX-NNN"
domain: "runtime-guard|secret-scan|injection-scan|workflow"
description: "What this test verifies"
input: { ... }           # The input to the agent/tool
expected_output: { ... } # The expected correct output
acceptance_criteria:     # List of specific checks
  - "..."
tags: ["regression", "security", ...]
```
