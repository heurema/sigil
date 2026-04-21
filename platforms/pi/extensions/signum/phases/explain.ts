import { readFile } from "node:fs/promises"

import { packageJsonPath } from "../paths.ts"

export async function runExplainPhase(): Promise<string> {
  const version = await readVersion()

  const payload = {
    name: "Signum",
    version,
    platform: "pi",
    status: "slice-5",
    pipeline: ["CONTRACT", "EXECUTE", "AUDIT", "PACK"],
    commands: {
      explain: { implemented: true },
      init: { implemented: true },
      archive: { implemented: true },
      close: { implemented: true },
      task: {
        implemented: true,
        status: "full-pipeline-single-pass-audit",
        note: "Default /signum <task> runs CONTRACT, EXECUTE, AUDIT, and PACK. AUDIT is single-pass in the pi runtime; iterative audit parity is still deferred.",
      },
    },
    phases: {
      CONTRACT: {
        status: "implemented",
        note: "TypeScript CONTRACT orchestration, deterministic checks, contract summary, and approval flow are available in the pi runtime.",
      },
      EXECUTE: {
        status: "implemented",
        note: "Engineer execution runs via SDK session with runtime policy-wrapped read/edit/write/bash tools and writes execute artifacts.",
      },
      AUDIT: {
        status: "implemented-single-pass",
        note: "Mechanic, policy scan, holdout validation, reviewer sessions, deterministic synthesis, and audit summary artifacts are available. Iterative audit remains deferred.",
      },
      PACK: {
        status: "implemented",
        note: "Proofpack assembly, anti-entropy artifact generation, and per-contract sync are available in the pi runtime.",
      },
    },
    implementedArtifacts: [
      "project.intent.md",
      "project.glossary.json",
      "AGENTS.md",
      "ARCHITECTURE.md",
      "docs/PLANS.md",
      "docs/RELIABILITY.md",
      "docs/SECURITY.md",
      "docs/QUALITY_SCORE.md",
      ".signum/contract.json",
      ".signum/spec_quality.json",
      ".signum/approval.json",
      ".signum/contract-hash.txt",
      ".signum/contract-engineer.json",
      ".signum/contract-policy.json",
      ".signum/execution_context.json",
      ".signum/baseline.json",
      ".signum/combined.patch",
      ".signum/execute_log.json",
      ".signum/policy_violations.json",
      ".signum/receipts/execute.json",
      ".signum/review_context.json",
      ".signum/mechanic_report.json",
      ".signum/policy_scan.json",
      ".signum/holdout_report.json",
      ".signum/reviews/*.json",
      ".signum/audit_summary.json",
      ".signum/proofpack.json",
      ".signum/anti_entropy_report.json",
      ".signum/contracts/index.json",
      ".signum/archive/<contractId>/",
    ],
  }

  return JSON.stringify(payload, null, 2)
}

async function readVersion(): Promise<string> {
  try {
    const raw = await readFile(packageJsonPath, "utf8")
    const parsed = JSON.parse(raw) as { version?: string }
    return parsed.version ?? "4.19.0"
  } catch {
    return "4.19.0"
  }
}
