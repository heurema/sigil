import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import type { SignumRunState } from "./state.ts"

export type ResumeDecision = "resume" | "restart" | "cancel"

interface SignumHeartbeatController {
  stop(): void
}

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

export function startSignumHeartbeat(
  ctx: ExtensionCommandContext,
  phase: string,
  milestone: string,
  intervalMs = 15_000,
): SignumHeartbeatController {
  if (!ctx.hasUI) {
    return { stop() {} }
  }

  const startedAt = Date.now()
  const setHeartbeatStatus = () => {
    const elapsed = formatHeartbeatElapsed(Date.now() - startedAt)
    setSignumStatus(ctx, `${phase} ${milestone} · elapsed ${elapsed}`)
  }

  setHeartbeatStatus()
  const heartbeat = setInterval(setHeartbeatStatus, intervalMs)
  return {
    stop() {
      clearInterval(heartbeat)
    },
  }
}

export async function withSignumHeartbeat<T>(
  ctx: ExtensionCommandContext,
  phase: string,
  milestone: string,
  run: () => Promise<T>,
): Promise<T> {
  const heartbeat = startSignumHeartbeat(ctx, phase, milestone)
  try {
    return await run()
  } finally {
    heartbeat.stop()
  }
}

function formatHeartbeatElapsed(durationMs: number): string {
  const totalSeconds = Math.max(0, Math.floor(durationMs / 1000))
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  return `${minutes}:${String(seconds).padStart(2, "0")}`
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
