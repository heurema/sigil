import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import type { SignumRunState } from "./state.ts"

export type ResumeDecision = "resume" | "restart" | "cancel"

export function setSignumStatus(ctx: ExtensionCommandContext, text?: string) {
  if (!ctx.hasUI) return

  if (!text) {
    ctx.ui.setStatus("signum", undefined)
    return
  }

  const theme = ctx.ui.theme
  const prefix = theme.fg("accent", "signum")
  const body = theme.fg("dim", ` ${text}`)
  ctx.ui.setStatus("signum", `${prefix}${body}`)
}

export function emitSignumMessage(pi: ExtensionAPI, content: string, details?: Record<string, unknown>) {
  pi.sendMessage({
    customType: "signum",
    content,
    display: true,
    details: {
      ...(details ?? {}),
      timestamp: Date.now(),
    },
  })
}

export async function promptResumeDecision(
  ctx: ExtensionCommandContext,
  state: SignumRunState,
): Promise<ResumeDecision> {
  if (!ctx.hasUI) return "cancel"

  const message =
    state.kind === "resumable"
      ? "A previous run exists in .signum/ (contract + execution context). Choose how to continue."
      : "A contract exists in .signum/, but execution has not started. Choose how to continue."

  const options = [
    "resume — continue with the current working set",
    "restart — discard the current working set and start from CONTRACT",
    "cancel — do nothing",
  ]

  const selected = await ctx.ui.select(message, options)
  if (!selected) return "cancel"
  if (selected.startsWith("resume")) return "resume"
  if (selected.startsWith("restart")) return "restart"
  return "cancel"
}
