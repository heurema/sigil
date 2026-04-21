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

  if (options.preferFallback) {
    return pickFallbackModel(available, options.currentModel, role) ?? options.currentModel ?? available[0]
  }

  if (options.preferredModelId) {
    const direct = available.find((model) => model.id === options.preferredModelId)
    if (direct) return direct
  }

  if (options.currentModel) {
    return options.currentModel
  }

  return pickInitialModel(available, role) ?? available[0]
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
  const candidates = models.filter((model) => !currentModel || `${model.provider}/${model.id}` !== `${currentModel.provider}/${currentModel.id}`)
  return pickByPatterns(candidates, [/sonnet/i, /gpt-5/i, /pro/i, /opus/i, /thinking/i]) ?? pickInitialModel(candidates, role)
}

function pickByPatterns(models: Model[], patterns: RegExp[]): Model | undefined {
  return models.find((model) => patterns.some((pattern) => pattern.test(model.id) || pattern.test(model.name ?? "")))
}
