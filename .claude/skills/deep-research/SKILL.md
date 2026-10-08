---
name: deep-research
description: "Multi-source deep research — searches codebase, web, and package registries for comprehensive answers"
stage: requirement
agents: [researcher, analyst]
prompt_template: |
  Conduct deep research on: {research_question}
  
  Search sources:
  - Codebase: {codebase_paths}
  - Web: {web_search_terms}
  - Package registries: {registry_queries}
  
  Methodology:
  1. Search all sources in parallel
  2. Cross-reference findings
  3. Identify patterns, risks, and gaps
  4. Produce structured report with:
     - Executive summary
     - Findings (with confidence levels)
     - Sources cited
     - Recommendations
  
  Confidence levels: confirmed, likely, speculative
inputs:
  research_question:
    type: string
    required: true
  codebase_paths:
    type: string
  web_search_terms:
    type: string
  registry_queries:
    type: string
output: research-report
---
