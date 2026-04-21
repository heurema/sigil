import { copyFile, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"

import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"
import type { Model } from "@mariozechner/pi-ai"

import { selectRoleModel } from "../models.ts"
import { buildCombinedPatch, runBoundaryVerification, runTransitionVerification } from "../phases/execute.ts"
import { setSignumStatus } from "../ui.ts"
import { createPolicyAwareEngineerTools, deriveExecutionPolicy, type ContractPolicy } from "./policy-tools.ts"
import { loadRolePromptAsset, SdkRoleSessionRunner } from "./role-session.ts"
import { toUtcTimestamp } from "./script-adapters/checks.ts"

export interface AuditIterationFinding {
  fingerprint: string
  category: string
  file: string
  severity: "CRITICAL" | "MAJOR" | "MINOR"
  comment: string
}

export interface AuditIterationLogEntry {
  pass: number
  decision: "AUTO_OK" | "AUTO_BLOCK" | "HUMAN_REVIEW"
  score: number
  findingsCount: { critical: number; major: number; minor: number }
  remainingSeverity: "CRITICAL" | "MAJOR" | "MINOR" | "none"
  consensus: string
  reasoning: string
  mechanicRegressions: boolean
  holdoutFailures: number
  canonicalFindings: AuditIterationFinding[]
}

export interface AuditIterationLog {
  iterationsMax: number
  iterationsUsed: number
  bestIteration: number
  earlyStop: boolean
  earlyStopReason: string
  terminalReason: string
  remainingSeverity: "CRITICAL" | "MAJOR" | "MINOR" | "none"
  auditIterations: AuditIterationLogEntry[]
}

export interface AuditRepairResult {
  status: "success" | "no_changes" | "blocked"
  summary: string
  changedFiles: string[]
}

interface RepairContractDocument {
  contractId: string
  riskLevel: "low" | "medium" | "high"
  goal: string
  inScope: string[]
  allowNewFilesUnder?: string[]
  acceptanceCriteria: Array<{ id: string; visibility?: string; description?: string; verify?: unknown }>
}

interface ExecuteLog {
  status?: string
  totalAttempts?: number
  maxAttempts?: number
  attempts?: unknown[]
  started_at?: string
  finished_at?: string
  auditRepairAttempts?: unknown[]
}

interface RepairBriefSummary {
  decision: "AUTO_OK" | "AUTO_BLOCK" | "HUMAN_REVIEW"
  remainingSeverity: "CRITICAL" | "MAJOR" | "MINOR" | "none"
  consensus: string
  reasoning: string
  canonicalFindings: AuditIterationFinding[]
}

const REDACTED_HOLDOUT_DETAIL = "[redacted holdout detail]"
const REDACTED_HOLDOUT_ARTIFACT = "[redacted holdout artifact]"
const HOLDOUT_ARTIFACT_PATTERN = /\.signum\/(?:holdout_report|contract)\.json/gi
const HOLDOUT_DETAIL_PATTERN = /\bholdoutScenarios\b/gi

export function computeAuditIterationScore(input: {
  findingsCount: { critical: number; major: number; minor: number }
  mechanicRegressions: boolean
  holdoutFailures: number
}): number {
  return -(
    input.findingsCount.critical * 1000 +
    (input.mechanicRegressions ? 500 : 0) +
    input.holdoutFailures * 200 +
    input.findingsCount.major * 50 +
    input.findingsCount.minor
  )
}

export function buildAuditIterationLog(
  auditIterations: AuditIterationLogEntry[],
  iterationsMax: number,
  terminalReason: string,
  earlyStopReason = "",
): AuditIterationLog {
  const bestIteration = auditIterations.reduce((best, entry) => {
    if (!best) return entry
    return entry.score > best.score ? entry : best
  }, auditIterations[0])

  return {
    iterationsMax,
    iterationsUsed: auditIterations.length,
    bestIteration: bestIteration?.pass ?? auditIterations.length,
    earlyStop: earlyStopReason.length > 0,
    earlyStopReason,
    terminalReason,
    remainingSeverity: auditIterations[auditIterations.length - 1]?.remainingSeverity ?? "none",
    auditIterations,
  }
}

export function buildIterativeAuditProofpackSummary(log: AuditIterationLog) {
  const finalIteration = log.auditIterations[log.auditIterations.length - 1]
  return {
    iterationsUsed: log.iterationsUsed,
    iterationsMax: log.iterationsMax,
    bestIteration: log.bestIteration,
    earlyStop: log.earlyStop,
    earlyStopReason: log.earlyStopReason,
    terminalReason: log.terminalReason,
    remainingSeverity: log.remainingSeverity,
    auditIterations: log.auditIterations.map((entry) => ({
      pass: entry.pass,
      score: entry.score,
      findingsCount: entry.findingsCount,
      mechanicRegressions: entry.mechanicRegressions,
      holdoutFailures: entry.holdoutFailures,
      decision: entry.decision,
    })),
    resolvedFindings: computeResolvedFindings(log.auditIterations),
    remainingFindings: (finalIteration?.canonicalFindings ?? []).map((finding) => ({
      fingerprint: finding.fingerprint,
      category: finding.category,
      file: finding.file,
      severity: finding.severity,
      comment: finding.comment,
    })),
  }
}

export function sanitizeRepairText(text: string): string {
  return text
    .replace(/\.signum\/contract\.json/gi, ".signum/contract-engineer.json")
    .replace(HOLDOUT_ARTIFACT_PATTERN, REDACTED_HOLDOUT_ARTIFACT)
    .replace(HOLDOUT_DETAIL_PATTERN, REDACTED_HOLDOUT_DETAIL)
    .replace(/\s+/g, " ")
    .trim()
}

export function buildRepairBrief(
  contract: RepairContractDocument,
  auditSummary: RepairBriefSummary,
  pass: number,
  iterationsMax: number,
) {
  const visibleAcceptanceCriteria = contract.acceptanceCriteria.filter((criterion) => (criterion.visibility ?? "visible") !== "holdout")

  return {
    contractSource: ".signum/contract-engineer.json",
    pass,
    iterationsMax,
    goal: contract.goal,
    remainingSeverity: auditSummary.remainingSeverity,
    decision: auditSummary.decision,
    consensus: auditSummary.consensus,
    reasoning: sanitizeRepairText(auditSummary.reasoning),
    visibleAcceptanceCriteria: visibleAcceptanceCriteria.map((criterion) => ({
      id: criterion.id,
      description: criterion.description ?? criterion.id,
    })),
    reviewFindings: auditSummary.canonicalFindings.map((finding) => ({
      fingerprint: finding.fingerprint,
      category: finding.category,
      file: finding.file,
      severity: finding.severity,
      comment: sanitizeRepairText(finding.comment),
    })),
    instructions: [
      "Use .signum/contract-engineer.json as the only contract source for this repair iteration.",
      "Do not read hidden holdout payloads or infer raw holdout scenario definitions from .signum artifacts.",
      "Address only the sanitized findings summarized here and keep repair work within contract scope.",
    ],
  }
}

export async function runAuditRepairIteration(input: {
  pi: ExtensionAPI
  ctx: ExtensionCommandContext
  runner: SdkRoleSessionRunner
  projectRoot: string
  contract: RepairContractDocument
  model: Model
  pass: number
  iterationsMax: number
}): Promise<AuditRepairResult> {
  const { pi, ctx, runner, projectRoot, contract, model, pass, iterationsMax } = input
  const executeLogPath = resolve(projectRoot, ".signum/execute_log.json")
  const startedAt = toUtcTimestamp()
  const policyPath = resolve(projectRoot, ".signum/contract-policy.json")
  const policy = (await readOptionalJson<ContractPolicy>(policyPath)) ?? deriveExecutionPolicy(contract as Record<string, unknown>)
  await writeJson(policyPath, policy)

  const policyTools = createPolicyAwareEngineerTools(projectRoot, policy)
  setSignumStatus(ctx, `audit repair ${pass}/${iterationsMax}`)

  const prompt = [
    "Read .signum/repair_brief.json, .signum/contract-engineer.json, .signum/baseline.json, and .signum/contract-policy.json.",
    `This is repair pass ${pass} of ${iterationsMax}.`,
    "Implement only the fixes required by the sanitized repair brief.",
    "Use edit/write for mutations. Use bash only for read-only inspection or checks.",
    "Do not modify .signum artifacts directly.",
    "Do not inspect hidden holdout payloads. Use only the sanitized engineer-facing repair brief.",
  ].join("\n")

  const run = await runner.run({
    role: "engineer",
    projectRoot,
    prompt,
    model,
    toolNames: [...policyTools.builtInToolNames, ...policyTools.customTools.map((tool) => tool.name)],
    customTools: policyTools.customTools,
  })

  const changedFiles = policyTools.getTouchedFiles()
  const violations = policyTools.getViolations()
  if (violations.length > 0) {
    await writeJson(resolve(projectRoot, ".signum/policy_violations.json"), { violations })
    await appendAuditRepairAttempt(executeLogPath, {
      iteration: pass,
      status: "POLICY_VIOLATION",
      startedAt,
      finishedAt: toUtcTimestamp(),
      model: `${run.model}`,
      finalText: run.finalText,
      toolEvents: run.events,
      changedFiles,
      policyViolations: violations,
    })
    return {
      status: "blocked",
      summary: `audit repair pass ${pass} blocked by runtime policy violation(s)`,
      changedFiles,
    }
  }

  if (changedFiles.length === 0) {
    await appendAuditRepairAttempt(executeLogPath, {
      iteration: pass,
      status: "NO_CHANGES",
      startedAt,
      finishedAt: toUtcTimestamp(),
      model: `${run.model}`,
      finalText: run.finalText,
      toolEvents: run.events,
      changedFiles,
    })
    return {
      status: "no_changes",
      summary: `audit repair pass ${pass} produced no in-scope changes`,
      changedFiles,
    }
  }

  const previousPatch = await readOptionalText(resolve(projectRoot, ".signum/combined.patch"))
  const combinedPatch = await buildCombinedPatch(pi, projectRoot)
  await writeFile(resolve(projectRoot, ".signum/combined.patch"), combinedPatch, "utf8")
  await writeIterationDeltaPatch(projectRoot, previousPatch, combinedPatch)

  const boundary = await runBoundaryVerification(pi, projectRoot, contract as any, policy, changedFiles)
  if (!boundary.ok) {
    await appendAuditRepairAttempt(executeLogPath, {
      iteration: pass,
      status: "BOUNDARY_BLOCKED",
      startedAt,
      finishedAt: toUtcTimestamp(),
      model: `${run.model}`,
      finalText: run.finalText,
      toolEvents: run.events,
      changedFiles,
      boundaryVerification: boundary.output,
    })
    return {
      status: "blocked",
      summary: `audit repair pass ${pass} failed boundary verification`,
      changedFiles,
    }
  }

  const transition = await runTransitionVerification(pi, projectRoot)
  if (!transition.ok) {
    await appendAuditRepairAttempt(executeLogPath, {
      iteration: pass,
      status: "TRANSITION_BLOCKED",
      startedAt,
      finishedAt: toUtcTimestamp(),
      model: `${run.model}`,
      finalText: run.finalText,
      toolEvents: run.events,
      changedFiles,
      transitionVerification: transition.output,
    })
    return {
      status: "blocked",
      summary: `audit repair pass ${pass} failed transition verification`,
      changedFiles,
    }
  }

  await appendAuditRepairAttempt(executeLogPath, {
    iteration: pass,
    status: "SUCCESS",
    startedAt,
    finishedAt: toUtcTimestamp(),
    model: `${run.model}`,
    finalText: run.finalText,
    toolEvents: run.events,
    changedFiles,
  })

  return {
    status: "success",
    summary: `audit repair pass ${pass} completed (${changedFiles.length} changed file(s))`,
    changedFiles,
  }
}

export async function selectAuditRepairEngineerModel(input: {
  ctx: ExtensionCommandContext
  availableModels: Model[]
}): Promise<Model | null> {
  const promptAsset = await loadRolePromptAsset("engineer")
  return (
    selectRoleModel("engineer", {
      currentModel: input.ctx.model,
      availableModels: input.availableModels,
      preferredModelId: promptAsset.preferredModelId,
    }) ?? null
  )
}

export async function snapshotAuditIterationArtifacts(projectRoot: string, pass: number) {
  const passDir = resolve(projectRoot, ".signum/iterations", String(pass).padStart(2, "0"))
  await mkdir(resolve(passDir, "reviews"), { recursive: true })
  await mkdir(resolve(passDir, "receipts"), { recursive: true })

  for (const relativePath of [
    ".signum/combined.patch",
    ".signum/iteration_delta.patch",
    ".signum/mechanic_report.json",
    ".signum/policy_scan.json",
    ".signum/holdout_report.json",
    ".signum/audit_summary.json",
    ".signum/audit_iteration_log.json",
    ".signum/repair_brief.json",
    ".signum/execute_log.json",
  ]) {
    await copyIfExists(projectRoot, relativePath, resolve(passDir, relativePath.replace(/^\.signum\//, "")))
  }

  for (const providerKey of ["claude", "codex", "gemini"] as const) {
    await copyIfExists(
      projectRoot,
      `.signum/reviews/${providerKey}.json`,
      resolve(passDir, "reviews", `${providerKey}.json`),
    )
  }

  await copyIfExists(projectRoot, ".signum/receipts/execute.json", resolve(passDir, "receipts", "execute.json"))
}

function computeResolvedFindings(auditIterations: AuditIterationLogEntry[]) {
  const finalFingerprints = new Set((auditIterations[auditIterations.length - 1]?.canonicalFindings ?? []).map((finding) => finding.fingerprint))
  const firstSeen = new Map<string, AuditIterationFinding>()
  const lastSeenPass = new Map<string, number>()

  for (const iteration of auditIterations) {
    for (const finding of iteration.canonicalFindings) {
      if (!firstSeen.has(finding.fingerprint)) {
        firstSeen.set(finding.fingerprint, finding)
      }
      lastSeenPass.set(finding.fingerprint, iteration.pass)
    }
  }

  return [...firstSeen.entries()]
    .filter(([fingerprint]) => !finalFingerprints.has(fingerprint))
    .map(([fingerprint, finding]) => ({
      fingerprint,
      category: finding.category,
      file: finding.file,
      severity: finding.severity,
      resolvedInPass: Math.min((lastSeenPass.get(fingerprint) ?? 0) + 1, auditIterations.length),
    }))
}

async function writeIterationDeltaPatch(projectRoot: string, previousPatch: string | null, currentPatch: string) {
  const deltaPath = resolve(projectRoot, ".signum/iteration_delta.patch")
  if (!previousPatch || previousPatch.trim().length === 0) {
    await writeFile(deltaPath, currentPatch, "utf8")
    return
  }
  if (previousPatch.trim() === currentPatch.trim()) {
    await rm(deltaPath, { force: true })
    return
  }
  await writeFile(deltaPath, currentPatch, "utf8")
}

async function appendAuditRepairAttempt(executeLogPath: string, attempt: Record<string, unknown>) {
  const existing = (await readOptionalJson<ExecuteLog>(executeLogPath)) ?? {}
  const auditRepairAttempts = Array.isArray(existing.auditRepairAttempts) ? [...existing.auditRepairAttempts, attempt] : [attempt]
  await writeJson(executeLogPath, {
    ...existing,
    finished_at: toUtcTimestamp(),
    auditRepairAttempts,
  })
}

async function copyIfExists(projectRoot: string, sourceRelativePath: string, destinationPath: string) {
  const sourcePath = resolve(projectRoot, sourceRelativePath)
  if (!(await exists(sourcePath))) return
  await mkdir(dirname(destinationPath), { recursive: true })
  await copyFile(sourcePath, destinationPath)
}

async function readOptionalJson<T>(path: string): Promise<T | null> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as T
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
