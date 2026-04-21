import { posix } from "node:path"

import { compilePortableRegex } from "./portable-regex.ts"

interface VerifyStep {
  type?: unknown
  [key: string]: unknown
}

interface VerifyBlock {
  steps?: unknown
  timeout_ms?: unknown
  [key: string]: unknown
}

interface ContractLike {
  inScope?: unknown
  outOfScope?: unknown
  allowNewFilesUnder?: unknown
  acceptanceCriteria?: Array<Record<string, unknown>>
  holdoutScenarios?: Array<Record<string, unknown>>
  removals?: Array<Record<string, unknown>>
  [key: string]: unknown
}

interface VerifyLintIssue {
  criterionId: string
  message: string
}

export interface PiContractProfile {
  kind: "default" | "meta-task"
  matchedScopes: string[]
}

export interface PiContractValidationResult {
  profile: PiContractProfile
  errors: string[]
  warnings: string[]
  sanitizedVisibleVerifySteps: number
}

const DEFAULT_TIMEOUT_MS = 30_000

export function normalizeContractForPiRuntime<T extends ContractLike>(contract: T): T {
  const next = {
    ...contract,
    inScope: normalizeScopeList(contract.inScope),
    outOfScope: normalizeScopeList(contract.outOfScope),
    allowNewFilesUnder: normalizeScopeList(contract.allowNewFilesUnder, { directoriesOnly: true }),
    acceptanceCriteria: Array.isArray(contract.acceptanceCriteria)
      ? contract.acceptanceCriteria.map((criterion) => normalizeCriterion(criterion))
      : contract.acceptanceCriteria,
    holdoutScenarios: Array.isArray(contract.holdoutScenarios)
      ? contract.holdoutScenarios.map((scenario) => normalizeHoldoutScenario(scenario))
      : contract.holdoutScenarios,
    removals: Array.isArray(contract.removals)
      ? contract.removals.map((removal) => normalizeRemoval(removal))
      : contract.removals,
  }
  return next as T
}

export function normalizeVerifyForPiRuntime(verify: unknown): unknown {
  if (!verify || typeof verify !== "object") return verify
  const record = verify as VerifyBlock
  if (!Array.isArray(record.steps)) return verify

  return {
    ...record,
    steps: record.steps.map((step) => normalizeStep(step)).filter((step) => !isSanitizedAway(step)),
    timeout_ms:
      typeof record.timeout_ms === "number" && Number.isFinite(record.timeout_ms) && record.timeout_ms > 0
        ? record.timeout_ms
        : DEFAULT_TIMEOUT_MS,
  }
}

export function collectPiContractVerifyIssues(contract: ContractLike): string[] {
  const issues: VerifyLintIssue[] = []
  const visibleCriteria = getVisibleCriteria(contract)

  for (const criterion of visibleCriteria) {
    const criterionId = typeof criterion.id === "string" && criterion.id ? criterion.id : "unknown"
    const verify = criterion.verify as VerifyBlock | undefined
    const steps = Array.isArray(verify?.steps) ? verify.steps : []

    if (steps.length === 0) {
      issues.push({
        criterionId,
        message: `${criterionId}: verify.steps must not be empty after pi normalization`,
      })
      continue
    }

    for (const rawStep of steps) {
      if (!rawStep || typeof rawStep !== "object") continue
      const step = rawStep as Record<string, unknown>
      const type = typeof step.type === "string" ? step.type : ""
      const normalizedType = type.toLowerCase().replace(/[-_]/g, "")
      const path = typeof step.path === "string" ? step.path : ""
      const texts = collectStepTexts(step)

      if (["assertreferencematchesimplementation", "assertsemanticalignment", "assertsemanticconsistency"].includes(normalizedType)) {
        issues.push({
          criterionId,
          message: `${criterionId}: avoid ${type}; use explicit file/path assertions in the pi verify dialect`,
        })
      }

      if (normalizedType === "assertmatches" && typeof step.pattern === "string") {
        try {
          compilePortableRegex(step.pattern, { defaultFlags: "m" })
        } catch (error) {
          issues.push({
            criterionId,
            message: `${criterionId}: assertMatches pattern is not portable to the pi runtime (${error instanceof Error ? error.message : String(error)})`,
          })
        }

      }

      if (referencesLatePhaseArtifact(step)) {
        issues.push({
          criterionId,
          message: `${criterionId}: do not require later-phase .signum artifacts during execute-phase verification`,
        })
      }

      if (!isImplementationSourcePath(path)) continue

      if (["assertnotcontains", "assertnotcontainsany"].includes(normalizedType)) {
        for (const text of texts) {
          if (BRITTLE_SECRECY_PATTERN.test(text)) {
            issues.push({
              criterionId,
              message: `${criterionId}: do not ban generic holdout or contract identifiers in implementation source; target engineer-facing repair inputs instead`,
            })
            break
          }
          if (BRITTLE_LITERAL_PATTERN.test(text)) {
            issues.push({
              criterionId,
              message: `${criterionId}: avoid brittle exact source-literal checks like ${JSON.stringify(text)}`,
            })
            break
          }
        }
      }
    }
  }

  return issues.map((issue) => issue.message)
}

export function detectPiContractProfile(contract: ContractLike): PiContractProfile {
  const matchedScopes = normalizeScopeList(contract.inScope) as string[] | unknown
  const items = Array.isArray(matchedScopes) ? matchedScopes.filter((item): item is string => typeof item === "string") : []
  const metaTaskMatches = items.filter((item) => META_TASK_SCOPE_PATTERN.test(item))

  return {
    kind: metaTaskMatches.length > 0 ? "meta-task" : "default",
    matchedScopes: metaTaskMatches,
  }
}

export function analyzePiContractForRuntime(rawContract: ContractLike, normalizedContract: ContractLike = normalizeContractForPiRuntime(rawContract)): PiContractValidationResult {
  const profile = detectPiContractProfile(normalizedContract)
  const errors = collectPiContractVerifyIssues(normalizedContract)
  const warnings: string[] = []
  const sanitizedVisibleVerifySteps = countSanitizedVisibleVerifySteps(rawContract, normalizedContract)

  if (profile.kind === "meta-task") {
    warnings.push(`meta-task profile active for: ${profile.matchedScopes.join(", ")}`)
  }
  if (sanitizedVisibleVerifySteps > 0) {
    warnings.push(`sanitized ${sanitizedVisibleVerifySteps} brittle visible verify step(s) during pi normalization`)
  }

  return {
    profile,
    errors,
    warnings,
    sanitizedVisibleVerifySteps,
  }
}

export function normalizeScopeList(value: unknown, options: { directoriesOnly?: boolean } = {}): unknown {
  if (!Array.isArray(value)) return value

  const normalized: string[] = []
  for (const item of value) {
    const text = String(item ?? "").trim()
    if (!text) continue

    const extracted = extractPathCandidates(text)
      .map((candidate) => normalizePathCandidate(candidate, options))
      .filter((candidate): candidate is string => Boolean(candidate))

    if (extracted.length > 0) {
      normalized.push(...extracted)
      continue
    }

    normalized.push(text.replace(/\s+/g, " "))
  }

  return [...new Set(normalized)]
}

function getVisibleCriteria(contract: ContractLike): Array<Record<string, unknown>> {
  return Array.isArray(contract.acceptanceCriteria)
    ? contract.acceptanceCriteria.filter((criterion) => (criterion.visibility ?? "visible") !== "holdout")
    : []
}

function countSanitizedVisibleVerifySteps(rawContract: ContractLike, normalizedContract: ContractLike): number {
  const rawById = new Map<string, number>()
  for (const criterion of getVisibleCriteria(rawContract)) {
    const criterionId = typeof criterion.id === "string" ? criterion.id : ""
    const steps = Array.isArray((criterion.verify as VerifyBlock | undefined)?.steps) ? ((criterion.verify as VerifyBlock).steps as unknown[]) : []
    if (criterionId) rawById.set(criterionId, steps.length)
  }

  let removed = 0
  for (const criterion of getVisibleCriteria(normalizedContract)) {
    const criterionId = typeof criterion.id === "string" ? criterion.id : ""
    const normalizedSteps = Array.isArray((criterion.verify as VerifyBlock | undefined)?.steps)
      ? ((criterion.verify as VerifyBlock).steps as unknown[]).length
      : 0
    const rawSteps = rawById.get(criterionId) ?? normalizedSteps
    removed += Math.max(0, rawSteps - normalizedSteps)
  }

  return removed
}

function normalizeCriterion(criterion: Record<string, unknown>): Record<string, unknown> {
  return {
    ...criterion,
    visibility: typeof criterion.visibility === "string" ? criterion.visibility : "visible",
    verify: normalizeVerifyForPiRuntime(criterion.verify),
  }
}

function normalizeHoldoutScenario(scenario: Record<string, unknown>): Record<string, unknown> {
  return {
    ...scenario,
    verify: normalizeVerifyForPiRuntime(scenario.verify),
  }
}

function normalizeRemoval(removal: Record<string, unknown>): Record<string, unknown> {
  const path = typeof removal.path === "string" ? normalizePathCandidate(removal.path, {}) : removal.path
  return {
    ...removal,
    ...(typeof path === "string" ? { path } : {}),
  }
}

function normalizeStep(step: unknown): unknown {
  if (!step || typeof step !== "object") return step
  const record = { ...(step as VerifyStep) }
  const normalizedType = normalizeType(record.type)
  if (normalizedType) {
    record.type = normalizedType
  }

  switch (normalizedType) {
    case "assertContains":
    case "assertNotContains": {
      if (typeof record.text !== "string" && typeof record.value === "string") {
        record.text = record.value
      }
      break
    }
    case "assertJsonPathEquals": {
      if (typeof record.jsonPath !== "string" && typeof record.json_path === "string") {
        record.jsonPath = record.json_path
      }
      break
    }
    case "assertOnlyPathsChanged": {
      if (!Array.isArray(record.paths) && Array.isArray(record.allowed)) {
        record.paths = record.allowed
      }
      break
    }
  }

  return record
}

function isSanitizedAway(step: unknown): boolean {
  if (!step || typeof step !== "object") return false
  const record = step as Record<string, unknown>
  const type = typeof record.type === "string" ? record.type.toLowerCase().replace(/[-_]/g, "") : ""

  if (type === "assertmatches") {
    const path = typeof record.path === "string" ? record.path : ""
    const pattern = typeof record.pattern === "string" ? record.pattern : ""
    if (isBrittleShellEntrypointAssertion(path, pattern) || isBrittleShellHelperAssertion(path, pattern)) {
      return true
    }
  }

  if (!["assertnotcontains", "assertnotcontainsany"].includes(type)) return false

  const path = typeof record.path === "string" ? record.path : ""
  if (!isImplementationSourcePath(path)) return false

  return collectStepTexts(record).some((text) => BRITTLE_SECRECY_PATTERN.test(text) || BRITTLE_LITERAL_PATTERN.test(text))
}

function normalizeType(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const key = value.toLowerCase().replace(/[-_]/g, "")
  return TYPE_ALIASES[key] ?? value
}

function collectStepTexts(step: Record<string, unknown>): string[] {
  const texts: string[] = []
  if (typeof step.text === "string") texts.push(step.text)
  if (typeof step.value === "string") texts.push(step.value)
  if (Array.isArray(step.texts)) {
    texts.push(...step.texts.filter((value): value is string => typeof value === "string"))
  }
  return texts
}

function isImplementationSourcePath(path: string): boolean {
  const normalized = path.replace(/^\.\//, "")
  return /\.(?:ts|tsx|js|jsx|mjs|cjs|py|sh)$/.test(normalized)
}

function isShellHarnessPath(path: string): boolean {
  return /\.sh$/i.test(path.replace(/^\.\//, ""))
}

function isBrittleShellEntrypointAssertion(path: string, pattern: string): boolean {
  if (!isShellHarnessPath(path)) return false
  const normalized = pattern
    .replace(/\\\//g, "/")
    .replace(/\\\./g, ".")
    .toLowerCase()
  return normalized.includes("pi") && normalized.includes("--no-extensions") && normalized.includes("platforms/pi/extensions/signum/index")
}

function isBrittleShellHelperAssertion(path: string, pattern: string): boolean {
  if (!isShellHarnessPath(path)) return false
  const normalized = pattern.toLowerCase()
  return (normalized.includes("python3") || normalized.includes("jq")) && normalized.includes("json")
}

function extractPathCandidates(text: string): string[] {
  const pattern = /(?:\.?\/?[A-Za-z0-9_@-]+(?:\/[A-Za-z0-9_.@-]+)+\/?|\.?\/?[A-Za-z0-9_@-]+\/|[A-Za-z0-9_.@-]+\.[A-Za-z0-9]+)/g
  return [...text.matchAll(pattern)].map((match) => match[0])
}

function normalizePathCandidate(
  value: string,
  options: { directoriesOnly?: boolean },
): string | null {
  const hadDirectorySignal = /\/$/.test(value)
  let normalized = value
    .trim()
    .replace(/^[`'"(\[]+/, "")
    .replace(/[\])'"`.,;:]+$/, "")
    .replace(/^\.\//, "")
    .replace(/\/+/g, "/")

  if (!normalized) return null

  while (normalized.endsWith("/")) {
    normalized = normalized.slice(0, -1)
  }
  if (!normalized) return null

  if (options.directoriesOnly && looksLikeFilePath(normalized)) {
    normalized = posix.dirname(normalized)
  }

  if (normalized === ".") return null
  if (looksLikePath(normalized)) return normalized
  if (hadDirectorySignal && /^[A-Za-z0-9_@-]+$/.test(normalized)) return normalized
  return null
}

function looksLikeFilePath(value: string): boolean {
  const base = value.split("/").pop() ?? value
  return /\.[A-Za-z0-9]+$/.test(base)
}

function looksLikePath(value: string): boolean {
  return /[/.]/.test(value) && !/^\.[A-Za-z0-9]+$/.test(value) && !/\s/.test(value)
}

function referencesLatePhaseArtifact(step: Record<string, unknown>): boolean {
  const path = typeof step.path === "string" ? step.path : ""
  if (LATE_PHASE_SIGNUM_PATH_PATTERN.test(path)) return true
  const command = typeof step.command === "string" ? step.command : ""
  if (LATE_PHASE_SIGNUM_PATH_PATTERN.test(command)) return true
  return false
}

const META_TASK_SCOPE_PATTERN = /^(?:platforms\/pi\/extensions\/signum|docs\/reference\.md|platforms\/pi\/README\.md|tests(?:\/|$))/
const LATE_PHASE_SIGNUM_PATH_PATTERN = /\.signum\/(?:repair_brief|audit_iteration_log|iterations\/|proofpack|anti_entropy|holdout_report|reviews\/)/i
const BRITTLE_SECRECY_PATTERN = /(?:\bholdoutScenarios\b|\bcontract\.holdoutScenarios\b|Read\s+\.signum\/(?:contract|holdout_report)\.json|\.signum\/(?:contract|holdout_report)\.json)/i
const BRITTLE_LITERAL_PATTERN = /(?:iterativeAuditMode\s*:\s*["']single-pass["']|full-pipeline-single-pass-audit)/i

const TYPE_ALIASES: Record<string, string> = {
  readfile: "readFile",
  run: "run",
  gitdiff: "gitDiff",
  gitdifffiles: "gitDiffFiles",
  assertcontains: "assertContains",
  assertnotcontains: "assertNotContains",
  assertnotcontainsany: "assertNotContainsAny",
  assertjsonpathequals: "assertJsonPathEquals",
  assertgitdiffpaths: "assertOnlyPathsChanged",
  assertonlypathschanged: "assertOnlyPathsChanged",
  assertnofilechangesoutside: "assertOnlyPathsChanged",
  assertequals: "assertEquals",
  assertmatches: "assertMatches",
  assertnotmodified: "assertNotModified",
  assertpathnotmodified: "assertNotModified",
  assertnodiff: "assertNotModified",
  assertfileunchanged: "assertNotModified",
  assertfileexists: "assertFileExists",
  assertreferencematchesimplementation: "assertReferenceMatchesImplementation",
  assertsemanticalignment: "assertSemanticAlignment",
  assertsemanticconsistency: "assertSemanticAlignment",
}
