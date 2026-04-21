export const SIGNUM_USAGE = [
  "Usage:",
  "  /signum explain",
  "  /signum init [--force] [--harness] [--project-root <path>]",
  "  /signum archive [contractId]",
  "  /signum close [contractId]",
  "  /signum <task>",
].join("\n")

export type SignumParsedCommand =
  | { kind: "explain" }
  | { kind: "init"; force: boolean; harness: boolean; projectRoot?: string }
  | { kind: "archive"; contractId?: string }
  | { kind: "close"; contractId?: string }
  | { kind: "task"; task: string }

export type SignumParseResult =
  | { ok: true; command: SignumParsedCommand }
  | { ok: false; message: string }

interface TokenizeResult {
  ok: boolean
  tokens?: string[]
  message?: string
}

export function parseSignumArgs(rawArgs: string): SignumParseResult {
  const normalized = rawArgs.trim()
  if (normalized.length === 0) {
    return {
      ok: false,
      message: `Missing command or task.\n\n${SIGNUM_USAGE}`,
    }
  }

  const tokenized = tokenizeArgs(normalized)
  if (!tokenized.ok || !tokenized.tokens) {
    return {
      ok: false,
      message: `${tokenized.message ?? "Could not parse arguments."}\n\n${SIGNUM_USAGE}`,
    }
  }

  const [head, ...tail] = tokenized.tokens
  const command = head.toLowerCase()

  if (command === "explain") {
    if (tail.length > 0) {
      return {
        ok: false,
        message: `The explain subcommand does not accept additional arguments.\n\n${SIGNUM_USAGE}`,
      }
    }
    return { ok: true, command: { kind: "explain" } }
  }

  if (command === "init") {
    return parseInitArgs(tail)
  }

  if (command === "archive") {
    return parseSingleOptionalArgumentCommand("archive", tail)
  }

  if (command === "close") {
    return parseSingleOptionalArgumentCommand("close", tail)
  }

  return {
    ok: true,
    command: {
      kind: "task",
      task: normalized,
    },
  }
}

function parseSingleOptionalArgumentCommand(
  command: "archive" | "close",
  tail: string[],
): SignumParseResult {
  if (tail.length > 1) {
    return {
      ok: false,
      message: `Ambiguous ${command} invocation. The ${command} subcommand accepts at most one contractId argument.\n\n${SIGNUM_USAGE}`,
    }
  }

  if (tail.length === 1 && !looksLikeContractId(tail[0])) {
    return {
      ok: false,
      message: `Ambiguous ${command} invocation: "${command} ${tail[0]}" does not look like a Signum contract ID. If you meant the ${command} subcommand, pass a contractId like sig-20260314-a1b2. If you meant a task, phrase it without the reserved leading word "${command}".\n\n${SIGNUM_USAGE}`,
    }
  }

  return {
    ok: true,
    command: {
      kind: command,
      contractId: tail[0],
    },
  }
}

function parseInitArgs(tokens: string[]): SignumParseResult {
  let force = false
  let harness = false
  let projectRoot: string | undefined

  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index]

    if (token === "--force") {
      if (force) {
        return {
          ok: false,
          message: `Duplicate flag: --force\n\n${SIGNUM_USAGE}`,
        }
      }
      force = true
      continue
    }

    if (token === "--harness") {
      if (harness) {
        return {
          ok: false,
          message: `Duplicate flag: --harness\n\n${SIGNUM_USAGE}`,
        }
      }
      harness = true
      continue
    }

    if (token === "--project-root") {
      if (projectRoot !== undefined) {
        return {
          ok: false,
          message: `Duplicate flag: --project-root\n\n${SIGNUM_USAGE}`,
        }
      }

      const value = tokens[index + 1]
      if (!value || value.startsWith("--")) {
        return {
          ok: false,
          message: `The --project-root flag requires a path value.\n\n${SIGNUM_USAGE}`,
        }
      }

      projectRoot = value
      index++
      continue
    }

    if (token.startsWith("--")) {
      return {
        ok: false,
        message: `Unknown init flag: ${token}\n\n${SIGNUM_USAGE}`,
      }
    }

    return {
      ok: false,
      message: `Unexpected positional argument for init: ${token}\n\n${SIGNUM_USAGE}`,
    }
  }

  return {
    ok: true,
    command: {
      kind: "init",
      force,
      harness,
      projectRoot,
    },
  }
}

function looksLikeContractId(value: string): boolean {
  return /^sig-[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)
}

export function tokenizeArgs(input: string): TokenizeResult {
  const tokens: string[] = []
  let current = ""
  let quote: "'" | '"' | null = null
  let escaping = false

  for (let index = 0; index < input.length; index++) {
    const char = input[index]

    if (escaping) {
      current += char
      escaping = false
      continue
    }

    if (char === "\\" && quote !== "'") {
      escaping = true
      continue
    }

    if (quote) {
      if (char === quote) {
        quote = null
      } else {
        current += char
      }
      continue
    }

    if (char === '"' || char === "'") {
      quote = char
      continue
    }

    if (/\s/.test(char)) {
      if (current.length > 0) {
        tokens.push(current)
        current = ""
      }
      continue
    }

    current += char
  }

  if (escaping) {
    current += "\\"
  }

  if (quote) {
    return {
      ok: false,
      message: `Unterminated ${quote === '"' ? "double" : "single"} quote in arguments.`,
    }
  }

  if (current.length > 0) {
    tokens.push(current)
  }

  return { ok: true, tokens }
}
