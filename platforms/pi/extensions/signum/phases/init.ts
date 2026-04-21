import { mkdir, lstat, readFile, writeFile } from "node:fs/promises"
import { basename, dirname, resolve } from "node:path"

import { complete, type Message, type Model } from "@mariozechner/pi-ai"
import { BorderedLoader, type ExtensionAPI, type ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import {
  initHarnessScaffoldScriptPath,
  initScannerScriptPath,
  initSynthesizerPromptPath,
} from "../paths.ts"
import { emitSignumMessage, setSignumStatus } from "../ui.ts"

interface InitCommandInput {
  force: boolean
  harness: boolean
  projectRoot?: string
}

interface HarnessFileDraft {
  path: string
  exists: boolean
  content: string
}

interface HarnessScaffoldResult {
  files: HarnessFileDraft[]
  missingCount: number
  existingCount: number
}

interface InitScanResult {
  signals: Record<string, string>
  existingFiles: {
    glossary?: { path?: string; content?: string }
    intent?: { path?: string; content?: string }
  }
}

interface GlossaryTerm {
  term: string
  definition?: string
  source?: string
}

interface GlossaryDocument {
  version: string
  generatedAt: string
  canonicalTerms: GlossaryTerm[]
  aliases: Record<string, string>
}

interface InitDrafts {
  projectIntent: string
  projectGlossary: GlossaryDocument
  coverageSummary: string
}

export async function runInitPhase(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  input: InitCommandInput,
): Promise<string> {
  if (!ctx.hasUI) {
    return "/signum init requires interactive pi because it uses review/accept flows via ctx.ui.select() and ctx.ui.editor()."
  }

  const projectRoot = await resolveProjectRoot(ctx.cwd, input.projectRoot)
  const projectName = basename(projectRoot)
  const intentPath = resolve(projectRoot, "project.intent.md")
  const glossaryPath = resolve(projectRoot, "project.glossary.json")

  const intentExists = await pathExists(intentPath)
  const glossaryExists = await pathExists(glossaryPath)

  setSignumStatus(ctx, `init: scan ${projectName}`)

  const harnessScaffold = input.harness ? ((await runJsonScript(pi, initHarnessScaffoldScriptPath, ["--project-root", projectRoot])) as HarnessScaffoldResult) : null
  const brownfieldPreserve = Boolean(input.harness && intentExists && glossaryExists && !input.force)

  if ((intentExists || glossaryExists) && !input.force && !brownfieldPreserve) {
    const existing = [intentExists ? "project.intent.md" : null, glossaryExists ? "project.glossary.json" : null]
      .filter(Boolean)
      .join(", ")
    const verb = existing.includes(",") ? "exist" : "exists"
    return `${existing} already ${verb}.\n\nTo overwrite, run: /signum init --force${input.harness ? " --harness" : ""}`
  }

  if (brownfieldPreserve && harnessScaffold && harnessScaffold.missingCount === 0) {
    return "Harness docs already exist. No files written."
  }

  const scanResult = (await runJsonScript(pi, initScannerScriptPath, ["--project-root", projectRoot])) as InitScanResult
  emitSignumMessage(
    pi,
    buildScanSummary(scanResult, {
      harness: input.harness,
      harnessScaffold,
      intentExists,
      glossaryExists,
      projectRoot,
    }),
    {
      phase: "init-scan",
      projectRoot,
    },
  )

  let drafts: InitDrafts | null = null
  if (!brownfieldPreserve) {
    setSignumStatus(ctx, `init: synthesize ${projectName}`)
    drafts = await synthesizeInitDrafts(ctx, scanResult, projectName, projectRoot)
  }

  const missingHarnessFiles = harnessScaffold?.files.filter((file) => !file.exists) ?? []

  setSignumStatus(ctx, `init: review ${projectName}`)
  emitSignumMessage(
    pi,
    buildDraftMessage({
      drafts,
      harnessFiles: brownfieldPreserve ? missingHarnessFiles : harnessScaffold?.files ?? [],
      brownfieldPreserve,
      harness: input.harness,
    }),
    {
      phase: "init-drafts",
      projectRoot,
    },
  )

  const reviewDecision = await promptForInitDecision(ctx, {
    harness: input.harness,
    brownfieldPreserve,
  })
  if (reviewDecision === "cancel") {
    return "Cancelled. No files written."
  }

  let writeContext = !brownfieldPreserve
  let writeGlossary = !brownfieldPreserve
  let writeHarness = Boolean(input.harness)

  if (brownfieldPreserve) {
    writeContext = false
    writeGlossary = false
    writeHarness = true
  } else if (!input.harness) {
    if (reviewDecision === "intent-only") {
      writeGlossary = false
    }
  } else {
    if (reviewDecision === "context-only") {
      writeHarness = false
    }
    if (reviewDecision === "harness-only") {
      writeContext = false
      writeGlossary = false
      writeHarness = true
    }
  }

  if (reviewDecision === "edit-intent" && drafts) {
    const edited = await ctx.ui.editor("Edit project.intent.md", drafts.projectIntent)
    if (edited === undefined) return "Cancelled. No files written."
    drafts.projectIntent = edited
    emitSignumMessage(pi, buildSingleDraftPreview("project.intent.md", drafts.projectIntent), { phase: "init-edit-intent" })
    const confirmed = await ctx.ui.confirm("Write updated intent?", "Proceed with the edited project.intent.md draft?")
    if (!confirmed) return "Cancelled. No files written."
  }

  if (reviewDecision === "edit-glossary" && drafts) {
    const edited = await ctx.ui.editor("Edit project.glossary.json", `${JSON.stringify(drafts.projectGlossary, null, 2)}\n`)
    if (edited === undefined) return "Cancelled. No files written."
    drafts.projectGlossary = normalizeGlossary(parseJsonObjectFromText(edited), scanResult, new Date().toISOString())
    emitSignumMessage(
      pi,
      buildSingleDraftPreview("project.glossary.json", `${JSON.stringify(drafts.projectGlossary, null, 2)}\n`),
      { phase: "init-edit-glossary" },
    )
    const confirmed = await ctx.ui.confirm("Write updated glossary?", "Proceed with the edited project.glossary.json draft?")
    if (!confirmed) return "Cancelled. No files written."
  }

  setSignumStatus(ctx, `init: write ${projectName}`)

  const written: string[] = []
  const skipped: string[] = []
  const errors: string[] = []

  if (writeContext && drafts) {
    await writeDraftFile(intentPath, drafts.projectIntent, { allowExisting: input.force }, written, skipped, errors)
  }
  if (writeGlossary && drafts) {
    await writeDraftFile(glossaryPath, `${JSON.stringify(drafts.projectGlossary, null, 2)}\n`, { allowExisting: input.force }, written, skipped, errors)
  }

  if (writeHarness && harnessScaffold) {
    await mkdir(resolve(projectRoot, "docs"), { recursive: true })
    const selectedHarnessFiles = brownfieldPreserve ? missingHarnessFiles : harnessScaffold.files

    for (const file of selectedHarnessFiles) {
      await writeDraftFile(resolve(projectRoot, file.path), file.content, { allowExisting: input.force }, written, skipped, errors)
    }
  }

  const verifySummary = await buildVerifySummary(projectRoot)

  return [
    written.length > 0 ? written.map((file) => `Written: ${displayPath(projectRoot, file)}`).join("\n") : "No files written.",
    skipped.length > 0 ? skipped.map((file) => `Skipped existing: ${displayPath(projectRoot, file)}`).join("\n") : "",
    errors.length > 0 ? errors.join("\n") : "",
    "",
    verifySummary,
  ]
    .filter((line) => line.length > 0)
    .join("\n")
}

async function synthesizeInitDrafts(
  ctx: ExtensionCommandContext,
  scanResult: InitScanResult,
  projectName: string,
  projectRoot: string,
): Promise<InitDrafts> {
  const model = await resolveModel(ctx)
  if (!model) {
    throw new Error("No model selected and no available authenticated model found for /signum init")
  }

  const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model)
  if (!auth.ok || !auth.apiKey) {
    throw new Error(auth.ok ? `No API key for ${model.provider}` : auth.error)
  }

  const systemPrompt = `${stripFrontmatter(await readFile(initSynthesizerPromptPath, "utf8"))}\n\n## Structured Output Contract\nReturn ONLY valid JSON in this exact shape:\n{\n  "projectIntent": "<full markdown document>",\n  "projectGlossary": {\n    "version": "1.0",\n    "generatedAt": "<ISO timestamp>",\n    "canonicalTerms": [{"term": "...", "definition": "...", "source": "..."}],\n    "aliases": {"alias": "canonical term"}\n  },\n  "coverageSummary": "<brief summary>"\n}\nDo not wrap the JSON in markdown fences. Do not include commentary before or after the JSON.`

  const userMessage: Message = {
    role: "user",
    content: [
      {
        type: "text",
        text: [
          `Project root: ${projectRoot}`,
          "Use the deterministic scan result below as $SIGNALS.",
          JSON.stringify(scanResult, null, 2),
        ].join("\n\n"),
      },
    ],
    timestamp: Date.now(),
  }

  const text = await ctx.ui.custom<string | null>((tui, theme, _kb, done) => {
    const loader = new BorderedLoader(tui, theme, `Synthesizing init drafts with ${model.id}...`)
    loader.onAbort = () => done(null)

    complete(model, { systemPrompt, messages: [userMessage] }, { apiKey: auth.apiKey, headers: auth.headers, signal: loader.signal })
      .then((response) => {
        if (response.stopReason === "aborted") {
          done(null)
          return
        }

        const combined = response.content
          .filter((item): item is { type: "text"; text: string } => item.type === "text")
          .map((item) => item.text)
          .join("\n")

        done(combined)
      })
      .catch((error) => {
        console.error("/signum init synthesis failed", error)
        done(null)
      })

    return loader
  })

  if (text === null) {
    throw new Error("Init synthesis cancelled")
  }

  const parsed = parseJsonObjectFromText(text) as Record<string, unknown>
  const generatedAt = new Date().toISOString()

  const projectIntent = normalizeIntentDraft(parsed.projectIntent, projectName)
  const projectGlossary = normalizeGlossary(parsed.projectGlossary, scanResult, generatedAt)
  const coverageSummary = typeof parsed.coverageSummary === "string" ? parsed.coverageSummary : "Coverage summary unavailable."

  return {
    projectIntent,
    projectGlossary,
    coverageSummary,
  }
}

async function resolveProjectRoot(cwd: string, projectRoot?: string): Promise<string> {
  const resolved = resolve(cwd, projectRoot ?? ".")
  const stat = await lstat(resolved)
  if (!stat.isDirectory()) {
    throw new Error(`Project root is not a directory: ${resolved}`)
  }
  return resolved
}

async function writeDraftFile(
  absolutePath: string,
  content: string,
  options: { allowExisting: boolean },
  written: string[],
  skipped: string[],
  errors: string[],
) {
  try {
    const stat = await lstat(absolutePath)
    if (stat.isSymbolicLink()) {
      errors.push(`ERROR: ${absolutePath} is a symlink. Refusing to overwrite for safety.`)
      return
    }
    if (!options.allowExisting) {
      skipped.push(absolutePath)
      return
    }
  } catch {
    // file does not exist yet
  }

  await mkdir(dirname(absolutePath), { recursive: true })
  await writeFile(absolutePath, content, "utf8")
  written.push(absolutePath)
}

async function buildVerifySummary(projectRoot: string): Promise<string> {
  const glossary = await readJsonIfExists(resolve(projectRoot, "project.glossary.json"))
  const glossaryTerms = Array.isArray(glossary?.canonicalTerms) ? glossary.canonicalTerms.length : 0
  const aliasCount = glossary?.aliases && typeof glossary.aliases === "object" ? Object.keys(glossary.aliases).length : 0

  const intentText = await readTextIfExists(resolve(projectRoot, "project.intent.md"))
  const goalCount = countHeadingOccurrences(intentText, "Goal")
  const capabilityCount = countBulletsInSection(intentText, "Core Capabilities")
  const nonGoalCount = countBulletsInSection(intentText, "Non-Goals")
  const harnessPresent = await countExistingFiles(projectRoot, [
    "AGENTS.md",
    "ARCHITECTURE.md",
    "docs/PLANS.md",
    "docs/RELIABILITY.md",
    "docs/SECURITY.md",
    "docs/QUALITY_SCORE.md",
  ])

  return [
    "VERIFY complete:",
    `  Glossary has ${glossaryTerms} terms, ${aliasCount} aliases`,
    `  Intent covers: ${goalCount} goal, ${capabilityCount} capabilities, ${nonGoalCount} non-goals`,
    `  Harness docs present: ${harnessPresent}/6`,
    "",
    "Next steps:",
    "  1. Review project.intent.md and replace TODO markers where confidence is low",
    "  2. Review AGENTS.md / ARCHITECTURE.md / docs/*.md and replace TODOs with repo-specific facts",
    "  3. Commit the generated files to your repository",
    "  4. Contractor will now use project context automatically",
  ].join("\n")
}

function buildScanSummary(
  scanResult: InitScanResult,
  options: {
    harness: boolean
    harnessScaffold: HarnessScaffoldResult | null
    intentExists: boolean
    glossaryExists: boolean
    projectRoot: string
  },
): string {
  const signals = scanResult.signals ?? {}

  return [
    `SCAN complete for ${options.projectRoot}. Found signals:`,
    `  - Authoritative docs: ${hasSignal(signals.authoritative_docs) ? "yes" : "no"}`,
    `  - CLAUDE.md: ${hasSignal(signals.claude_md) ? "yes" : "no"}`,
    `  - README.md: ${hasSignal(signals.readme) ? "yes" : "no"}`,
    `  - Package manifest: ${hasSignal(signals.package_json) || hasSignal(signals.pyproject_toml) || hasSignal(signals.cargo_toml) ? "yes" : "no"}`,
    `  - Git history (6 months): ${countNonEmptyLines(signals.git_recent)} commits`,
    `  - Public entrypoints: ${countEntrypoints(signals.entrypoints)} found`,
    `  - Existing glossary: ${options.glossaryExists ? "yes" : "no"}`,
    `  - Existing intent: ${options.intentExists ? "yes" : "no"}`,
    options.harness && options.harnessScaffold ? `  - Harness docs missing: ${options.harnessScaffold.missingCount}` : "",
    options.harness && options.harnessScaffold ? `  - Harness docs already present: ${options.harnessScaffold.existingCount}` : "",
  ]
    .filter((line) => line.length > 0)
    .join("\n")
}

function buildDraftMessage(options: {
  drafts: InitDrafts | null
  harnessFiles: HarnessFileDraft[]
  brownfieldPreserve: boolean
  harness: boolean
}): string {
  const sections: string[] = []

  if (options.drafts) {
    sections.push(buildSingleDraftPreview("project.intent.md", options.drafts.projectIntent))
    sections.push(buildSingleDraftPreview("project.glossary.json", `${JSON.stringify(options.drafts.projectGlossary, null, 2)}\n`))
    sections.push(`Coverage summary:\n${options.drafts.coverageSummary}`)
  }

  if (options.harness) {
    for (const file of options.harnessFiles) {
      sections.push(buildSingleDraftPreview(file.path, file.content))
    }
  }

  if (sections.length === 0 && options.brownfieldPreserve) {
    return "No draft content to show."
  }

  return sections.join("\n\n")
}

function buildSingleDraftPreview(path: string, content: string): string {
  return [
    "════════════════════════════════════════",
    `DRAFT: ${path}`,
    "════════════════════════════════════════",
    content,
  ].join("\n")
}

async function promptForInitDecision(
  ctx: ExtensionCommandContext,
  options: { harness: boolean; brownfieldPreserve: boolean },
): Promise<"accept" | "edit-intent" | "edit-glossary" | "intent-only" | "context-only" | "harness-only" | "cancel"> {
  if (options.brownfieldPreserve) {
    const choice = await ctx.ui.select("Review the harness drafts above.", [
      "1. Accept and write missing harness docs",
      "2. Cancel (write nothing)",
    ])
    return choice?.startsWith("1.") ? "accept" : "cancel"
  }

  if (!options.harness) {
    const choice = await ctx.ui.select("Review the drafts above.", [
      "1. Accept and write both files",
      "2. Edit intent first, then write",
      "3. Edit glossary first, then write",
      "4. Accept intent only, skip glossary",
      "5. Cancel (write nothing)",
    ])

    if (!choice || choice.startsWith("5.")) return "cancel"
    if (choice.startsWith("2.")) return "edit-intent"
    if (choice.startsWith("3.")) return "edit-glossary"
    if (choice.startsWith("4.")) return "intent-only"
    return "accept"
  }

  const choice = await ctx.ui.select("Review the drafts above.", [
    "1. Accept and write all drafts",
    "2. Edit intent first, then write all drafts",
    "3. Edit glossary first, then write all drafts",
    "4. Accept context files only, skip harness docs",
    "5. Accept harness docs only, skip context files",
    "6. Cancel (write nothing)",
  ])

  if (!choice || choice.startsWith("6.")) return "cancel"
  if (choice.startsWith("2.")) return "edit-intent"
  if (choice.startsWith("3.")) return "edit-glossary"
  if (choice.startsWith("4.")) return "context-only"
  if (choice.startsWith("5.")) return "harness-only"
  return "accept"
}

async function runJsonScript(pi: ExtensionAPI, scriptPath: string, args: string[]) {
  const result = await pi.exec("bash", [scriptPath, ...args])
  if (result.code !== 0) {
    throw new Error(result.stderr || result.stdout || `Script failed: ${scriptPath}`)
  }
  return parseJsonObjectFromText(result.stdout)
}

function stripFrontmatter(markdown: string): string {
  return markdown.replace(/^---\n[\s\S]*?\n---\n?/, "")
}

async function resolveModel(ctx: ExtensionCommandContext): Promise<Model | undefined> {
  if (ctx.model) {
    return ctx.model
  }

  const available = await ctx.modelRegistry.getAvailable()
  return available[0]
}

function normalizeIntentDraft(value: unknown, projectName: string): string {
  if (typeof value !== "string" || !value.trim()) {
    return minimalIntentDraft(projectName)
  }

  const normalized = value.endsWith("\n") ? value : `${value}\n`
  if (!/^[#]\s+/m.test(normalized)) {
    return minimalIntentDraft(projectName)
  }
  if (!/^##\s+Goal\b/m.test(normalized)) {
    return minimalIntentDraft(projectName)
  }
  return normalized
}

function minimalIntentDraft(projectName: string): string {
  return [
    `# ${projectName} — Project Intent`,
    "<!-- generated by /signum init, review and edit before committing -->",
    "",
    "## Goal",
    "<!-- evidence: synthesis fallback -->",
    "<!-- confidence: low -->",
    "- TODO: Describe the project goal.",
    "",
    "## Core Capabilities",
    "<!-- evidence: synthesis fallback -->",
    "<!-- confidence: low -->",
    "- TODO: List the core capabilities.",
    "",
    "## Non-Goals",
    "<!-- evidence: none found -->",
    "<!-- confidence: low -->",
    "- TODO: No explicit non-goals detected. Review and add manually.",
  ].join("\n")
}

function normalizeGlossary(value: unknown, scanResult: InitScanResult, generatedAt: string): GlossaryDocument {
  let parsed = value
  if (typeof value === "string") {
    parsed = parseJsonObjectFromText(value)
  }

  const generated = parsed && typeof parsed === "object" ? (parsed as Partial<GlossaryDocument>) : {}
  const existing = parseExistingGlossary(scanResult)

  const canonicalTerms = mergeCanonicalTerms(existing.canonicalTerms ?? [], Array.isArray(generated.canonicalTerms) ? generated.canonicalTerms : [])
  const aliases = {
    ...(generated.aliases && typeof generated.aliases === "object" ? generated.aliases : {}),
    ...(existing.aliases ?? {}),
  }

  return {
    version: typeof generated.version === "string" ? generated.version : existing.version ?? "1.0",
    generatedAt,
    canonicalTerms,
    aliases,
  }
}

function parseExistingGlossary(scanResult: InitScanResult): Partial<GlossaryDocument> {
  const raw = scanResult.existingFiles?.glossary?.content
  if (!raw) return {}
  try {
    return JSON.parse(raw)
  } catch {
    return {}
  }
}

function mergeCanonicalTerms(existing: unknown[], generated: unknown[]): GlossaryTerm[] {
  const merged = new Map<string, GlossaryTerm>()
  for (const item of [...existing, ...generated]) {
    if (!item || typeof item !== "object") continue
    const candidate = item as GlossaryTerm
    if (!candidate.term || typeof candidate.term !== "string") continue
    if (merged.has(candidate.term)) continue
    merged.set(candidate.term, {
      term: candidate.term,
      definition: typeof candidate.definition === "string" ? candidate.definition : undefined,
      source: typeof candidate.source === "string" ? candidate.source : undefined,
    })
  }
  return [...merged.values()].sort((left, right) => left.term.localeCompare(right.term))
}

function parseJsonObjectFromText(text: string): unknown {
  const trimmed = text.trim()
  if (!trimmed) {
    throw new Error("Expected JSON output, got empty text")
  }

  const fenceMatch = trimmed.match(/^```(?:json)?\n([\s\S]*?)\n```$/)
  const candidate = fenceMatch ? fenceMatch[1].trim() : trimmed

  try {
    return JSON.parse(candidate)
  } catch {
    const start = candidate.indexOf("{")
    const end = candidate.lastIndexOf("}")
    if (start >= 0 && end > start) {
      return JSON.parse(candidate.slice(start, end + 1))
    }
    throw new Error("Could not parse JSON output from init synthesis")
  }
}

function hasSignal(value?: string): boolean {
  return Boolean(value && value.trim().length > 0)
}

function countNonEmptyLines(value?: string): number {
  if (!value) return 0
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0).length
}

function countEntrypoints(value?: string): number {
  if (!value) return 0
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("===")).length
}

function countHeadingOccurrences(markdown: string, sectionName: string): number {
  const pattern = new RegExp(`^##\\s+${escapeRegExp(sectionName)}\\b`, "gm")
  return [...markdown.matchAll(pattern)].length
}

function countBulletsInSection(markdown: string, sectionName: string): number {
  const section = extractSection(markdown, sectionName)
  return section
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("- ")).length
}

function extractSection(markdown: string, sectionName: string): string {
  const pattern = new RegExp(`^##\\s+${escapeRegExp(sectionName)}\\b([\\s\\S]*?)(?=^##\\s+|$)`, "m")
  const match = markdown.match(pattern)
  return match?.[1] ?? ""
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await lstat(path)
    return true
  } catch {
    return false
  }
}

async function readJsonIfExists(path: string): Promise<any | null> {
  try {
    const raw = await readFile(path, "utf8")
    return JSON.parse(raw)
  } catch {
    return null
  }
}

async function readTextIfExists(path: string): Promise<string> {
  try {
    return await readFile(path, "utf8")
  } catch {
    return ""
  }
}

async function countExistingFiles(projectRoot: string, paths: string[]): Promise<number> {
  let count = 0
  for (const relativePath of paths) {
    if (await pathExists(resolve(projectRoot, relativePath))) {
      count += 1
    }
  }
  return count
}

function displayPath(projectRoot: string, absolutePath: string): string {
  return absolutePath.startsWith(projectRoot) ? absolutePath.slice(projectRoot.length + 1) : absolutePath
}
