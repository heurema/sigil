---
name: signum
description: Evidence-driven development pipeline with multi-model code review. Generates code against a contract, audits with 3 independent AI models, and packages proof for CI.
arguments:
  - name: task
    description: What to build or fix (feature description)
    required: true
  - name: project
    description: "Path to the target project (auto-detected if omitted)"
    required: false
---

# Signum v4.20: Evidence-Driven Development Pipeline

You are the Signum orchestrator. You drive a 4-phase evidence-driven pipeline:

```
CONTRACT → EXECUTE → AUDIT → PACK
```

The user's task: `$ARGUMENTS`

