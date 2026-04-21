import { readFile } from "node:fs/promises"
import { resolve } from "node:path"

import type { Model } from "@mariozechner/pi-ai"
import {
  AuthStorage,
  createAgentSession,
  createExtensionRuntime,
  type AgentSessionEvent,
  type ResourceLoader,
  SessionManager,
  SettingsManager,
  type ToolDefinition,
  parseFrontmatter,
  stripFrontmatter,
} from "@mariozechner/pi-coding-agent"

import type { SignumRole } from "../models.ts"
import { piAgentsRoot } from "../paths.ts"

export interface RoleToolEvent {
  type: string
  toolName?: string
  toolCallId?: string
  args?: unknown
  result?: unknown
  isError?: boolean
}

export interface RoleRunResult {
  role: SignumRole
  model: string
  finalText: string
  events: RoleToolEvent[]
}

export interface RoleRunRequest {
  role: SignumRole
  projectRoot: string
  prompt: string
  model: Model
  toolNames?: string[]
  customTools?: ToolDefinition[]
}

export interface RoleSessionRunner {
  run(request: RoleRunRequest): Promise<RoleRunResult>
}

interface PromptAssetFrontmatter {
  name?: string
  description?: string
  model?: string
  tools?: string | string[]
}

interface RolePromptAsset {
  body: string
  tools: string[]
  preferredModelId?: string
}

export class SdkRoleSessionRunner implements RoleSessionRunner {
  async run(request: RoleRunRequest): Promise<RoleRunResult> {
    const promptAsset = await loadRolePromptAsset(request.role)
    const authStorage = AuthStorage.create()

    const toolNames = request.toolNames ?? promptAsset.tools
    const promptToolNames = [...new Set([...toolNames, ...(request.customTools ?? []).map((tool) => tool.name)])]

    const resourceLoader: ResourceLoader = {
      getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
      getSkills: () => ({ skills: [], diagnostics: [] }),
      getPrompts: () => ({ prompts: [], diagnostics: [] }),
      getThemes: () => ({ themes: [], diagnostics: [] }),
      getAgentsFiles: () => ({ agentsFiles: [] }),
      getSystemPrompt: () => buildRoleSystemPrompt(promptAsset.body, promptToolNames),
      getAppendSystemPrompt: () => [],
      extendResources: () => {},
      reload: async () => {},
    }

    const { session } = await createAgentSession({
      cwd: request.projectRoot,
      model: request.model,
      thinkingLevel: "off",
      authStorage,
      resourceLoader,
      tools: toolNames,
      customTools: request.customTools,
      sessionManager: SessionManager.inMemory(),
      settingsManager: SettingsManager.inMemory({
        compaction: { enabled: false },
        retry: { enabled: false },
      }),
    })

    const events: RoleToolEvent[] = []
    const unsubscribe = session.subscribe((event: AgentSessionEvent) => {
      if (event.type === "tool_execution_start") {
        events.push({
          type: event.type,
          toolName: event.toolName,
          toolCallId: event.toolCallId,
          args: event.args,
        })
      }
      if (event.type === "tool_execution_end") {
        events.push({
          type: event.type,
          toolName: event.toolName,
          toolCallId: event.toolCallId,
          result: event.result,
          isError: event.isError,
        })
      }
    })

    try {
      await session.prompt(request.prompt)
      const finalText = extractLastAssistantText(session.messages)

      return {
        role: request.role,
        model: `${request.model.provider}/${request.model.id}`,
        finalText,
        events,
      }
    } finally {
      unsubscribe()
      session.dispose()
    }
  }
}

export async function loadRolePromptAsset(role: SignumRole): Promise<RolePromptAsset> {
  const promptPath = resolve(piAgentsRoot, `${role}.md`)
  const raw = await readFile(promptPath, "utf8")
  const { frontmatter } = parseFrontmatter<PromptAssetFrontmatter>(raw)

  return {
    body: stripFrontmatter(raw),
    tools: normalizePromptTools(frontmatter.tools),
    preferredModelId: frontmatter.model,
  }
}

function normalizePromptTools(value: PromptAssetFrontmatter["tools"]): string[] {
  const rawItems = Array.isArray(value)
    ? value
    : typeof value === "string"
      ? value
          .replace(/^\[/, "")
          .replace(/\]$/, "")
          .split(",")
      : []

  const normalized = new Set<string>()
  for (const item of rawItems) {
    const lower = item.trim().toLowerCase()
    if (!lower) continue
    if (lower === "glob") {
      normalized.add("find")
      continue
    }
    normalized.add(lower)
  }

  if (normalized.size === 0) {
    return ["read", "grep", "find", "ls", "bash"]
  }

  return [...normalized]
}

function buildRoleSystemPrompt(body: string, tools: string[]): string {
  return [
    "You are an AI assistant accessed via the pi SDK.",
    "",
    `Available tools: ${tools.join(", ")}`,
    "Guidelines:",
    "- Use read to inspect files.",
    "- Use grep, find, and ls for deterministic discovery.",
    "- Use edit for precise updates and write for full-file writes.",
    "- Use bash for repository-local commands when file tools are insufficient.",
    "- Be concise and prefer structured artifacts over long prose.",
    "",
    body.trim(),
  ].join("\n")
}

function extractLastAssistantText(messages: Array<{ role?: string; content?: Array<{ type: string; text?: string }> }>): string {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index]
    if (message.role !== "assistant") continue
    const text = (message.content ?? [])
      .filter((part) => part.type === "text")
      .map((part) => part.text ?? "")
      .join("\n")
      .trim()
    if (text) return text
  }
  return ""
}
