import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import { resolve } from "node:path"

import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import { selectRoleModel } from "../models.ts"
import {
  adrCheckScriptPath,
  assumptionCheckScriptPath,
  contractInjectionScanScriptPath,
  glossaryCheckScriptPath,
  overlapCheckScriptPath,
  proseCheckScriptPath,
  stalenessCheckScriptPath,
  terminologyCheckScriptPath,
} from "../paths.ts"
import {
  ensureContractIndex,
  initContractDirectory,
  registerContract,
  updateContractStatus,
  writeContractIndex,
} from "../runtime/script-adapters/contract-dir.ts"
import { runJsonScript, runTextScript, sha256File, toUtcTimestamp } from "../runtime/script-adapters/checks.ts"
import { loadRolePromptAsset, SdkRoleSessionRunner } from "../runtime/role-session.ts"
import { emitSignumMessage, setSignumStatus } from "../ui.ts"

interface ContractRunOptions {
  task: string
}

interface ContractDocument {
  schemaVersion: string
  contractId: string
  status: string
  timestamps: { createdAt: string; activatedAt?: string }
  goal: string
  inScope: string[]
  outOfScope?: string[]
  allowNewFilesUnder?: string[]
  acceptanceCriteria: Array<{ id: string; description: string; visibility?: string; verify?: unknown }>
  assumptions?: Array<string | { id?: string; text?: string }>
  openQuestions?: string[]
  holdoutScenarios?: unknown[]
  riskLevel: "low" | "medium" | "high"
  riskSignals?: string[]
  requiredInputsProvided?: boolean
  contextInheritance?: Record<string, unknown>
  readinessForPlanning?: { verdict?: string; summary?: string }
  [key: string]: unknown
}

interface SpecQuality {
  total: number
  grade: "A" | "B" | "C" | "D"
  dimensions: {
    testability: number
    negative_coverage: number
    clarity: number
    scope_boundedness: number
    completeness: number
    boundary_system: number
    nl_consistency: number
  }
  warnings?: Record<string, unknown>
}

export interface ContractPhaseResult {
  status: "approved" | "blocked" | "rejected"
  contractId: string
  summary: string
}

const APPROVAL_QUESTIONS = [
  { key: "goal_matches_intent", label: "Goal matches intent", text: "Does the contract goal accurately reflect what you asked for?" },
  { key: "acs_sufficient", label: "ACs sufficient", text: "Are the acceptance criteria complete and testable?" },
  { key: "scope_correct", label: "Scope correct", text: "Is the inScope list appropriate (no missing or extra files)?" },
  { key: "assumptions_valid", label: "Assumptions valid", text: "Are the listed assumptions accurate for your project?" },
  { key: "risk_appropriate", label: "Risk appropriate", text: "Is the stated risk level correct for this change?" },
] as const

export async function runContractPhase(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  options: ContractRunOptions,
): Promise<ContractPhaseResult> {
  const projectRoot = ctx.cwd
  await prepareWorkspace(projectRoot)

  const runner = new SdkRoleSessionRunner()
  const promptAsset = await loadRolePromptAsset("contractor")
  const availableModels = await ctx.modelRegistry.getAvailable()
  const firstModel = selectRoleModel("contractor", {
    currentModel: ctx.model,
    availableModels,
    preferredModelId: promptAsset.preferredModelId,
  })

  if (!firstModel) {
    throw new Error("No authenticated model available for contractor role")
  }

  const basePrompt = [
    `FEATURE_REQUEST: ${options.task}`,
    `PROJECT_ROOT: ${projectRoot}`,
    "",
    "Scan the codebase, assess risk, and write .signum/contract.json.",
  ].join("\n")

  let contractorResult: Awaited<ReturnType<typeof runContractor>>
  try {
    contractorResult = await runContractor(runner, projectRoot, firstModel, basePrompt)
  } catch (error) {
    throw new Error(`Contractor role session failed on first attempt: ${error instanceof Error ? error.message : String(error)}`)
  }
  let contract = await readAndValidateContract(projectRoot)
  if (!contract) {
    contract = await salvageContractFromFinalText(projectRoot, contractorResult.finalText)
  }

  if (!contract) {
    const fallbackModel = selectRoleModel("contractor", {
      currentModel: ctx.model,
      availableModels,
      preferredModelId: promptAsset.preferredModelId,
      preferFallback: true,
    })

    if (!fallbackModel || `${fallbackModel.provider}/${fallbackModel.id}` === `${firstModel.provider}/${firstModel.id}`) {
      throw new Error(`Contractor agent failed to produce a valid contract.json on the first attempt.${formatContractorFailure(contractorResult)}`)
    }

    try {
      contractorResult = await runContractor(runner, projectRoot, fallbackModel, basePrompt)
    } catch (error) {
      throw new Error(`Contractor role session failed on fallback attempt: ${error instanceof Error ? error.message : String(error)}`)
    }
    contract = await readAndValidateContract(projectRoot)
    if (!contract) {
      contract = await salvageContractFromFinalText(projectRoot, contractorResult.finalText)
    }
    if (!contract) {
      throw new Error(`Contractor agent failed to produce a valid contract.json on both attempts.${formatContractorFailure(contractorResult)}`)
    }
  }

  const injection = await runTextScript(pi, contractInjectionScanScriptPath, [resolve(projectRoot, ".signum/contract.json")])
  if (!injection.ok) {
    if (/BLOCKED:/i.test(injection.output)) {
      return {
        status: "blocked",
        contractId: contract.contractId,
        summary: injection.output || "Contract blocked by injection scan.",
      }
    }

    const fallbackScan = scanContractForInvisibleUnicode(contract)
    if (fallbackScan.length > 0) {
      return {
        status: "blocked",
        contractId: contract.contractId,
        summary: fallbackScan.join("\n"),
      }
    }
  }

  const holdoutRetry = holdoutRequirement(contract.riskLevel, contract)
  if (!holdoutRetry.satisfied) {
    const fallbackModel = selectRoleModel("contractor", {
      currentModel: ctx.model,
      availableModels,
      preferredModelId: promptAsset.preferredModelId,
      preferFallback: true,
    }) ?? firstModel

    const retryPrompt = [
      basePrompt,
      "",
      `ADDITIONAL REQUIREMENT: The previous contract had insufficient holdout scenarios for ${contract.riskLevel} risk level.`,
      `Risk level ${contract.riskLevel} requires at least ${holdoutRetry.required} holdout scenarios. Current count: ${holdoutRetry.actual}.`,
      "Generate exactly the required minimum number of high-quality holdout scenarios.",
      "- Each must be a negative test, error path, or boundary condition",
      "- Each must NOT be derivable from the visible acceptance criteria",
      "- Prefer typed DSL verify steps, not manual verification",
      "Keep all other contract fields consistent with the task.",
    ].join("\n")

    try {
      contractorResult = await runContractor(runner, projectRoot, fallbackModel, retryPrompt)
    } catch (error) {
      throw new Error(`Contractor role session failed during holdout retry: ${error instanceof Error ? error.message : String(error)}`)
    }
    contract = await readAndValidateContract(projectRoot)
    if (!contract) {
      contract = await salvageContractFromFinalText(projectRoot, contractorResult.finalText)
    }
    if (!contract) {
      throw new Error(`Contractor retry for holdout generation produced an invalid contract.json.${formatContractorFailure(contractorResult)}`)
    }
  }

  const contractDir = await initContractDirectory(projectRoot, contract.contractId)
  let index = await ensureContractIndex(projectRoot)
  index = registerContract(index, contract, "draft")
  await writeContractIndex(projectRoot, index)
  await copyFile(resolve(projectRoot, ".signum/contract.json"), resolve(contractDir, "contract.json"))

  const specQuality = scoreContract(contract)
  await writeJson(resolve(projectRoot, ".signum/spec_quality.json"), specQuality)
  const mergedSpecQuality = await enrichSpecQualityWithDeterministicChecks(pi, projectRoot, specQuality)

  const summary = buildContractSummary(contract, mergedSpecQuality)
  emitSignumMessage(pi, summary, {
    phase: "contract-summary",
    contractId: contract.contractId,
    riskLevel: contract.riskLevel,
  })

  if (mergedSpecQuality.grade === "D") {
    return {
      status: "blocked",
      contractId: contract.contractId,
      summary: `${summary}\n\nSPEC QUALITY GATE FAILED (grade D). Re-run the contractor with a tighter scope and more testable acceptance criteria.`,
    }
  }

  if ((mergedSpecQuality.staleness as any)?.status === "block") {
    return {
      status: "blocked",
      contractId: contract.contractId,
      summary: `${summary}\n\nBLOCK: upstream artifacts changed (stalenessPolicy=block). Re-run the contractor to refresh context.`,
    }
  }

  if (contract.requiredInputsProvided === false || (contract.openQuestions ?? []).length > 0) {
    return {
      status: "blocked",
      contractId: contract.contractId,
      summary: [
        summary,
        "",
        "Contractor needs additional input:",
        ...(contract.openQuestions ?? []).map((question) => `- ${question}`),
      ].join("\n"),
    }
  }

  if (!ctx.hasUI && !shouldAutoApproveContract()) {
    return {
      status: "blocked",
      contractId: contract.contractId,
      summary: `${summary}\n\nInteractive pi is required for the approval checklist. Set SIGNUM_PI_AUTO_APPROVE=1 only for development smoke tests.`,
    }
  }

  const approval = shouldAutoApproveContract()
    ? { approved: true, failedItems: [] }
    : await runApprovalChecklist(ctx)
  if (!approval.approved) {
    return {
      status: "rejected",
      contractId: contract.contractId,
      summary: [
        summary,
        "",
        "Approval REJECTED. Failed items:",
        ...approval.failedItems.map((item) => `- ${item}`),
        "",
        "Re-run the contractor with this feedback to revise the contract.",
        "Phase 2 will NOT be entered until all checklist items are approved.",
      ].join("\n"),
    }
  }

  const approvedAt = toUtcTimestamp()
  await writeJson(resolve(projectRoot, ".signum/approval.json"), {
    approved: true,
    approvedAt,
    checklist: Object.fromEntries(APPROVAL_QUESTIONS.map((question) => [question.key, true])),
  })

  contract.status = "active"
  contract.timestamps = {
    ...(contract.timestamps ?? { createdAt: approvedAt }),
    activatedAt: approvedAt,
  }
  await writeJson(resolve(projectRoot, ".signum/contract.json"), contract)

  const contractHash = await sha256File(resolve(projectRoot, ".signum/contract.json"))
  await writeFile(
    resolve(projectRoot, ".signum/contract-hash.txt"),
    [`contract_sha256: ${contractHash}`, `approved_at: ${approvedAt}`, `contract_file: .signum/contract.json`, ""].join("\n"),
    "utf8",
  )

  await writeEngineerContract(projectRoot, contract)
  await copyFile(resolve(projectRoot, ".signum/contract.json"), resolve(contractDir, "contract.json"))
  await copyFile(resolve(projectRoot, ".signum/approval.json"), resolve(contractDir, "approval.json"))

  index = updateContractStatus(index, contract.contractId, "active")
  await writeContractIndex(projectRoot, index)

  return {
    status: "approved",
    contractId: contract.contractId,
    summary: [summary, "", `approval.json written at ${approvedAt}`, `Audit chain anchored: ${contractHash} at ${approvedAt}`].join("\n"),
  }
}

async function salvageContractFromFinalText(projectRoot: string, finalText: string): Promise<ContractDocument | null> {
  const extracted = extractJsonObject(finalText)
  if (!extracted) return null

  try {
    const parsed = JSON.parse(extracted) as ContractDocument
    if (!isValidContract(parsed)) return null
    await writeJson(resolve(projectRoot, ".signum/contract.json"), parsed)
    return parsed
  } catch {
    return null
  }
}

function extractJsonObject(text: string): string | null {
  const trimmed = text.trim()
  if (!trimmed) return null

  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i)
  const candidate = fenced ? fenced[1].trim() : trimmed
  const start = candidate.indexOf("{")
  const end = candidate.lastIndexOf("}")
  if (start < 0 || end <= start) return null
  return candidate.slice(start, end + 1)
}

function formatContractorFailure(result: { finalText: string; events?: Array<{ type: string; toolName?: string; isError?: boolean }> }): string {
  const pieces: string[] = []
  if (result.finalText) {
    pieces.push(`Final contractor message: ${result.finalText.replace(/\s+/g, " ").trim().slice(0, 400)}`)
  }
  if (Array.isArray(result.events) && result.events.length > 0) {
    const preview = result.events
      .slice(0, 12)
      .map((event) => `${event.type}${event.toolName ? `:${event.toolName}` : ""}${event.isError ? ":error" : ""}`)
      .join(", ")
    pieces.push(`tool events: ${preview}`)
  }
  return pieces.length > 0 ? ` ${pieces.join(" | ")}` : ""
}

async function runContractor(
  runner: SdkRoleSessionRunner,
  projectRoot: string,
  model: { provider: string; id: string },
  prompt: string,
) {
  return runner.run({
    role: "contractor",
    projectRoot,
    prompt,
    model: model as any,
  })
}

async function prepareWorkspace(projectRoot: string) {
  await mkdir(resolve(projectRoot, ".signum", "reviews"), { recursive: true })
  await mkdir(resolve(projectRoot, ".signum", "contracts"), { recursive: true })

  const gitignorePath = resolve(projectRoot, ".gitignore")
  let gitignore = ""
  try {
    gitignore = await readFile(gitignorePath, "utf8")
  } catch {
    gitignore = ""
  }
  if (!gitignore.split(/\r?\n/).includes(".signum/")) {
    const next = gitignore.length > 0 && !gitignore.endsWith("\n") ? `${gitignore}\n.signum/\n` : `${gitignore}.signum/\n`
    await writeFile(gitignorePath, next, "utf8")
  }
}

async function readAndValidateContract(projectRoot: string): Promise<ContractDocument | null> {
  try {
    const raw = await readFile(resolve(projectRoot, ".signum/contract.json"), "utf8")
    const parsed = JSON.parse(raw) as ContractDocument
    if (!isValidContract(parsed)) return null
    return parsed
  } catch {
    return null
  }
}

function isValidContract(contract: ContractDocument | null | undefined): contract is ContractDocument {
  if (!contract || typeof contract !== "object") return false
  if (!contract.schemaVersion || !contract.goal || !Array.isArray(contract.inScope) || contract.inScope.length === 0) return false
  if (!Array.isArray(contract.acceptanceCriteria) || contract.acceptanceCriteria.length === 0) return false
  if (!contract.riskLevel || !["low", "medium", "high"].includes(contract.riskLevel)) return false
  if (!contract.contractId || !/^sig-.+/.test(contract.contractId)) return false
  if (!contract.status || !contract.timestamps?.createdAt) return false
  return true
}

function scoreContract(contract: ContractDocument): SpecQuality {
  const acCount = contract.acceptanceCriteria.length
  const acWithVerify = contract.acceptanceCriteria.filter((criterion) => hasVerify(criterion.verify)).length
  const inScopeCount = contract.inScope.length
  const hasOutOfScope = (contract.outOfScope ?? []).length > 0 ? 1 : 0
  const hasAssumptions = (contract.assumptions ?? []).length > 0 ? 1 : 0
  const holdoutCount = holdoutRequirement(contract.riskLevel, contract).actual
  const hasHoldouts = holdoutCount > 0 ? 1 : 0
  const reqOk = contract.requiredInputsProvided !== false
  const openQuestionCount = (contract.openQuestions ?? []).length

  const testability = acCount > 0 ? Math.floor((acWithVerify * 25) / acCount) : 0
  const completeness = (reqOk ? 5 : 0) + (openQuestionCount === 0 ? 5 : 0)

  let scopeScore = inScopeCount < 5 ? 15 : inScopeCount < 16 ? 10 : 5
  if (hasOutOfScope) scopeScore = Math.min(15, scopeScore + 3)

  let negativeCoverage = hasHoldouts ? 10 : 0
  const negativeAcs = contract.acceptanceCriteria.filter((criterion) => /must not|should not|\bnever\b|\bprevent|reject|fail|invalid/i.test(criterion.description)).length
  if (negativeAcs > 0) negativeCoverage += 10

  const goal = contract.goal ?? ""
  const clarity = (goal.length >= 20 && goal.length <= 300 ? 10 : 0) + (/works correctly|as expected|properly|should work/i.test(goal) ? 0 : 10)
  const boundary = (hasOutOfScope ? 5 : 0) + (hasAssumptions ? 5 : 0)

  const allAcText = contract.acceptanceCriteria.map((criterion) => criterion.description).join(" ")
  const vagueVerbPoints = /\b(handle|process|manage|support|ensure|implement|perform|utilize|leverage|facilitate)\b/i.test(`${goal} ${allAcText}`) ? 0 : 5
  const terminologyPairs: Array<[string, string]> = [
    ["endpoint", "route"],
    ["function", "method"],
    ["test", "spec"],
    ["error", "exception"],
    ["config", "configuration"],
    ["config", "settings"],
    ["user", "client"],
    ["file", "document"],
  ]
  const terminologyPoints = terminologyPairs.some(([left, right]) => hasWholeWord(`${goal} ${allAcText}`, left) && hasWholeWord(`${goal} ${allAcText}`, right)) ? 0 : 5
  const contradictionPoints = findContradiction(contract.acceptanceCriteria.map((criterion) => criterion.description)) ? 0 : 5
  const nlConsistency = vagueVerbPoints + terminologyPoints + contradictionPoints

  const total = testability + completeness + scopeScore + negativeCoverage + clarity + boundary + nlConsistency
  const grade = total >= 103 ? "A" : total >= 86 ? "B" : total >= 69 ? "C" : "D"

  return {
    total,
    grade,
    dimensions: {
      testability: testability,
      negative_coverage: negativeCoverage,
      clarity,
      scope_boundedness: scopeScore,
      completeness,
      boundary_system: boundary,
      nl_consistency: nlConsistency,
    },
  }
}

const INVISIBLE_UNICODE_PATTERN = /(?:[\uFE00-\uFE0F\u202A-\u202E\u2066-\u2069\u200B-\u200D\uFEFF\u00AD\u034F\u2060-\u2064]|[\u{E0100}-\u{E01EF}]|[\u{E0000}-\u{E007F}])/u

function scanContractForInvisibleUnicode(contract: ContractDocument): string[] {
  const findings: string[] = []
  let index = 0

  for (const value of extractContractStrings(contract)) {
    index += 1
    const match = value.match(INVISIBLE_UNICODE_PATTERN)
    if (!match) continue
    const codePoint = match[0].codePointAt(0)?.toString(16).toUpperCase().padStart(4, "0") ?? "????"
    findings.push(`BLOCKED: invisible Unicode U+${codePoint} in field ${index}: ${value.slice(0, 80)}`)
  }

  return findings
}

function extractContractStrings(value: unknown): string[] {
  if (typeof value === "string") return [value]
  if (Array.isArray(value)) return value.flatMap((item) => extractContractStrings(item))
  if (value && typeof value === "object") {
    return Object.values(value as Record<string, unknown>).flatMap((item) => extractContractStrings(item))
  }
  return []
}

function hasVerify(verify: unknown): boolean {
  if (!verify || typeof verify !== "object") return false
  const candidate = verify as Record<string, unknown>
  return Boolean((typeof candidate.type === "string" && typeof candidate.value === "string") || Array.isArray(candidate.steps))
}

function hasWholeWord(text: string, word: string): boolean {
  return new RegExp(`\\b${word}\\b`, "i").test(text)
}

function findContradiction(descriptions: string[]): boolean {
  const joined = descriptions.join("\n")
  for (const description of descriptions) {
    const matches = description.match(/\b(?:must|allow|enable)\s+([a-z]+)/gi) ?? []
    for (const phrase of matches) {
      if (/must not/i.test(phrase)) continue
      const word = phrase.split(/\s+/)[1]
      if (new RegExp(`must not ${word}|prevent ${word}|disallow ${word}|disable ${word}`, "i").test(joined)) {
        return true
      }
    }
  }
  return false
}

function holdoutRequirement(riskLevel: ContractDocument["riskLevel"], contract: ContractDocument) {
  const holdoutAcs = contract.acceptanceCriteria.filter((criterion) => criterion.visibility === "holdout").length
  const holdoutScenarios = Array.isArray(contract.holdoutScenarios) ? contract.holdoutScenarios.length : 0
  const actual = holdoutAcs + holdoutScenarios
  const required = riskLevel === "medium" ? 2 : riskLevel === "high" ? 5 : 0
  return {
    actual,
    required,
    satisfied: actual >= required,
  }
}

async function enrichSpecQualityWithDeterministicChecks(
  pi: ExtensionAPI,
  projectRoot: string,
  specQuality: SpecQuality,
): Promise<SpecQuality & Record<string, unknown>> {
  const glossaryPath = resolve(projectRoot, "project.glossary.json")
  const indexPath = resolve(projectRoot, ".signum/contracts/index.json")
  const contractPath = resolve(projectRoot, ".signum/contract.json")

  const merged: SpecQuality & Record<string, unknown> = { ...specQuality }

  const checks: Array<Promise<void>> = []

  checks.push(
    safeJsonScript(pi, glossaryCheckScriptPath, [contractPath, "--glossary", glossaryPath]).then((result) => {
      merged.glossary_warnings = (result as any)?.findings ?? []
      merged.glossary_version = (result as any)?.glossary_version ?? ""
      merged.glossary_terms = (result as any)?.glossary_terms ?? 0
    }),
  )

  checks.push(
    safeJsonScript(pi, proseCheckScriptPath, [contractPath]).then((result) => {
      merged.prose_warnings = result ?? {}
    }),
  )

  checks.push(
    safeJsonScript(pi, terminologyCheckScriptPath, [contractPath, "--index", indexPath, "--glossary", glossaryPath]).then((result) => {
      merged.terminology_warnings = (result as any)?.findings ?? []
    }),
  )

  checks.push(
    safeJsonScript(pi, overlapCheckScriptPath, [contractPath, "--index", indexPath]).then((result) => {
      merged.overlap_warnings = (result as any)?.findings ?? []
    }),
  )

  checks.push(
    safeJsonScript(pi, assumptionCheckScriptPath, [contractPath, "--index", indexPath]).then((result) => {
      merged.assumption_warnings = (result as any)?.findings ?? []
    }),
  )

  checks.push(
    safeJsonScript(pi, adrCheckScriptPath, [contractPath, "--project-root", projectRoot]).then((result) => {
      merged.adr_warnings = (result as any)?.findings ?? []
    }),
  )

  checks.push(
    safeJsonScript(pi, stalenessCheckScriptPath, [contractPath, "--project-root", projectRoot]).then(async (result) => {
      merged.staleness = result ?? {}
      const status = (result as any)?.status
      if (status === "fresh" || status === "warn" || status === "block") {
        const contract = (await readAndValidateContract(projectRoot))!
        contract.contextInheritance = {
          ...(contract.contextInheritance ?? {}),
          stalenessStatus: status === "fresh" ? "fresh" : status === "warn" ? "warning" : "stale",
        }
        await writeJson(contractPath, contract)
      }
    }),
  )

  await Promise.all(checks)
  await writeJson(resolve(projectRoot, ".signum/spec_quality.json"), merged)
  return merged
}

async function safeJsonScript(pi: ExtensionAPI, scriptPath: string, args: string[]) {
  try {
    return await runJsonScript(pi, scriptPath, args)
  } catch {
    return {}
  }
}

function buildContractSummary(contract: ContractDocument, specQuality: SpecQuality & Record<string, unknown>): string {
  const visibleAcCount = contract.acceptanceCriteria.filter((criterion) => criterion.visibility !== "holdout").length
  const holdouts = holdoutRequirement(contract.riskLevel, contract).actual
  const warnings = collectWarnings(specQuality, contract)

  return [
    `## Contract: ${contract.contractId}`,
    "",
    `**Goal:** ${contract.goal}`,
    "",
    "| Field | Value |",
    "|-------|-------|",
    `| Risk | ${contract.riskLevel} |`,
    `| Scope | ${(contract.inScope ?? []).join(", ")} |`,
    `| ACs | ${visibleAcCount} visible + ${holdouts} holdout |`,
    `| Spec quality | ${specQuality.total}/115 (${specQuality.grade}) |`,
    `| Readiness | ${contract.readinessForPlanning?.verdict ?? "absent"} |`,
    warnings.length > 0 ? "" : "",
    warnings.length > 0 ? "### Warnings" : "",
    ...warnings.map((warning) => `- ${warning}`),
    "",
    "Human approval checklist — answer yes or no for each:",
    ...APPROVAL_QUESTIONS.map((question, index) => `${index + 1}. ${question.label}: ${question.text}`),
  ]
    .filter((line) => line !== "")
    .join("\n")
}

function collectWarnings(specQuality: Record<string, unknown>, contract: ContractDocument): string[] {
  const warnings: string[] = []
  for (const key of ["glossary_warnings", "terminology_warnings", "overlap_warnings", "assumption_warnings", "adr_warnings"] as const) {
    const value = specQuality[key]
    if (Array.isArray(value) && value.length > 0) {
      warnings.push(`${key.replace(/_/g, " ")}: ${value.length}`)
    }
  }
  const proseWarnings = specQuality.prose_warnings as Record<string, unknown> | undefined
  if (typeof proseWarnings?.total_findings === "number" && proseWarnings.total_findings > 0) {
    warnings.push(`prose warnings: ${proseWarnings.total_findings}`)
  }
  const holdout = holdoutRequirement(contract.riskLevel, contract)
  if (!holdout.satisfied) {
    warnings.push(`holdout gate not satisfied for ${contract.riskLevel} risk (${holdout.actual}/${holdout.required})`)
  }
  if ((specQuality.grade as string) === "D") {
    warnings.push("spec quality gate failed (grade D)")
  }
  if (contract.readinessForPlanning?.verdict === "no-go") {
    warnings.push("contractor self-critique returned no-go")
  }
  return warnings
}

function shouldAutoApproveContract(): boolean {
  return process.env.SIGNUM_PI_AUTO_APPROVE === "1"
}

async function runApprovalChecklist(ctx: ExtensionCommandContext): Promise<{ approved: boolean; failedItems: string[] }> {
  const failedItems: string[] = []

  for (const [index, question] of APPROVAL_QUESTIONS.entries()) {
    const ok = await ctx.ui.confirm(`Approval item ${index + 1}/5`, `${question.label}: ${question.text}`)
    if (ok) continue

    const reason = await ctx.ui.input(`Reason for rejecting \"${question.label}\" (optional):`, "Short explanation")
    failedItems.push(`Item ${index + 1} (${question.label})${reason ? `: ${reason}` : ""}`)
  }

  return {
    approved: failedItems.length === 0,
    failedItems,
  }
}

async function writeEngineerContract(projectRoot: string, contract: ContractDocument) {
  const visibleAcceptanceCriteria = contract.acceptanceCriteria.filter((criterion) => criterion.visibility !== "holdout")
  const holdoutItems = {
    acceptanceCriteria: contract.acceptanceCriteria.filter((criterion) => criterion.visibility === "holdout"),
    holdoutScenarios: contract.holdoutScenarios ?? [],
  }

  const engineerContract: Record<string, unknown> = {
    schemaVersion: contract.schemaVersion,
    contractId: contract.contractId,
    status: contract.status,
    timestamps: contract.timestamps,
    goal: contract.goal,
    inScope: contract.inScope,
    allowNewFilesUnder: contract.allowNewFilesUnder,
    outOfScope: contract.outOfScope,
    acceptanceCriteria: visibleAcceptanceCriteria,
    assumptions: contract.assumptions,
    openQuestions: contract.openQuestions,
    riskLevel: contract.riskLevel,
    riskSignals: contract.riskSignals,
    requiredInputsProvided: contract.requiredInputsProvided,
    contextInheritance: contract.contextInheritance,
  }

  const holdoutCount = holdoutItems.acceptanceCriteria.length + holdoutItems.holdoutScenarios.length
  if (holdoutCount > 0) {
    const holdoutHash = createHash("sha256").update(JSON.stringify(holdoutItems)).digest("hex").slice(0, 16)
    engineerContract.holdoutManifest = {
      count: holdoutCount,
      hash: `sha256:${holdoutHash}`,
    }
  }

  await writeJson(resolve(projectRoot, ".signum/contract-engineer.json"), engineerContract)
}

async function writeJson(path: string, value: unknown) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8")
}
