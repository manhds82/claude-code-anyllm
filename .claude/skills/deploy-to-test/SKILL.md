---
name: deploy-to-test
description: "Deploy current build to test/staging environment with approval gate"
stage: release
agents: [devops]
prompt_template: |
  Deploy to {environment} environment.
  
  Build: {build_ref}
  Approval required: {approval_required}
  
  1. Run pre-deployment checks (health, config, migrations)
  2. Execute deployment per {deployment_script}
  3. Run smoke tests post-deployment
  4. Report deployment status
  
  Guardrails:
  - NEVER deploy to production without human approval
  - All deployment steps recorded in evidence ledger
  - Rollback plan must exist before starting
inputs:
  environment:
    type: string
    enum: [test, staging, production]
    required: true
  build_ref:
    type: string
    default: HEAD
  approval_required:
    type: boolean
    default: true
  deployment_script:
    type: string
output: deployment-report
---
