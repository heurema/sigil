export function parsePossiblyBrokenJsonObject(text: string): Record<string, unknown> {
  const direct = tryParseJsonObject(text)
  if (direct) return direct

  const repaired = escapeControlCharactersInStrings(text)
  const repairedParsed = tryParseJsonObject(repaired)
  if (repairedParsed) return repairedParsed

  throw new Error("invalid JSON object")
}

export function escapeControlCharactersInStrings(text: string): string {
  let output = ""
  let inString = false
  let escaped = false

  for (const char of text) {
    if (!inString) {
      output += char
      if (char === '"') {
        inString = true
      }
      continue
    }

    if (escaped) {
      output += char
      escaped = false
      continue
    }

    if (char === "\\") {
      output += char
      escaped = true
      continue
    }

    if (char === '"') {
      output += char
      inString = false
      continue
    }

    if (char === "\n") {
      output += "\\n"
      continue
    }
    if (char === "\r") {
      output += "\\r"
      continue
    }
    if (char === "\t") {
      output += "\\t"
      continue
    }

    output += char
  }

  return output
}

function tryParseJsonObject(text: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(text) as unknown
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return null
    }
    return parsed as Record<string, unknown>
  } catch {
    return null
  }
}
