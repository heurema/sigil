## Error Handling

- If any phase fails catastrophically (agent error, required file missing after agent run), **STOP** immediately and report: what phase failed, what file is missing, and what the user should do next.
- Mechanic check failures continue to audit — they influence the decision but do not block Phase 3.
- If codex or gemini times out (`exit 124`) or returns a non-zero exit code, mark as unavailable and continue.
- **Never silently swallow errors.** All bash exit codes must be checked. If jq fails to parse a file, report it explicitly.
- If the synthesizer produces an invalid audit_summary.json, stop Phase 4 and report the problem.
