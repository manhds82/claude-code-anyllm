---
name: fan
description: "Fan-out parallel execution — decomposes work into independent subtasks and runs them concurrently"
stage: planning
agents: [boss]
prompt_template: |
  Fan-out the following work into parallel subtasks:
  
  Work item: {work_description}
  
  1. Decompose into independent subtasks
  2. Assign each subtask to appropriate specialist agent
  3. Launch all subtasks concurrently
  4. Collect results and merge
  5. Report: subtask results, merge conflicts (if any), completion status
  
  Parallel limit: {parallel_limit}
inputs:
  work_description:
    type: string
    required: true
  parallel_limit:
    type: integer
    default: 4
    minimum: 1
    maximum: 8
output: fan-out-report
---
