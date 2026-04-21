import { lstat, readFile, rm, writeFile } from "node:fs/promises"
import { resolve } from "node:path"

export type SignumRunState =
  | { kind: "none" }
  | { kind: "contract-only" }
  | { kind: "resumable" }

export interface ClearWorkingSetResult {
  removedPaths: string[]
  clearedActiveContract: boolean
}

const FINALIZED_STATUSES = new Set(["completed", "archived", "closed"])

const WORKING_SET_FILES = [
  ".signum/contract.json",
  ".signum/execute_log.json",
  ".signum/combined.patch",
  ".signum/iteration_delta.patch",
  ".signum/baseline.json",
  ".signum/mechanic_report.json",
  ".signum/audit_summary.json",
  ".signum/proofpack.json",
  ".signum/holdout_report.json",
  ".signum/contract-engineer.json",
  ".signum/contract-policy.json",
  ".signum/policy_violations.json",
  ".signum/policy_scan.json",
  ".signum/spec_quality.json",
  ".signum/spec_validation.json",
  ".signum/contract_validation.json",
  ".signum/repo_contract_baseline.json",
  ".signum/repo_contract_violations.json",
  ".signum/contract-hash.txt",
  ".signum/execution_context.json",
  ".signum/review_prompt_codex.txt",
  ".signum/review_prompt_gemini.txt",
  ".signum/review_context.json",
  ".signum/clover_report.json",
  ".signum/approval.json",
  ".signum/intent_check.json",
  ".signum/audit_iteration_log.json",
  ".signum/repair_brief.json",
  ".signum/flaky_tests.json",
  ".signum/reviews/claude.json",
  ".signum/reviews/codex.json",
  ".signum/reviews/gemini.json",
  ".signum/reviews/codex_raw.txt",
  ".signum/reviews/gemini_raw.txt",
  ".signum/anti_entropy_report.json",
]

const WORKING_SET_DIRS = [
  ".signum/reviews",
  ".signum/iterations",
  ".signum/receipts",
  ".signum/runs",
  ".signum/snapshots",
]

export async function detectRunState(projectRoot: string): Promise<SignumRunState> {
  const contract = await readJsonIfExists(resolve(projectRoot, ".signum/contract.json"))
  if (!contract) {
    return { kind: "none" }
  }

  const status = typeof contract.status === "string" ? contract.status.toLowerCase() : undefined
  if (status && FINALIZED_STATUSES.has(status)) {
    return { kind: "none" }
  }

  const hasProofpack = await pathExists(resolve(projectRoot, ".signum/proofpack.json"))
  const hasAuditSummary = await pathExists(resolve(projectRoot, ".signum/audit_summary.json"))
  if (hasProofpack || hasAuditSummary) {
    return { kind: "none" }
  }

  const hasExecutionContext = await pathExists(resolve(projectRoot, ".signum/execution_context.json"))
  if (hasExecutionContext) {
    return { kind: "resumable" }
  }

  return { kind: "contract-only" }
}

export async function clearWorkingSet(projectRoot: string): Promise<ClearWorkingSetResult> {
  const removedPaths: string[] = []

  for (const relativePath of [...WORKING_SET_FILES, ...WORKING_SET_DIRS]) {
    const absolutePath = resolve(projectRoot, relativePath)
    if (await pathExists(absolutePath)) {
      await rm(absolutePath, { force: true, recursive: true })
      removedPaths.push(relativePath)
    }
  }

  let clearedActiveContract = false
  const indexPath = resolve(projectRoot, ".signum/contracts/index.json")
  const index = await readJsonIfExists(indexPath)
  if (index && typeof index === "object" && !Array.isArray(index)) {
    const nextIndex = {
      ...(index as Record<string, unknown>),
      activeContractId: null,
    }
    await writeFile(indexPath, `${JSON.stringify(nextIndex, null, 2)}\n`, "utf8")
    clearedActiveContract = true
  }

  return {
    removedPaths,
    clearedActiveContract,
  }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await lstat(path)
    return true
  } catch {
    return false
  }
}

async function readJsonIfExists(path: string): Promise<any | null> {
  try {
    const content = await readFile(path, "utf8")
    return JSON.parse(content)
  } catch {
    return null
  }
}
