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
  acceptanceCriteria?: Array<Record<string, unknown>>
  holdoutScenarios?: Array<Record<string, unknown>>
  [key: string]: unknown
}

const DEFAULT_TIMEOUT_MS = 30_000

export function normalizeContractForPiRuntime<T extends ContractLike>(contract: T): T {
  const next = {
    ...contract,
    acceptanceCriteria: Array.isArray(contract.acceptanceCriteria)
      ? contract.acceptanceCriteria.map((criterion) => normalizeCriterion(criterion))
      : contract.acceptanceCriteria,
    holdoutScenarios: Array.isArray(contract.holdoutScenarios)
      ? contract.holdoutScenarios.map((scenario) => normalizeHoldoutScenario(scenario))
      : contract.holdoutScenarios,
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
