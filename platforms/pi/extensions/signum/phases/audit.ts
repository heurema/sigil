import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"

import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"
import type { Model } from "@mariozechner/pi-ai"

import { dslRunnerScriptPath, mechanicParserScriptPath, policyScannerScriptPath } from "../paths.ts"
import { selectRoleModel, type SignumRole } from "../models.ts"
import { loadRolePromptAsset, SdkRoleSessionRunner } from "../runtime/role-session.ts"
import { toUtcTimestamp } from "../runtime/script-adapters/checks.ts"
import { setSignumStatus } from "../ui.ts"

interface ContractDocument {
  contractId: string
  riskLevel: "low" | "medium" | "high"
  goal: string
  acceptanceCriteria: Array<{ id: string; visibility?: string; description?: string; verify?: unknown }>
  holdoutScenarios?: Array<{ id?: string; description?: string; verify?: unknown }>
}

interface MechanicReport {
  checks?: Array<{ status?: string; regression?: boolean }>
  hasRegressions?: boolean
}

interface PolicyScanReport {
  summaryCounts?: { critical?: number; major?: number; minor?: number; total?: number }
}

interface HoldoutReport {
  total: number
  passed: number
  failed: number
  errors: number
  results: Array<{ id: string; description?: string; status: string; error?: string | null }>
}

interface ExecuteLog {
  totalAttempts?: number
}

interface ExecuteReceipt {
  status?: string
  summary?: { total_acs?: number; passed_acs?: number }
}

interface ReviewFinding {
  file: string
  line: number
  severity: "CRITICAL" | "MAJOR" | "MINOR"
  category: string
  comment: string
  evidence: string
  confirmedBy?: string[]
  fingerprint?: string
}

interface ReviewDocument {
  verdict: "APPROVE" | "REJECT" | "CONDITIONAL" | "UNAVAILABLE"
  reviewedFiles: string[]
  findings: ReviewFinding[]
  summary: string
  parseOk: boolean
  available: boolean
  role?: string
  model?: string
  raw?: string
}

interface ReviewRolePlan {
  role: Extract<SignumRole, "reviewer-semantic" | "reviewer-security" | "reviewer-performance">
  providerKey: "claude" | "codex" | "gemini"
  outputPath: string
  model?: Model
}

export interface AuditPhaseResult {
  status: "ok" | "failed"
  decision?: "AUTO_OK" | "AUTO_BLOCK" | "HUMAN_REVIEW"
  summary: string
}

export async function runAuditPhase(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
): Promise<AuditPhaseResult> {
  const projectRoot = ctx.cwd
  const contract = await readJson<ContractDocument>(resolve(projectRoot, ".signum/contract.json"))
  await readJson(resolve(projectRoot, ".signum/contract-engineer.json"))

  setSignumStatus(ctx, "audit mechanic")
  await mkdir(resolve(projectRoot, ".signum", "reviews"), { recursive: true })
  await runRequiredScript(pi, projectRoot, mechanicParserScriptPath, [".signum/baseline.json"], "mechanic parser")

  setSignumStatus(ctx, "audit policy")
  await runScriptAllowFailure(pi, projectRoot, policyScannerScriptPath, [".signum/combined.patch"])

  setSignumStatus(ctx, "audit holdout")
  const holdoutReport = await runHoldoutValidation(pi, projectRoot, contract)

  setSignumStatus(ctx, "audit review context")
  await writeReviewContext(pi, projectRoot)

  const runner = new SdkRoleSessionRunner()
  const availableModels = await ctx.modelRegistry.getAvailable()
  const semanticPrompt = await loadRolePromptAsset("reviewer-semantic")
  const semanticModel = selectRoleModel("reviewer-semantic", {
    currentModel: ctx.model,
    availableModels,
    preferredModelId: semanticPrompt.preferredModelId,
  })
  if (!semanticModel) {
    throw new Error("No authenticated model available for semantic reviewer")
  }

  const reviewPlans = buildReviewPlan(contract.riskLevel, availableModels, semanticModel)
  const reviewResults: Array<Promise<{ providerKey: ReviewRolePlan["providerKey"]; review: ReviewDocument }>> = []

  for (const plan of reviewPlans) {
    const absoluteOutputPath = resolve(projectRoot, plan.outputPath)
    if (!plan.model) {
      await writeJson(absoluteOutputPath, unavailableReview(plan.providerKey, "No distinct reviewer model available in the current pi runtime."))
      continue
    }

    const prompt = buildReviewerPrompt(plan.providerKey, plan.outputPath)
    reviewResults.push(
      runner
        .run({
          role: plan.role,
          projectRoot,
          prompt,
          model: plan.model,
        })
        .then(async (result) => ({
          providerKey: plan.providerKey,
          review: await finalizeReviewArtifact(plan.providerKey, absoluteOutputPath, result.finalText, `${result.model}`),
        })),
    )
  }

  const completedReviews = await Promise.all(reviewResults)
  for (const completed of completedReviews) {
    await writeJson(resolve(projectRoot, ".signum", "reviews", `${completed.providerKey}.json`), completed.review)
  }

  for (const providerKey of ["claude", "codex", "gemini"] as const) {
    const reviewPath = resolve(projectRoot, ".signum", "reviews", `${providerKey}.json`)
    if (!(await exists(reviewPath))) {
      await writeJson(reviewPath, unavailableReview(providerKey, `${providerKey} reviewer was not launched for this risk profile.`))
    }
  }

  const reviews = {
    claude: await readJson<ReviewDocument>(resolve(projectRoot, ".signum/reviews/claude.json")),
    codex: await readJson<ReviewDocument>(resolve(projectRoot, ".signum/reviews/codex.json")),
    gemini: await readJson<ReviewDocument>(resolve(projectRoot, ".signum/reviews/gemini.json")),
  }
  const mechanic = await readJson<MechanicReport>(resolve(projectRoot, ".signum/mechanic_report.json"))
  const policyScan = await readJson<PolicyScanReport>(resolve(projectRoot, ".signum/policy_scan.json"))
  const executeLog = await readJson<ExecuteLog>(resolve(projectRoot, ".signum/execute_log.json"))
  const executeReceipt = await readOptionalJson<ExecuteReceipt>(resolve(projectRoot, ".signum/receipts/execute.json"))

  setSignumStatus(ctx, "audit synthesize")
  const synthOpinion = await runSynthesizer(runner, ctx, projectRoot)
  const auditSummary = buildAuditSummary({
    contract,
    mechanic,
    policyScan,
    holdout: holdoutReport,
    executeLog,
    executeReceipt,
    reviews,
    synthOpinion,
  })

  await writeJson(resolve(projectRoot, ".signum/audit_summary.json"), auditSummary)

  return {
    status: "ok",
    decision: auditSummary.decision,
    summary: [
      `AUDIT complete: ${auditSummary.decision}`,
      `Mechanic: ${auditSummary.mechanic}`,
      `Available reviews: ${auditSummary.availableReviews}/3`,
      `Consensus: ${auditSummary.consensus}`,
      `Confidence: ${auditSummary.confidence.overall}%`,
      `Reasoning: ${auditSummary.reasoning}`,
    ].join("\n"),
  }
}

function buildReviewPlan(riskLevel: ContractDocument["riskLevel"], availableModels: Model[], semanticModel: Model): ReviewRolePlan[] {
  const projectReviews: ReviewRolePlan[] = [
    {
      role: "reviewer-semantic",
      providerKey: "claude",
      outputPath: ".signum/reviews/claude.json",
      model: semanticModel,
    },
  ]

  if (riskLevel === "low") {
    projectReviews.push(
      { role: "reviewer-security", providerKey: "codex", outputPath: ".signum/reviews/codex.json" },
      { role: "reviewer-performance", providerKey: "gemini", outputPath: ".signum/reviews/gemini.json" },
    )
    return projectReviews
  }

  const securityModel = pickAdditionalReviewerModel(availableModels, [semanticModel], [/gpt-5/i, /gpt/i, /sonnet/i, /opus/i, /pro/i, /gemini/i])
  const performanceModel = pickAdditionalReviewerModel(
    availableModels,
    [semanticModel, securityModel].filter(Boolean) as Model[],
    [/gemini/i, /flash/i, /pro/i, /gpt/i, /sonnet/i, /opus/i],
  )

  projectReviews.push(
    {
      role: "reviewer-security",
      providerKey: "codex",
      outputPath: ".signum/reviews/codex.json",
      model: securityModel,
    },
    {
      role: "reviewer-performance",
      providerKey: "gemini",
      outputPath: ".signum/reviews/gemini.json",
      model: performanceModel,
    },
  )

  return projectReviews
}

function pickAdditionalReviewerModel(models: Model[], used: Model[], preferredPatterns: RegExp[]): Model | undefined {
  const usedKeys = new Set(used.map((model) => `${model.provider}/${model.id}`))
  const usedProviders = new Set(used.map((model) => model.provider))
  const candidates = models.filter((model) => !usedKeys.has(`${model.provider}/${model.id}`))
  const differentProvider = candidates.filter((model) => !usedProviders.has(model.provider))
  return (
    pickByPatterns(differentProvider, preferredPatterns) ??
    pickByPatterns(candidates, preferredPatterns) ??
    differentProvider[0] ??
    candidates[0]
  )
}

function pickByPatterns(models: Model[], patterns: RegExp[]): Model | undefined {
  return models.find((model) => patterns.some((pattern) => pattern.test(model.id) || pattern.test(model.name ?? "")))
}

function buildReviewerPrompt(providerKey: "claude" | "codex" | "gemini", outputPath: string): string {
  const focus =
    providerKey === "claude"
      ? "semantic correctness, requirement coverage, and regressions"
      : providerKey === "codex"
        ? "security-sensitive defects only"
        : "performance-sensitive defects only"

  return [
    "Read .signum/contract.json, .signum/combined.patch, .signum/mechanic_report.json, and .signum/review_context.json.",
    "Also read .signum/policy_scan.json if it exists for extra context, but do not duplicate deterministic scanner findings unless the patch evidence supports them.",
    `Focus on ${focus}.`,
    `Write a strict JSON review object to ${outputPath}.`,
    "If file writing fails, emit ONLY the JSON object as final text.",
    "Do not emit markdown fences or explanatory prose outside the JSON object.",
  ].join("\n")
}

async function finalizeReviewArtifact(
  providerKey: "claude" | "codex" | "gemini",
  outputPath: string,
  finalText: string,
  model: string,
): Promise<ReviewDocument> {
  const onDisk = await readOptionalJson<Record<string, unknown>>(outputPath)
  const candidate = onDisk ?? extractJsonObject(finalText)
  if (!candidate) {
    return parseFailureReview(providerKey, "Reviewer did not produce a parseable JSON object.", finalText, model)
  }

  const normalized = normalizeReviewDocument(candidate, providerKey, model)
  await writeJson(outputPath, normalized)
  return normalized
}

function normalizeReviewDocument(raw: Record<string, unknown>, providerKey: string, model: string): ReviewDocument {
  const verdict = normalizeVerdict(raw.verdict)
  const findings = Array.isArray(raw.findings) ? raw.findings.map(normalizeFinding).filter(Boolean) as ReviewFinding[] : []
  const reviewedFiles = Array.isArray(raw.reviewedFiles)
    ? raw.reviewedFiles.filter((value): value is string => typeof value === "string" && value.length > 0)
    : []

  return {
    verdict,
    reviewedFiles,
    findings,
    summary: typeof raw.summary === "string" && raw.summary.trim().length > 0 ? raw.summary.trim() : `${providerKey} review completed`,
    parseOk: verdict !== "UNAVAILABLE",
    available: raw.available === false ? false : verdict !== "UNAVAILABLE",
    role: providerKey,
    model,
  }
}

function normalizeFinding(raw: unknown): ReviewFinding | undefined {
  if (!raw || typeof raw !== "object") return undefined
  const record = raw as Record<string, unknown>
  const severity = normalizeSeverity(record.severity)
  return {
    file: typeof record.file === "string" ? record.file : "",
    line: typeof record.line === "number" ? record.line : Number(record.line ?? 0) || 0,
    severity,
    category: typeof record.category === "string" && record.category.trim().length > 0 ? record.category.trim() : "review",
    comment: typeof record.comment === "string" ? record.comment.trim() : "",
    evidence: typeof record.evidence === "string" ? record.evidence.trim() : "",
  }
}

function normalizeVerdict(value: unknown): ReviewDocument["verdict"] {
  const normalized = typeof value === "string" ? value.trim().toUpperCase() : ""
  if (normalized === "APPROVE" || normalized === "REJECT" || normalized === "CONDITIONAL" || normalized === "UNAVAILABLE") {
    return normalized
  }
  return "CONDITIONAL"
}

function normalizeSeverity(value: unknown): ReviewFinding["severity"] {
  const normalized = typeof value === "string" ? value.trim().toUpperCase() : ""
  if (normalized === "CRITICAL" || normalized === "MAJOR" || normalized === "MINOR") {
    return normalized
  }
  return "MINOR"
}

function unavailableReview(providerKey: string, summary: string): ReviewDocument {
  return {
    verdict: "UNAVAILABLE",
    reviewedFiles: [],
    findings: [],
    summary,
    parseOk: false,
    available: false,
    role: providerKey,
  }
}

function parseFailureReview(providerKey: string, summary: string, raw: string, model: string): ReviewDocument {
  return {
    verdict: "CONDITIONAL",
    reviewedFiles: [],
    findings: [],
    summary,
    parseOk: false,
    available: true,
    role: providerKey,
    model,
    raw: raw.trim().slice(0, 2000),
  }
}

async function runHoldoutValidation(pi: ExtensionAPI, projectRoot: string, contract: ContractDocument): Promise<HoldoutReport> {
  if (contract.riskLevel === "low") {
    const empty = { total: 0, passed: 0, failed: 0, errors: 0, results: [] }
    await writeJson(resolve(projectRoot, ".signum/holdout_report.json"), empty)
    return empty
  }

  const results: HoldoutReport["results"] = []
  let passed = 0
  let failed = 0
  let errors = 0

  const holdoutAcs = contract.acceptanceCriteria.filter((criterion) => (criterion.visibility ?? "visible") === "holdout")
  for (const criterion of holdoutAcs) {
    const result = await runSingleHoldout(pi, projectRoot, criterion.id, criterion.description ?? criterion.id, criterion.verify)
    results.push(result)
    if (result.status === "PASS") passed += 1
    else if (result.status === "FAIL") failed += 1
    else errors += 1
  }

  for (const [index, scenario] of (contract.holdoutScenarios ?? []).entries()) {
    const result = await runSingleHoldout(
      pi,
      projectRoot,
      scenario.id ?? `HO${index + 1}`,
      scenario.description ?? `Holdout ${index + 1}`,
      scenario.verify,
    )
    results.push(result)
    if (result.status === "PASS") passed += 1
    else if (result.status === "FAIL") failed += 1
    else errors += 1
  }

  const report: HoldoutReport = {
    total: results.length,
    passed,
    failed,
    errors,
    results,
  }
  await writeJson(resolve(projectRoot, ".signum/holdout_report.json"), report)
  return report
}

async function runSingleHoldout(
  pi: ExtensionAPI,
  projectRoot: string,
  id: string,
  description: string,
  verify: unknown,
): Promise<HoldoutReport["results"][number]> {
  const tempDir = await mkdtemp(join(tmpdir(), "signum-holdout-"))
  const verifyPath = join(tempDir, `${id}.json`)

  try {
    await writeFile(verifyPath, `${JSON.stringify(verify ?? null, null, 2)}\n`, "utf8")
    const validate = await pi.exec("bash", [dslRunnerScriptPath, "validate", verifyPath], {
      cwd: projectRoot,
      timeout: 30_000,
    })
    if (validate.code !== 0) {
      return { id, description, status: "ERROR", error: "DSL validation failed" }
    }

    const run = await pi.exec("bash", [dslRunnerScriptPath, "run", verifyPath], {
      cwd: projectRoot,
      timeout: 60_000,
    })
    const parsed = extractJsonObject(run.stdout) ?? extractJsonObject(run.stderr)
    const status = typeof parsed?.status === "string" ? parsed.status.toUpperCase() : run.code === 0 ? "PASS" : "ERROR"
    return {
      id,
      description,
      status: status === "PASS" || status === "FAIL" ? status : "ERROR",
      error: typeof parsed?.error === "string" && parsed.error.length > 0 ? parsed.error : null,
    }
  } finally {
    await rm(tempDir, { recursive: true, force: true })
  }
}

async function writeReviewContext(pi: ExtensionAPI, projectRoot: string) {
  const patch = await safeRead(resolve(projectRoot, ".signum/combined.patch"))
  const changedFiles = [...new Set([...patch.matchAll(/^\+\+\+\s+[bw]\/([^\n]+)$/gm)].map((match) => match[1]).filter(Boolean))]

  const gitHistory: Array<{ file: string; last_commit_sha: string; subject: string; date: string }> = []
  for (const file of changedFiles) {
    const result = await pi.exec("git", ["log", "-1", "--format=%h\x1f%s\x1f%ad", "--date=short", "--", file], {
      cwd: projectRoot,
      timeout: 10_000,
    })
    const line = result.stdout.trim()
    if (!line) {
      gitHistory.push({ file, last_commit_sha: "", subject: "", date: "" })
      continue
    }
    const [sha = "", subject = "", date = ""] = line.split("\x1f")
    gitHistory.push({ file, last_commit_sha: sha, subject, date })
  }

  const issueRefs = [...new Set(gitHistory.flatMap((entry) => [...entry.subject.matchAll(/#(\d+)/g)].map((match) => match[1])))]
    .map((id) => ({ id, title_or_null: null, tracker: "unknown" }))

  const projectIntent = await readOptionalText(resolve(projectRoot, "project.intent.md"))
  await writeJson(resolve(projectRoot, ".signum/review_context.json"), {
    git_history: gitHistory,
    issue_refs: issueRefs,
    project_intent: projectIntent ?? null,
  })
}

async function runSynthesizer(runner: SdkRoleSessionRunner, ctx: ExtensionCommandContext, projectRoot: string) {
  const promptAsset = await loadRolePromptAsset("synthesizer")
  const availableModels = await ctx.modelRegistry.getAvailable()
  const model = selectRoleModel("synthesizer", {
    currentModel: ctx.model,
    availableModels,
    preferredModelId: promptAsset.preferredModelId,
  })
  if (!model) return null

  const run = await runner.run({
    role: "synthesizer",
    projectRoot,
    model,
    prompt: [
      "Read .signum/contract.json, .signum/mechanic_report.json, .signum/policy_scan.json, .signum/reviews/claude.json, .signum/reviews/codex.json, .signum/reviews/gemini.json, .signum/holdout_report.json, .signum/execute_log.json, and .signum/receipts/execute.json if it exists.",
      "Return ONLY a JSON object with keys consensus, reasoning, and decision.",
      "Do not write files for this step.",
    ].join("\n"),
  })

  return extractJsonObject(run.finalText)
}

function buildAuditSummary(input: {
  contract: ContractDocument
  mechanic: MechanicReport
  policyScan: PolicyScanReport
  holdout: HoldoutReport
  executeLog: ExecuteLog
  executeReceipt: ExecuteReceipt | null
  reviews: { claude: ReviewDocument; codex: ReviewDocument; gemini: ReviewDocument }
  synthOpinion: Record<string, unknown> | null
}) {
  const { contract, mechanic, policyScan, holdout, executeLog, executeReceipt, reviews, synthOpinion } = input
  const reviewEntries = Object.entries(reviews) as Array<[keyof typeof reviews, ReviewDocument]>
  const parsedReviews = reviewEntries.filter(([, review]) => review.parseOk && review.available)
  const approveCount = parsedReviews.filter(([, review]) => review.verdict === "APPROVE").length
  const rejectCount = parsedReviews.filter(([, review]) => review.verdict === "REJECT").length
  const conditionalCount = parsedReviews.filter(([, review]) => review.verdict === "CONDITIONAL").length
  const unavailableCount = reviewEntries.filter(([, review]) => !review.available).length
  const parseErrorCount = reviewEntries.filter(([, review]) => review.available && !review.parseOk).length

  const allFindings = reviewEntries.flatMap(([provider, review]) =>
    review.findings.map((finding) => ({
      ...finding,
      confirmedBy: [provider],
      fingerprint: createFindingFingerprint(finding),
    })),
  )
  const criticalCount = allFindings.filter((finding) => finding.severity === "CRITICAL").length
  const majorCount = allFindings.filter((finding) => finding.severity === "MAJOR").length
  const minorCount = allFindings.filter((finding) => finding.severity === "MINOR").length
  const policyCritical = policyScan.summaryCounts?.critical ?? 0
  const mechanicRegression = Boolean(mechanic.hasRegressions)
  const holdoutClean = holdout.failed === 0 && holdout.errors === 0
  const receiptPass = executeReceipt?.status === "PASS"

  const missingOrFailedReviewers = reviewEntries
    .filter(([, review]) => !(review.parseOk && review.available))
    .map(([, review]) => review)
  const mediumGateGraceful = parsedReviews.length >= 1 && missingOrFailedReviewers.every((review) => review.available === false)
  const reviewGateSatisfied =
    contract.riskLevel === "low"
      ? parsedReviews.length >= 1
      : contract.riskLevel === "medium"
        ? parsedReviews.length >= 2 || mediumGateGraceful
        : parsedReviews.length >= 2

  const blockReasons: string[] = []
  if (!receiptPass) blockReasons.push("execute receipt is missing or not PASS")
  if (mechanicRegression) blockReasons.push("mechanic detected new regressions versus baseline")
  if (rejectCount > 0) blockReasons.push("at least one reviewer rejected the change")
  if (criticalCount > 0) blockReasons.push("critical reviewer finding present")
  if (policyCritical > 0) blockReasons.push("policy scan found critical issues")

  let decision: "AUTO_OK" | "AUTO_BLOCK" | "HUMAN_REVIEW" = "HUMAN_REVIEW"
  if (blockReasons.length > 0) {
    decision = "AUTO_BLOCK"
  } else if (
    reviewGateSatisfied &&
    parsedReviews.every(([, review]) => review.verdict === "APPROVE") &&
    majorCount === 0 &&
    criticalCount === 0 &&
    !mechanicRegression &&
    holdoutClean &&
    receiptPass
  ) {
    decision = "AUTO_OK"
  }

  const executionHealth = computeExecutionHealth(executeReceipt, executeLog)
  const baselineStability = computeBaselineStability(mechanic)
  const behavioralEvidence = holdout.total > 0 ? Math.round((holdout.passed / holdout.total) * 100) : 75
  const reviewAlignment =
    approveCount === 3
      ? 100
      : approveCount === 2 && rejectCount === 0 && conditionalCount === 1
        ? 70
        : approveCount === 2 && rejectCount === 0 && conditionalCount === 0
          ? 70
          : approveCount === 2 && rejectCount === 1
            ? 40
            : approveCount === 1
              ? 20
              : 0
  const overall = Math.round(
    executionHealth * 0.25 + baselineStability * 0.15 + behavioralEvidence * 0.35 + reviewAlignment * 0.25,
  )

  const synthAligned = typeof synthOpinion?.decision === "string" ? synthOpinion.decision === decision : true
  const consensus =
    synthAligned && typeof synthOpinion?.consensus === "string" && synthOpinion.consensus.trim().length > 0
      ? synthOpinion.consensus.trim()
      : `${approveCount}/3 approve, ${conditionalCount} conditional, ${rejectCount} reject, ${unavailableCount} unavailable, ${parseErrorCount} parse error`

  const reasoning = buildReasoning({
    decision,
    blockReasons,
    reviewGateSatisfied,
    parsedReviewCount: parsedReviews.length,
    contractRisk: contract.riskLevel,
    holdout,
    synthReasoning: synthAligned && typeof synthOpinion?.reasoning === "string" ? synthOpinion.reasoning : undefined,
    policyCritical,
    majorCount,
    criticalCount,
    mechanicRegression,
    parseErrorCount,
    unavailableCount,
  })

  return {
    mechanic: mechanicRegression ? "regression" : "pass",
    policy: {
      critical: policyScan.summaryCounts?.critical ?? 0,
      major: policyScan.summaryCounts?.major ?? 0,
      minor: policyScan.summaryCounts?.minor ?? 0,
      total: policyScan.summaryCounts?.total ?? 0,
    },
    reviews: {
      claude: reviews.claude,
      codex: reviews.codex,
      gemini: reviews.gemini,
    },
    availableReviews: parsedReviews.length,
    holdout,
    consensus,
    decision,
    releaseVerdict: decision === "AUTO_OK" ? "PROMOTE" : "HOLD",
    reasoning,
    confidence: {
      execution_health: executionHealth,
      baseline_stability: baselineStability,
      behavioral_evidence: behavioralEvidence,
      review_alignment: reviewAlignment,
      overall,
    },
    iterationsUsed: 1,
    bestIteration: 1,
    iterativeAuditMode: "single-pass",
    findingsCount: {
      critical: criticalCount,
      major: majorCount,
      minor: minorCount,
    },
    generatedAt: toUtcTimestamp(),
  }
}

function buildReasoning(input: {
  decision: "AUTO_OK" | "AUTO_BLOCK" | "HUMAN_REVIEW"
  blockReasons: string[]
  reviewGateSatisfied: boolean
  parsedReviewCount: number
  contractRisk: ContractDocument["riskLevel"]
  holdout: HoldoutReport
  synthReasoning?: string
  policyCritical: number
  majorCount: number
  criticalCount: number
  mechanicRegression: boolean
  parseErrorCount: number
  unavailableCount: number
}): string {
  const reasons: string[] = []

  if (input.blockReasons.length > 0) {
    reasons.push(...input.blockReasons)
  } else {
    if (!input.reviewGateSatisfied) {
      reasons.push(`review coverage is insufficient for ${input.contractRisk} risk (${input.parsedReviewCount} parsed review(s))`)
    }
    if (input.holdout.failed > 0 || input.holdout.errors > 0) {
      reasons.push(`holdout verification reported ${input.holdout.failed} failure(s) and ${input.holdout.errors} error(s)`)
    }
    if (input.majorCount > 0) {
      reasons.push(`${input.majorCount} major reviewer finding(s) remain open`)
    }
  }

  if (input.parseErrorCount > 0) reasons.push(`${input.parseErrorCount} reviewer output(s) could not be parsed cleanly`)
  if (input.unavailableCount > 0) reasons.push(`${input.unavailableCount} reviewer slot(s) were unavailable in this runtime`)
  if (input.policyCritical > 0) reasons.push(`${input.policyCritical} critical policy finding(s) were detected`)
  if (input.criticalCount > 0 && input.decision !== "AUTO_BLOCK") reasons.push(`${input.criticalCount} critical reviewer finding(s) remain open`)
  if (input.mechanicRegression && input.decision !== "AUTO_BLOCK") reasons.push("mechanic reported baseline regressions")
  if (input.decision === "AUTO_OK" && reasons.length === 0) {
    reasons.push("mechanic is clean, review coverage is sufficient, no major findings remain, and holdouts passed")
  }

  if (input.synthReasoning && input.synthReasoning.trim().length > 0) {
    reasons.push(`synthesizer: ${input.synthReasoning.trim()}`)
  }

  return reasons.join("; ")
}

function computeExecutionHealth(executeReceipt: ExecuteReceipt | null, executeLog: ExecuteLog): number {
  const total = Math.max(1, executeReceipt?.summary?.total_acs ?? 0)
  const passed = Math.max(0, executeReceipt?.summary?.passed_acs ?? 0)
  const repairAttempts = Math.max(0, (executeLog.totalAttempts ?? 1) - 1)
  return clampPercent(Math.round((passed / total) * 100 - repairAttempts * 5))
}

function computeBaselineStability(mechanic: MechanicReport): number {
  if (!mechanic.hasRegressions) return 100
  const checks = mechanic.checks ?? []
  if (checks.length === 0) return 0
  const stable = checks.filter((check) => !check.regression).length
  return clampPercent(Math.round((stable / checks.length) * 100))
}

function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, value))
}

function createFindingFingerprint(finding: ReviewFinding): string {
  const normalizedComment = finding.comment.toLowerCase().replace(/line\s+\d+/g, "").replace(/\s+/g, " ").trim()
  return createHash("sha256")
    .update([finding.category, finding.file, normalizedComment].join("|"))
    .digest("hex")
    .slice(0, 8)
}

async function runRequiredScript(
  pi: ExtensionAPI,
  projectRoot: string,
  scriptPath: string,
  args: string[],
  label: string,
) {
  const result = await pi.exec("bash", [scriptPath, ...args], { cwd: projectRoot, timeout: 120_000 })
  if (result.code !== 0) {
    throw new Error(result.stderr || result.stdout || `${label} failed`)
  }
}

async function runScriptAllowFailure(pi: ExtensionAPI, projectRoot: string, scriptPath: string, args: string[]) {
  await pi.exec("bash", [scriptPath, ...args], { cwd: projectRoot, timeout: 120_000 })
}

function extractJsonObject(text: string): Record<string, unknown> | null {
  const trimmed = text.trim()
  if (!trimmed) return null

  const direct = tryParseJson(trimmed)
  if (direct && typeof direct === "object" && !Array.isArray(direct)) {
    return direct as Record<string, unknown>
  }

  const markerMatch = trimmed.match(/###SIGNUM_REVIEW_START###\s*([\s\S]*?)\s*###SIGNUM_REVIEW_END###/)
  if (markerMatch) {
    const marked = tryParseJson(markerMatch[1])
    if (marked && typeof marked === "object" && !Array.isArray(marked)) {
      return marked as Record<string, unknown>
    }
  }

  const firstBrace = trimmed.indexOf("{")
  const lastBrace = trimmed.lastIndexOf("}")
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    const sliced = tryParseJson(trimmed.slice(firstBrace, lastBrace + 1))
    if (sliced && typeof sliced === "object" && !Array.isArray(sliced)) {
      return sliced as Record<string, unknown>
    }
  }

  return null
}

function tryParseJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
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

async function safeRead(path: string): Promise<string> {
  try {
    return await readFile(path, "utf8")
  } catch {
    return ""
  }
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
