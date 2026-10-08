---
name: fix-and-verify
description: "Fix a defect then verify the fix with tests — iterative repair cycle with max retries"
stage: implement
agents: [developer, tester]
prompt_template: |
  Fix the following issue: {issue_description}
  
  Files affected: {files}
  
  1. Diagnose root cause
  2. Implement fix
  3. Write/update tests to prevent regression
  4. Run tests to verify fix
  5. Report: root cause, fix summary, test results
  
  Retry limit: {max_retries} attempts. If fix still fails after limit, escalate to architect.
inputs:
  issue_description:
    type: string
    required: true
  files:
    type: string
  max_retries:
    type: integer
    default: 3
    minimum: 1
    maximum: 5
output: fix-verification-report
---
