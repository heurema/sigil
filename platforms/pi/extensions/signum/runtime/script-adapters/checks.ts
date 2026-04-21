import { readFile } from "node:fs/promises"
import { createHash } from "node:crypto"

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent"

export async function runJsonScript(
  pi: ExtensionAPI,
  scriptPath: string,
  args: string[],
): Promise<unknown> {
  const result = await pi.exec("bash", [scriptPath, ...args])
  if (result.code !== 0) {
    throw new Error(result.stderr || result.stdout || `Script failed: ${scriptPath}`)
  }
  return JSON.parse(result.stdout)
}

export async function runTextScript(
  pi: ExtensionAPI,
  scriptPath: string,
  args: string[],
): Promise<{ ok: boolean; output: string }> {
  const result = await pi.exec("bash", [scriptPath, ...args])
  return {
    ok: result.code === 0,
    output: [result.stdout, result.stderr].filter(Boolean).join("\n").trim(),
  }
}

export function toUtcTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z")
}

export async function sha256File(path: string): Promise<string> {
  const contents = await readFile(path)
  return createHash("sha256").update(contents).digest("hex")
}
