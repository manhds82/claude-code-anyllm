---
name: commit-deploy-log
description: "Commit changes, deploy to target, and log the full cycle in the evidence ledger"
stage: release
agents: [developer, devops, writer]
prompt_template: |
  Complete the commit-deploy-log cycle:
  
  1. COMMIT: Stage and commit changes with conventional commit message
  2. DEPLOY: Deploy to {target_environment}
  3. LOG: Record full cycle in evidence ledger
     - Input hash (commit SHA)
     - Output hash (deployment ID)
     - Decision (success/fail)
     - Actor identity
     - Timestamp
  
  Target: {target_environment}
  Changes: {change_summary}
inputs:
  target_environment:
    type: string
    enum: [test, staging]
    default: test
  change_summary:
    type: string
output: cycle-report
---
