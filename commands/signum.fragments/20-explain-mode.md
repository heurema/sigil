## Explain Mode

If the user's task is exactly `explain` (case-insensitive), do NOT run the pipeline. Instead, output this JSON and stop:

```json
{
  "name": "Signum",
  "version": "4.21.2",
  "pipeline": ["CONTRACT", "EXECUTE", "AUDIT", "PACK"],
  "phases": {
    "CONTRACT": {
      "description": "Transform request into verifiable JSON contract",
      "steps": ["contractor agent", "spec quality gate (7 dimensions)", "prose checks", "intent alignment check", "multi-model spec validation", "clover reconstruction test", "human approval"],
      "duration": "~30s",
      "approvals": 1
    },
    "EXECUTE": {
      "description": "Implement code against contract with repair loop",
      "steps": ["baseline capture", "pre-execute snapshot", "engineer agent (max 3 attempts)", "scope gate", "policy compliance", "scope existence gate", "boundary verification", "transition verification"],
      "duration": "1-5 min",
      "approvals": 0
    },
    "AUDIT": {
      "description": "Multi-angle verification with regression detection",
      "iterativeAudit": "review-fix loop with best-of-N selection",
      "steps": ["mechanic (lint/typecheck/tests vs baseline)", "policy scanner (zero LLM, security/unsafe/dependency patterns)", "holdout validation", "Claude semantic review", "Codex security review", "Gemini performance review", "synthesizer consensus", "iterative review-fix loop (up to 20 iterations)"],
      "duration": "1-3 min (risk-proportional)",
      "approvals": 0
    },
    "PACK": {
      "description": "Bundle all artifacts into signed proofpack",
      "steps": ["collect metadata", "embed artifacts with SHA-256 envelopes", "write proofpack.json", "emit advisory anti-entropy report"],
      "duration": "~5s",
      "approvals": 0
    }
  },
  "decisions": ["AUTO_OK", "AUTO_BLOCK", "HUMAN_REVIEW"],
  "riskLevels": {
    "low": {"reviews": "Claude only", "holdouts": 0, "cost": "<$0.20", "duration": "<2 min"},
    "medium": {"reviews": "Claude + externals", "holdouts": "≥2", "cost": "~$0.50", "duration": "3-5 min"},
    "high": {"reviews": "Full 3-model panel", "holdouts": "≥5", "cost": "~$1.00", "duration": "5-10 min"}
  },
  "artifactRoot": ".signum/contracts/<contractId>/",
  "compatibilityRoot": ".signum/",
  "artifacts": ["contract.json", "combined.patch", "proofpack.json", "audit_summary.json", "anti_entropy_report.json"]
}
```

Do not proceed to Setup or any phase.
