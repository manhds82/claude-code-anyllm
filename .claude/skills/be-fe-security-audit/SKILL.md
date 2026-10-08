---
name: be-fe-security-audit
description: "Backend/Frontend security audit — scans code for OWASP Top 10, dependency vulns, misconfigurations"
stage: security
agents: [reviewer, researcher]
prompt_template: |
  Perform a security audit on the following code/diff.
  Focus on: {focus_areas}
  Risk level: {risk_level}
  
  1. Check for OWASP Top 10 vulnerabilities
  2. Scan for hardcoded secrets (API keys, passwords, tokens)
  3. Identify injection points (SQL, command, XSS)
  4. Review authentication/authorization logic
  5. Check dependency versions against known CVEs
  
  Output findings as structured report with severity, file:line, and remediation.
inputs:
  focus_areas:
    type: string
    default: "all"
  risk_level:
    type: string
    enum: [low, medium, high, critical]
    default: medium
output: security-audit-report
---
