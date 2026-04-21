import { access, lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises"
import { dirname, relative, resolve, sep } from "node:path"

import {
  createBashToolDefinition,
  createEditToolDefinition,
  createLocalBashOperations,
  createReadToolDefinition,
  createWriteToolDefinition,
  type ToolDefinition,
} from "@mariozechner/pi-coding-agent"

export interface ContractPolicy {
  schemaVersion: string
  generatedFrom: string
  riskLevel: "low" | "medium" | "high"
  allowed_tools: string[]
  denied_tools: string[]
  bash_deny_patterns: string[]
  allowed_paths: string[]
  allow_new_files_under: string[]
  removal_paths: string[]
  max_files_changed: number
  network_access: boolean
}

export interface PolicyViolation {
  type: "path" | "bash" | "limit" | "network"
  tool: string
  path?: string
  command?: string
  reason: string
  timestamp: string
}

export interface PolicyToolset {
  builtInToolNames: string[]
  customTools: ToolDefinition[]
  getViolations(): PolicyViolation[]
  getTouchedFiles(): string[]
}

interface Tracker {
  touchedFiles: Set<string>
  violations: PolicyViolation[]
}

const READABLE_SYSTEM_PATHS = [
  ".signum",
  "project.intent.md",
  "project.glossary.json",
  "modules.yaml",
  "README.md",
  "package.json",
  "tsconfig.json",
  "pyproject.toml",
  "Cargo.toml",
  ".gitignore",
]

const BASH_MUTATION_PATTERNS = [
  /(^|\s)mv\s/i,
  /(^|\s)cp\s/i,
  /(^|\s)touch\s/i,
  /(^|\s)mkdir\s/i,
  /(^|\s)rmdir\s/i,
  /(^|\s)tee\b/i,
  /(^|\s)git\s+(apply|checkout|restore|reset|clean|add|commit)\b/i,
  /(^|\s)(npm|pnpm|yarn)\s+(install|add|remove|update)\b/i,
  /(^|\s)sed\s+-i\b/i,
  /(^|\s)perl\s+-i\b/i,
  />|>>/,
]

export function deriveExecutionPolicy(contract: Record<string, any>): ContractPolicy {
  const riskLevel = (contract.riskLevel ?? "low") as ContractPolicy["riskLevel"]
  const maxFiles = riskLevel === "high" ? 10 : riskLevel === "medium" ? 15 : 25

  return {
    schemaVersion: "1.0",
    generatedFrom: contract.contractId ?? "unknown",
    riskLevel,
    allowed_tools: ["read", "write", "edit", "grep", "find", "ls", "bash"],
    denied_tools: ["WebSearch", "WebFetch", "Agent", "Task"],
    bash_deny_patterns: [
      String.raw`rm\s+-[rf]+\s+/`,
      String.raw`git\s+push\s+--force`,
      String.raw`curl[^|]*\|\s*sh`,
      String.raw`eval\s+\$`,
      String.raw`dd\s+if=`,
      String.raw`mkfs\.`,
      String.raw`>\s*/dev/sd`,
    ],
    allowed_paths: collectAllowedPaths(contract),
    allow_new_files_under: collectAllowNewDirectories(contract),
    removal_paths: sanitizePaths((contract.removals ?? []).map((item: { path?: string }) => item.path ?? "")),
    max_files_changed: maxFiles,
    network_access: false,
  }
}

export function createPolicyAwareEngineerTools(projectRoot: string, policy: ContractPolicy): PolicyToolset {
  const tracker: Tracker = {
    touchedFiles: new Set<string>(),
    violations: [],
  }

  const localBash = createLocalBashOperations()

  const readTool = createReadToolDefinition(projectRoot, {
    operations: {
      async access(absolutePath) {
        assertReadablePath(projectRoot, absolutePath, policy, tracker, "read")
        await access(absolutePath)
      },
      async readFile(absolutePath) {
        assertReadablePath(projectRoot, absolutePath, policy, tracker, "read")
        return readFile(absolutePath)
      },
    },
  })

  const writeTool = createWriteToolDefinition(projectRoot, {
    operations: {
      async mkdir(dir) {
        await mkdir(dir, { recursive: true })
      },
      async writeFile(absolutePath, content) {
        await assertMutationPath(projectRoot, absolutePath, policy, tracker, "write")
        await mkdir(dirname(absolutePath), { recursive: true })
        await writeFile(absolutePath, content, "utf8")
      },
    },
  })

  const editTool = createEditToolDefinition(projectRoot, {
    operations: {
      async access(absolutePath) {
        await assertMutationPath(projectRoot, absolutePath, policy, tracker, "edit")
        const stat = await lstat(absolutePath)
        if (stat.isSymbolicLink()) {
          throw violationError(tracker, {
            type: "path",
            tool: "edit",
            path: projectRelative(projectRoot, absolutePath),
            reason: "Editing symlinks is not allowed by runtime policy",
            timestamp: new Date().toISOString(),
          })
        }
      },
      async readFile(absolutePath) {
        await assertMutationPath(projectRoot, absolutePath, policy, tracker, "edit")
        return readFile(absolutePath)
      },
      async writeFile(absolutePath, content) {
        await assertMutationPath(projectRoot, absolutePath, policy, tracker, "edit")
        await writeFile(absolutePath, content, "utf8")
      },
    },
  })

  const bashTool = createBashToolDefinition(projectRoot, {
    operations: {
      async exec(command, cwd, options) {
        assertBashAllowed(projectRoot, command, policy, tracker)
        return localBash.exec(command, cwd, options)
      },
    },
  })

  return {
    builtInToolNames: ["grep", "find", "ls"],
    customTools: [readTool, writeTool, editTool, bashTool],
    getViolations: () => [...tracker.violations],
    getTouchedFiles: () => [...tracker.touchedFiles].sort(),
  }
}

function collectAllowedPaths(contract: Record<string, any>): string[] {
  const direct = sanitizePaths(contract.inScope ?? [])
  const extracted = extractLikelyPaths(contract.inScope ?? [])
  const verifyPaths = extractVerifyPaths(contract.acceptanceCriteria ?? [])
  return [...new Set([...direct.filter(looksLikePath), ...extracted, ...verifyPaths])]
}

function collectAllowNewDirectories(contract: Record<string, any>): string[] {
  const direct = sanitizePaths(contract.allowNewFilesUnder ?? [])
  const extracted = extractLikelyPaths(contract.allowNewFilesUnder ?? [])
  return [...new Set([...direct.filter(looksLikePath), ...extracted])]
}

function sanitizePaths(paths: string[]): string[] {
  return paths
    .map((path) => String(path ?? "").replace(/ \(.*$/, "").trim())
    .filter(Boolean)
}

function extractLikelyPaths(values: unknown[]): string[] {
  const found = new Set<string>()
  const pattern = /\b(?:\.?\/?[A-Za-z0-9_@-]+(?:\/[A-Za-z0-9_.@-]+)*\/?|[A-Za-z0-9_.@-]+\.[A-Za-z0-9]+)\b/g
  for (const value of values) {
    const text = String(value ?? "")
    for (const match of text.matchAll(pattern)) {
      const candidate = match[0].replace(/^\.\//, "")
      if (!looksLikePath(candidate)) continue
      found.add(candidate)
    }
  }
  return [...found]
}

function extractVerifyPaths(criteria: Array<{ verify?: unknown }>): string[] {
  const found = new Set<string>()
  for (const criterion of criteria) {
    const verify = criterion?.verify as Record<string, any> | undefined
    const steps = Array.isArray(verify?.steps) ? verify.steps : []
    for (const step of steps) {
      for (const key of ["path", "docPath", "sourcePath"] as const) {
        const value = step?.[key]
        if (typeof value === "string" && looksLikePath(value)) {
          found.add(value.replace(/^\.\//, ""))
        }
      }
      if (Array.isArray(step?.sources)) {
        for (const value of step.sources) {
          if (typeof value === "string" && looksLikePath(value)) {
            found.add(value.replace(/^\.\//, ""))
          }
        }
      }
      if (Array.isArray(step?.paths)) {
        for (const value of step.paths) {
          if (typeof value === "string" && looksLikePath(value)) {
            found.add(value.replace(/^\.\//, ""))
          }
        }
      }
      if (Array.isArray(step?.allowed)) {
        for (const value of step.allowed) {
          if (typeof value === "string" && looksLikePath(value)) {
            found.add(value.replace(/^\.\//, ""))
          }
        }
      }
    }
  }
  return [...found]
}

function looksLikePath(value: string): boolean {
  return /[/.]/.test(value) && !/^\.[A-Za-z0-9]+$/.test(value) && !/\s/.test(value)
}

function assertReadablePath(projectRoot: string, absolutePath: string, policy: ContractPolicy, tracker: Tracker, tool: string) {
  const normalized = normalizeExistingPath(projectRoot, absolutePath)
  if (!normalized.startsWith(projectRoot)) {
    throw violationError(tracker, {
      type: "path",
      tool,
      path: absolutePath,
      reason: "Reads must stay within the project root",
      timestamp: new Date().toISOString(),
    })
  }

  const rel = projectRelative(projectRoot, normalized)
  if (isReadableSystemPath(rel)) return
  if (matchesAllowedPath(rel, policy.allowed_paths)) return
  if (matchesAllowedDir(rel, policy.allow_new_files_under)) return

  throw violationError(tracker, {
    type: "path",
    tool,
    path: rel,
    reason: "Read path is outside the engineer runtime policy",
    timestamp: new Date().toISOString(),
  })
}

async function assertMutationPath(projectRoot: string, absolutePath: string, policy: ContractPolicy, tracker: Tracker, tool: string) {
  const exists = await fileExists(absolutePath)
  const normalized = exists ? await normalizePath(projectRoot, absolutePath) : resolve(projectRoot, absolutePath)

  if (!normalized.startsWith(projectRoot)) {
    throw violationError(tracker, {
      type: "path",
      tool,
      path: absolutePath,
      reason: "Mutations must stay within the project root",
      timestamp: new Date().toISOString(),
    })
  }

  const rel = projectRelative(projectRoot, normalized)
  const allowedExisting = exists && matchesAllowedPath(rel, policy.allowed_paths)
  const allowedNew = !exists && matchesAllowedDir(rel, policy.allow_new_files_under)

  if (!allowedExisting && !allowedNew) {
    throw violationError(tracker, {
      type: "path",
      tool,
      path: rel,
      reason: exists
        ? "Existing file is outside inScope"
        : "New file is outside allowNewFilesUnder",
      timestamp: new Date().toISOString(),
    })
  }

  trackFileMutation(tracker, rel, policy, tool)
}

function assertBashAllowed(projectRoot: string, command: string, policy: ContractPolicy, tracker: Tracker) {
  if (!policy.network_access && /\b(curl|wget|fetch|https?:\/\/|ssh\b|scp\b|rsync\b)\b/i.test(command)) {
    throw violationError(tracker, {
      type: "network",
      tool: "bash",
      command,
      reason: "Networked bash commands are disabled by runtime policy",
      timestamp: new Date().toISOString(),
    })
  }

  for (const pattern of policy.bash_deny_patterns) {
    if (new RegExp(pattern, "i").test(command)) {
      throw violationError(tracker, {
        type: "bash",
        tool: "bash",
        command,
        reason: `Denied bash pattern matched: ${pattern}`,
        timestamp: new Date().toISOString(),
      })
    }
  }

  const trimmed = command.trim()
  if (/^rm\b/i.test(trimmed)) {
    const targets = parseRmTargets(trimmed)
    if (targets.length === 0 || !targets.every((target) => matchesAllowedRemoval(projectRoot, target, policy.removal_paths))) {
      throw violationError(tracker, {
        type: "bash",
        tool: "bash",
        command,
        reason: "rm is only allowed for declared removal targets",
        timestamp: new Date().toISOString(),
      })
    }

    for (const target of targets) {
      const rel = projectRelative(projectRoot, resolve(projectRoot, target))
      trackFileMutation(tracker, rel, policy, "bash")
    }
    return
  }

  for (const pattern of BASH_MUTATION_PATTERNS) {
    if (pattern.test(command)) {
      throw violationError(tracker, {
        type: "bash",
        tool: "bash",
        command,
        reason: "Mutating bash commands are disabled; use edit/write tools instead",
        timestamp: new Date().toISOString(),
      })
    }
  }
}

function parseRmTargets(command: string): string[] {
  return command
    .split(/\s+/)
    .slice(1)
    .filter((token) => token.length > 0 && !token.startsWith("-"))
}

function matchesAllowedRemoval(projectRoot: string, target: string, removalPaths: string[]): boolean {
  const rel = projectRelative(projectRoot, resolve(projectRoot, target))
  return removalPaths.some((path) => rel === path || rel.startsWith(`${path}${sep}`) || path.startsWith(`${rel}${sep}`))
}

function trackFileMutation(tracker: Tracker, rel: string, policy: ContractPolicy, tool: string) {
  if (!tracker.touchedFiles.has(rel) && tracker.touchedFiles.size + 1 > policy.max_files_changed) {
    throw violationError(tracker, {
      type: "limit",
      tool,
      path: rel,
      reason: `Policy allows at most ${policy.max_files_changed} changed files`,
      timestamp: new Date().toISOString(),
    })
  }
  tracker.touchedFiles.add(rel)
}

function violationError(tracker: Tracker, violation: PolicyViolation): Error {
  tracker.violations.push(violation)
  return new Error(`[POLICY_VIOLATION] ${violation.reason}`)
}

function matchesAllowedPath(rel: string, allowedPaths: string[]): boolean {
  return allowedPaths.some((path) => rel === path || rel.startsWith(`${path}${sep}`) || path.startsWith(`${rel}${sep}`))
}

function matchesAllowedDir(rel: string, allowedDirs: string[]): boolean {
  return allowedDirs.some((dir) => rel === dir || rel.startsWith(`${dir}${sep}`))
}

function isReadableSystemPath(rel: string): boolean {
  return READABLE_SYSTEM_PATHS.some((path) => rel === path || rel.startsWith(`${path}${sep}`))
}

function projectRelative(projectRoot: string, absolutePath: string): string {
  const rel = relative(projectRoot, absolutePath)
  return rel === "" ? "." : rel
}

async function normalizePath(projectRoot: string, inputPath: string): Promise<string> {
  const resolved = resolve(projectRoot, stripLeadingAt(inputPath))
  try {
    return await realpath(resolved)
  } catch {
    return resolved
  }
}

function normalizeExistingPath(projectRoot: string, inputPath: string): string {
  return resolve(projectRoot, stripLeadingAt(inputPath))
}

function stripLeadingAt(path: string): string {
  return path.startsWith("@") ? path.slice(1) : path
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await lstat(path)
    return true
  } catch {
    return false
  }
}
