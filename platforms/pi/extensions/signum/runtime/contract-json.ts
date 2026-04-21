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

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index]

    if (!inString) {
      output += char
      if (char === '"') {
        inString = true
      }
      continue
    }

    if (char === '"') {
      output += char
      inString = false
      continue
    }

    if (char === "\\") {
      const next = text[index + 1]
      if (!next) {
        output += "\\\\"
        continue
      }

      if (/["\\/bfnrt]/.test(next)) {
        output += `\\${next}`
        index += 1
        continue
      }

      if (next === "u" && /^[0-9a-fA-F]{4}$/.test(text.slice(index + 2, index + 6))) {
        output += text.slice(index, index + 6)
        index += 5
        continue
      }

      output += "\\\\"
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
