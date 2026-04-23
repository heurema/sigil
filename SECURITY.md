# Security policy

Thanks for helping keep Signum and its users safe.

This file is the public reporting policy.
For Signum's internal trust-boundary notes and sensitive surfaces, see `docs/SECURITY.md`.

## Supported versions

Until Signum starts publishing an explicit support matrix, the **latest `main`**
branch state and the **latest tagged release** are the primary supported lines
for security fixes.

Older releases may not receive patches.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for suspected security problems.

Instead:

1. Use the private contact route listed on [skill7.dev](https://skill7.dev).
2. Include the affected path, reproduction steps, impact, and any proposed fix.
3. Share only the minimum reproduction needed to validate the issue.

If you cannot reach maintainers privately, open a minimal public issue that asks
for a private handoff **without** including exploit details, secrets, or proof
of concept.

## What to expect

We will make a good-faith effort to:

- acknowledge receipt within a reasonable time;
- assess severity and affected versions;
- coordinate remediation and disclosure timing where appropriate.

## Scope reminders

Security-sensitive areas include:
- execution policy enforcement;
- verify DSL execution surfaces;
- contract / prompt injection defenses;
- schema trust boundaries;
- any change that widens what external providers receive.

## Out of scope

This policy is not a bug bounty program and does not create any right to
compensation.
