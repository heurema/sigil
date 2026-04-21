import { existsSync } from "node:fs"
import { copyFile, cp, mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises"
import { createHash, randomBytes } from "node:crypto"
import { dirname, resolve } from "node:path"

import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import { packAntiEntropyScriptPath, proofpackIndexScriptPath } from "../paths.ts"
import { buildIterativeAuditProofpackSummary, type AuditIterationLog } from "../runtime/audit-iterations.ts"
import {
  contractDirPath,
  ensureContractIndex,
  updateContractStatus,
  writeContractIndex,
} from "../runtime/script-adapters/contract-dir.ts"
import { toUtcTimestamp } from "../runtime/script-adapters/checks.ts"
import { pushSignumProgressEvent, setSignumProgress, setSignumStatus, withSignumHeartbeat } from "../ui.ts"

interface ContractDocument {
  contractId: string
  goal: string
  riskLevel: string
  timestamps?: Record<string, string>
  holdoutScenarios?: unknown[]
  acceptanceCriteria?: unknown[]
  removals?: Array<{ id?: string; path?: string; type?: string; modulesYamlTransition?: string }>
  cleanupObligations?: Array<{ id?: string; action?: string; blocking?: boolean }>
}

interface AuditSummary {
  decision: "AUTO_OK" | "AUTO_BLOCK" | "HUMAN_REVIEW"
  mechanic?: string
  confidence?: { overall?: number }
  availableReviews?: number
  releaseVerdict?: string
  iterationsUsed?: number
  iterationsMax?: number
  bestIteration?: number
  terminalReason?: string
  earlyStop?: boolean
  earlyStopReason?: string
  remainingSeverity?: string
}

interface ExecuteLog {
  totalAttempts?: number
  started_at?: string
  finished_at?: string
}

export interface PackPhaseResult {
  status: "ok" | "failed"
  decision?: "AUTO_OK" | "AUTO_BLOCK" | "HUMAN_REVIEW"
  summary: string
}

export async function runPackPhase(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
): Promise<PackPhaseResult> {
  const projectRoot = ctx.cwd
  setSignumStatus(ctx, "pack assemble")
  setSignumProgress(ctx, "pack", "assemble", "Building proofpack artifacts")

  const contractPath = resolve(projectRoot, ".signum/contract.json")
  const auditPath = resolve(projectRoot, ".signum/audit_summary.json")
  const executeLogPath = resolve(projectRoot, ".signum/execute_log.json")
  const contract = await readJson<ContractDocument>(contractPath)
  const audit = await readJson<AuditSummary>(auditPath)
  const executeLog = await readJson<ExecuteLog>(executeLogPath)

  const completedAt = toUtcTimestamp()
  const updatedContract = {
    ...contract,
    status: "completed",
    timestamps: {
      ...(contract.timestamps ?? {}),
      completedAt,
    },
  }
  await writeJson(contractPath, updatedContract)

  const runId = `signum-${completedAt.slice(0, 10)}-${randomBytes(3).toString("hex")}`
  const proofpack = await withSignumHeartbeat(ctx, "pack", "assemble", () =>
    buildProofpack(projectRoot, updatedContract, audit, executeLog, runId, completedAt),
  )
  await writeJson(resolve(projectRoot, ".signum/proofpack.json"), proofpack)
  pushSignumProgressEvent(ctx, "Proofpack assembled")

  setSignumStatus(ctx, "pack anti-entropy")
  setSignumProgress(ctx, "pack", "anti-entropy", "Running anti-entropy checks")
  await withSignumHeartbeat(ctx, "pack", "anti-entropy", () => runPackAntiEntropy(pi, projectRoot))

  setSignumStatus(ctx, "pack index")
  setSignumProgress(ctx, "pack", "index", "Updating proofpack index")
  await withSignumHeartbeat(ctx, "pack", "index", () => appendProofpackIndex(pi, projectRoot))

  setSignumStatus(ctx, "pack sync")
  setSignumProgress(ctx, "pack", "sync", "Syncing contract artifacts")
  await withSignumHeartbeat(ctx, "pack", "sync", async () => {
    await syncContractArtifacts(projectRoot, updatedContract.contractId)
    await markContractCompleted(projectRoot, updatedContract.contractId)
  })

  return {
    status: "ok",
    decision: audit.decision,
    summary: [
      `PACK complete: ${audit.decision}`,
      `Proofpack: .signum/proofpack.json`,
      `Run ID: ${runId}`,
      `Anti-entropy: .signum/anti_entropy_report.json`,
    ].join("\n"),
  }
}

async function buildProofpack(
  projectRoot: string,
  contract: ContractDocument,
  audit: AuditSummary,
  executeLog: ExecuteLog,
  runId: string,
  createdAt: string,
) {
  const contractPath = resolve(projectRoot, ".signum/contract.json")
  const redactedContract = JSON.parse(JSON.stringify(contract)) as Record<string, unknown>
  delete redactedContract.holdoutScenarios

  const contractEnvelope = await buildContractEnvelope(contractPath, redactedContract)
  const diffEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/combined.patch"), false)
  const baselineEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/baseline.json"), true)
  const executeEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/execute_log.json"), true)
  const approvalEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/approval.json"), true)
  const mechanicEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/mechanic_report.json"), true)
  const holdoutEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/holdout_report.json"), true)
  const policyScanEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/policy_scan.json"), true)
  const auditEnvelope = await buildEnvelope(resolve(projectRoot, ".signum/audit_summary.json"), true)
  const reviewsEnvelope = await buildReviewsEnvelope(resolve(projectRoot, ".signum/reviews"))
  const auditIterationLog = await readOptionalJson<AuditIterationLog>(resolve(projectRoot, ".signum/audit_iteration_log.json"))

  const contractHashText = await readOptionalText(resolve(projectRoot, ".signum/contract-hash.txt"))
  const contractHash = extractTaggedValue(contractHashText, "contract_sha256")
  const approvedAt = extractTaggedValue(contractHashText, "approved_at")
  const executionContext = await readOptionalJson<Record<string, unknown>>(resolve(projectRoot, ".signum/execution_context.json"))
  const baseCommit = typeof executionContext?.base_commit === "string" ? executionContext.base_commit : "unavailable"
  const previousProofpack = await findPreviousProofpack(projectRoot, contract.contractId)
  const baselineComparison = previousProofpack
    ? {
        previousRunId: previousProofpack.runId,
        previousDecision: previousProofpack.decision,
        previousConfidence: previousProofpack.confidence,
        confidenceDelta: Math.round(((audit.confidence?.overall ?? 0) - previousProofpack.confidence) * 10) / 10,
      }
    : undefined

  const proofpack: Record<string, unknown> = {
    schemaVersion: "4.8",
    signumVersion: "4.19.0",
    createdAt,
    runId,
    contractId: contract.contractId,
    decision: audit.decision,
    releaseVerdict: audit.releaseVerdict ?? (audit.decision === "AUTO_OK" ? "PROMOTE" : "HOLD"),
    riskLevel: contract.riskLevel,
    summary: `Goal: ${contract.goal} | Risk: ${contract.riskLevel} | Attempts: ${executeLog.totalAttempts ?? 1} | Mechanic: ${audit.mechanic ?? "unknown"} | Confidence: ${audit.confidence?.overall ?? 0}% | Decision: ${audit.decision}`,
    confidence: { overall: audit.confidence?.overall ?? 0 },
    timing: {
      startedAt: executeLog.started_at ?? createdAt,
      completedAt: executeLog.finished_at ?? createdAt,
      durationMs: computeDurationMs(executeLog.started_at, executeLog.finished_at),
    },
    reviewCoverage: { availableReviews: audit.availableReviews ?? 0 },
    contractSource: "interactive",
    auditChain: {
      contractSha256: contractHash || null,
      approvedAt: approvedAt || null,
      baseCommit,
    },
    contract: contractEnvelope,
    diff: diffEnvelope,
    baseline: baselineEnvelope,
    executeLog: executeEnvelope,
    approval: approvalEnvelope,
    checks: {
      mechanic: mechanicEnvelope,
      holdout: holdoutEnvelope,
      policy_scan: policyScanEnvelope,
      reviews: reviewsEnvelope,
      auditSummary: auditEnvelope,
    },
  }

  if (baselineComparison) {
    proofpack.baselineComparison = baselineComparison
  }

  const removalEvidence = buildRemovalEvidence(contract, projectRoot)
  if (removalEvidence) {
    proofpack.removalEvidence = removalEvidence
  }

  if ((audit.iterationsUsed ?? 1) > 1 && auditIterationLog) {
    proofpack.iterativeAudit = buildIterativeAuditProofpackSummary(auditIterationLog)
  }

  void resolve(projectRoot, ".signum/audit_iteration_log.json")

  return proofpack
}

async function buildReviewsEnvelope(reviewsDir: string) {
  const envelopes: Record<string, unknown> = {}
  try {
    const entries = await readdir(reviewsDir)
    for (const entry of entries) {
      if (!entry.endsWith(".json")) continue
      envelopes[entry.replace(/\.json$/, "")] = await buildEnvelope(resolve(reviewsDir, entry), true)
    }
  } catch {
    return {}
  }
  return envelopes
}

async function buildEnvelope(path: string, parseJson: boolean) {
  try {
    const raw = await readFile(path)
    const sha256 = createHash("sha256").update(raw).digest("hex")
    const sizeBytes = raw.byteLength
    if (sizeBytes > 102_400) {
      return {
        content: null,
        sha256,
        sizeBytes,
        status: "omitted",
        omitReason: "size exceeds 100 KiB",
      }
    }

    return {
      content: parseJson ? JSON.parse(raw.toString("utf8")) : raw.toString("utf8"),
      sha256,
      sizeBytes,
      status: "present",
    }
  } catch {
    return {
      content: null,
      sha256: null,
      sizeBytes: 0,
      status: "error",
      omitReason: "file not found",
    }
  }
}

async function buildContractEnvelope(contractPath: string, redactedContract: Record<string, unknown>) {
  const full = await readFile(contractPath)
  const fullSha256 = createHash("sha256").update(full).digest("hex")
  const redactedRaw = Buffer.from(`${JSON.stringify(redactedContract, null, 2)}\n`, "utf8")
  const sha256 = createHash("sha256").update(redactedRaw).digest("hex")
  const sizeBytes = redactedRaw.byteLength
  if (sizeBytes > 102_400) {
    return {
      content: null,
      sha256,
      fullSha256,
      sizeBytes,
      status: "omitted",
      omitReason: "size exceeds 100 KiB",
    }
  }
  return {
    content: redactedContract,
    sha256,
    fullSha256,
    sizeBytes,
    status: "present",
  }
}

function buildRemovalEvidence(contract: ContractDocument, projectRoot: string) {
  const removals = (contract.removals ?? []).map((item) => ({
    id: item.id ?? "",
    path: item.path ?? "",
    type: item.type ?? "file",
    removed: item.path ? !existsSync(resolve(projectRoot, item.path)) : false,
    orphanReferences: 0,
    modulesYamlUpdated: item.modulesYamlTransition ? item.modulesYamlTransition !== "none" : false,
  }))
  const obligations = (contract.cleanupObligations ?? []).map((item) => ({
    id: item.id ?? "",
    action: item.action ?? "",
    fulfilled: true,
    blocking: item.blocking ?? true,
  }))

  if (removals.length === 0 && obligations.length === 0) {
    return undefined
  }

  return { removals, obligations }
}

async function runPackAntiEntropy(pi: ExtensionAPI, projectRoot: string) {
  await pi.exec(
    "bash",
    [packAntiEntropyScriptPath, "--project-root", ".", "--contract", ".signum/contract.json", "--proofpack", ".signum/proofpack.json", "--output", ".signum/anti_entropy_report.json"],
    { cwd: projectRoot, timeout: 120_000 },
  )
}

async function appendProofpackIndex(pi: ExtensionAPI, projectRoot: string) {
  const command = `source ${shellQuote(proofpackIndexScriptPath)} && proofpack_index_append .signum/proofpack.json`
  await pi.exec("bash", ["-lc", command], { cwd: projectRoot, timeout: 30_000 })
}

async function syncContractArtifacts(projectRoot: string, contractId: string) {
  const contractDir = contractDirPath(projectRoot, contractId)
  await mkdir(contractDir, { recursive: true })
  await mkdir(resolve(contractDir, "receipts"), { recursive: true })

  for (const relativePath of [
    ".signum/contract.json",
    ".signum/audit_summary.json",
    ".signum/audit_iteration_log.json",
    ".signum/repair_brief.json",
    ".signum/proofpack.json",
    ".signum/anti_entropy_report.json",
    ".signum/approval.json",
  ]) {
    const source = resolve(projectRoot, relativePath)
    if (await exists(source)) {
      const destination = resolve(contractDir, relativePath.replace(/^\.signum\//, ""))
      await mkdir(dirname(destination), { recursive: true })
      await copyFile(source, destination)
    }
  }

  const executeReceipt = resolve(projectRoot, ".signum/receipts/execute.json")
  if (await exists(executeReceipt)) {
    await copyFile(executeReceipt, resolve(contractDir, "receipts/execute.json"))
  }

  const iterationsDir = resolve(projectRoot, ".signum/iterations")
  if (await exists(iterationsDir)) {
    await cp(iterationsDir, resolve(contractDir, "iterations"), { recursive: true })
  }
}

async function markContractCompleted(projectRoot: string, contractId: string) {
  const index = updateContractStatus(await ensureContractIndex(projectRoot), contractId, "completed")
  await writeContractIndex(projectRoot, index)
}

async function findPreviousProofpack(projectRoot: string, currentContractId: string) {
  const contractsRoot = resolve(projectRoot, ".signum/contracts")
  try {
    const entries = await readdir(contractsRoot)
    const candidates: Array<{ path: string; mtimeMs: number }> = []
    for (const entry of entries) {
      if (entry === currentContractId) continue
      const proofpackPath = resolve(contractsRoot, entry, "proofpack.json")
      try {
        const proofpackStat = await stat(proofpackPath)
        candidates.push({ path: proofpackPath, mtimeMs: proofpackStat.mtimeMs })
      } catch {
        // ignore
      }
    }

    const latest = candidates.sort((left, right) => right.mtimeMs - left.mtimeMs)[0]
    if (!latest) return null
    const parsed = await readJson<Record<string, any>>(latest.path)
    return {
      runId: String(parsed.runId ?? ""),
      decision: String(parsed.decision ?? "HUMAN_REVIEW") as AuditSummary["decision"],
      confidence: Number(parsed.confidence?.overall ?? 0),
    }
  } catch {
    return null
  }
}

function computeDurationMs(startedAt?: string, finishedAt?: string) {
  const start = startedAt ? Date.parse(startedAt) : NaN
  const finish = finishedAt ? Date.parse(finishedAt) : NaN
  if (!Number.isFinite(start) || !Number.isFinite(finish)) return 0
  return Math.max(0, finish - start)
}

function extractTaggedValue(text: string | null, key: string): string {
  if (!text) return ""
  const match = text.match(new RegExp(`${key}:\\s*(\\S+)`))
  return match?.[1] ?? ""
}

async function readJson<T>(path: string): Promise<T> {
  return JSON.parse(await readFile(path, "utf8")) as T
}

async function readOptionalJson<T>(path: string): Promise<T | null> {
  try {
    return await readJson<T>(path)
  } catch {
    return null
  }
}

async function writeJson(path: string, value: unknown) {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8")
}

async function readOptionalText(path: string): Promise<string | null> {
  try {
    return await readFile(path, "utf8")
  } catch {
    return null
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`
}
