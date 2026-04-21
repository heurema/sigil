import type { Model } from "@mariozechner/pi-ai"

export type SignumRole =
  | "contractor"
  | "engineer"
  | "reviewer-semantic"
  | "reviewer-security"
  | "reviewer-performance"
  | "synthesizer"
  | "init-synthesizer"

export function selectRoleModel(
  role: SignumRole,
  options: {
    currentModel?: Model
    availableModels: Model[]
    preferredModelId?: string
    preferFallback?: boolean
  },
): Model | undefined {
  const available = dedupeModels(options.availableModels)
  if (available.length === 0) return options.currentModel

  const currentAvailable = findMatchingModel(available, options.currentModel)
  if (currentAvailable && !options.preferFallback) {
    return currentAvailable
  }

  if (options.preferFallback) {
    return pickFallbackModel(available, currentAvailable ?? options.currentModel, role) ?? currentAvailable ?? options.currentModel ?? available[0]
  }

  if (options.preferredModelId) {
    const direct = available.find((model) => model.id === options.preferredModelId)
    if (direct) return direct
  }

  return pickInitialModel(available, role) ?? currentAvailable ?? options.currentModel ?? available[0]
}

function dedupeModels(models: Model[]): Model[] {
  const seen = new Set<string>()
  const unique: Model[] = []
  for (const model of models) {
    const key = `${model.provider}/${model.id}`
    if (seen.has(key)) continue
    seen.add(key)
    unique.push(model)
  }
  return unique
}

function pickInitialModel(models: Model[], role: SignumRole): Model | undefined {
  if (role === "contractor") {
    return pickByPatterns(models, [/haiku/i, /mini/i, /flash/i]) ?? pickByPatterns(models, [/sonnet/i, /gpt-5/i, /pro/i])
  }
  return pickByPatterns(models, [/sonnet/i, /gpt-5/i, /pro/i, /opus/i]) ?? models[0]
}

function pickFallbackModel(models: Model[], currentModel: Model | undefined, role: SignumRole): Model | undefined {
  const candidates = models.filter((model) => !isSameModel(model, currentModel))
  const sameProviderCandidates = currentModel
    ? candidates.filter((model) => model.provider === currentModel.provider)
    : []
  return (
    pickProviderAwareFallback(sameProviderCandidates, role) ??
    pickProviderAwareFallback(candidates, role) ??
    pickInitialModel(candidates, role)
  )
}

function pickProviderAwareFallback(models: Model[], role: SignumRole): Model | undefined {
  const rolePatterns = role === "contractor"
    ? [/haiku/i, /mini/i, /flash/i, /sonnet/i, /gpt-5/i, /pro/i]
    : [/sonnet/i, /gpt-5/i, /pro/i, /opus/i, /thinking/i, /flash/i, /mini/i, /haiku/i]
  return pickByPatterns(models, rolePatterns)
}

function findMatchingModel(models: Model[], currentModel: Model | undefined): Model | undefined {
  return models.find((model) => isSameModel(model, currentModel))
}

function isSameModel(left: Model | undefined, right: Model | undefined): boolean {
  if (!left || !right) return false
  return `${left.provider}/${left.id}` === `${right.provider}/${right.id}`
}

function pickByPatterns(models: Model[], patterns: RegExp[]): Model | undefined {
  return models.find((model) => patterns.some((pattern) => pattern.test(model.id) || pattern.test(model.name ?? "")))
}
