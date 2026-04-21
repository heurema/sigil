import { copyFile, lstat, mkdir, readFile, rm } from "node:fs/promises"
import { resolve } from "node:path"

import {
  archiveDirPath,
  contractDirPath,
  readContractIndex,
  resolveContractId,
  setContractTimestampField,
  updateContractStatus,
  writeContractIndex,
} from "../runtime/script-adapters/contract-dir.ts"

const ARCHIVE_KEEP_FILES = ["contract.json", "proofpack.json", "approval.json", "audit_summary.json"]
const ARCHIVE_PURGE_FILES = [
  "baseline.json",
  "execute_log.json",
  "holdout_report.json",
  "mechanic_report.json",
  "combined.patch",
  "iteration_delta.patch",
  "contract-engineer.json",
  "contract-policy.json",
  "policy_violations.json",
  "spec_quality.json",
  "spec_validation.json",
  "clover_report.json",
  "contract-hash.txt",
  "execution_context.json",
  "review_prompt_codex.txt",
  "review_prompt_gemini.txt",
  "intent_check.json",
  "audit_iteration_log.json",
  "repair_brief.json",
  "flaky_tests.json",
  "policy_scan.json",
]
const ARCHIVE_PURGE_DIRS = ["reviews", "iterations", "receipts", "runs", "snapshots"]

export async function runArchivePhase(projectRoot: string, requestedContractId?: string): Promise<string> {
  const index = await readContractIndex(projectRoot)
  const contractId = resolveContractId(index, requestedContractId)
  const contractPath = contractDirPath(projectRoot, contractId)
  const archivePath = archiveDirPath(projectRoot, contractId)

  try {
    const stat = await lstat(contractPath)
    if (!stat.isDirectory()) {
      throw new Error()
    }
  } catch {
    throw new Error(`Contract directory not found: .signum/contracts/${contractId}/`)
  }

  await mkdir(archivePath, { recursive: true })

  for (const file of ARCHIVE_KEEP_FILES) {
    await copyIfExists(resolve(contractPath, file), resolve(archivePath, file))
  }
  await copyIfExists(resolve(contractPath, "receipts", "execute.json"), resolve(archivePath, "execute.json"))

  for (const directory of ARCHIVE_PURGE_DIRS) {
    await rm(resolve(contractPath, directory), { force: true, recursive: true })
  }
  for (const file of ARCHIVE_PURGE_FILES) {
    await rm(resolve(contractPath, file), { force: true, recursive: false })
  }

  const archivedAt = toUtcTimestamp()
  const nextIndex = setContractTimestampField(
    updateContractStatus(index, contractId, "archived"),
    contractId,
    "archivedAt",
    archivedAt,
  )
  await writeContractIndex(projectRoot, nextIndex)

  return [
    `Archived: ${contractId} → .signum/archive/${contractId}/`,
    "Kept: contract.json, proofpack.json, approval.json, audit_summary.json, execute.json",
    "Purged: intermediates (reviews, baseline, patches, prompts)",
  ].join("\n")
}

function toUtcTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z")
}

async function copyIfExists(source: string, destination: string) {
  try {
    await readFile(source)
    await copyFile(source, destination)
  } catch {
    // ignore missing optional artifacts
  }
}
