import { posix } from "node:path"

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
    steps: record.steps.map((step) => normalizeStep(step)),
    timeout_ms:
      typeof record.timeout_ms === "number" && Number.isFinite(record.timeout_ms) && record.timeout_ms > 0
        ? record.timeout_ms
        : DEFAULT_TIMEOUT_MS,
  }
}

export function collectPiContractVerifyIssues(contract: ContractLike): string[] {
  const issues: VerifyLintIssue[] = []
  const visibleCriteria = Array.isArray(contract.acceptanceCriteria)
    ? contract.acceptanceCriteria.filter((criterion) => (criterion.visibility ?? "visible") !== "holdout")
    : []

  for (const criterion of visibleCriteria) {
    const criterionId = typeof criterion.id === "string" && criterion.id ? criterion.id : "unknown"
    const verify = criterion.verify as VerifyBlock | undefined
    const steps = Array.isArray(verify?.steps) ? verify.steps : []

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

const BRITTLE_SECRECY_PATTERN = /(?:\bholdoutScenarios\b|\bcontract\.holdoutScenarios\b|Read\s+\.signum\/(?:contract|holdout_report)\.json|\.signum\/(?:contract|holdout_report)\.json)/i
const BRITTLE_LITERAL_PATTERN = /iterativeAuditMode\s*:\s*["']single-pass["']/i

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
