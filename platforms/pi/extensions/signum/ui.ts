import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import type { SignumRunState } from "./state.ts"

export type ResumeDecision = "resume" | "restart" | "cancel"

interface SignumHeartbeatController {
  stop(): void
}

interface SignumProgressState {
  phase: string
  milestone: string
  startedAt: number
  recentEvents: string[]
  frameIndex: number
}

const signumProgressState = new WeakMap<ExtensionCommandContext, SignumProgressState>()
const SIGNUM_RECENT_EVENT_LIMIT = 5
const SIGNUM_PROGRESS_WIDGET_ID = "signum-progress"
const SIGNUM_PIPELINE_PHASES = ["CONTRACT", "EXECUTE", "AUDIT", "PACK"] as const
const SIGNUM_SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸"] as const

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

export function clearSignumProgress(ctx: ExtensionCommandContext) {
  signumProgressState.delete(ctx)
  if (ctx.hasUI) {
    ctx.ui.setWidget(SIGNUM_PROGRESS_WIDGET_ID, undefined)
    ctx.ui.setStatus("signum", undefined)
  }
}

export function setSignumProgress(ctx: ExtensionCommandContext, phase: string, milestone: string, event?: string) {
  const previous = signumProgressState.get(ctx)
  const next: SignumProgressState = {
    phase,
    milestone,
    startedAt: previous?.phase === phase ? previous.startedAt : Date.now(),
    recentEvents: [...(previous?.recentEvents ?? [])],
    frameIndex: previous ? (previous.frameIndex + 1) % SIGNUM_SPINNER_FRAMES.length : 0,
  }

  if (event) {
    next.recentEvents.push(event)
    next.recentEvents = next.recentEvents.slice(-SIGNUM_RECENT_EVENT_LIMIT)
  }

  signumProgressState.set(ctx, next)
  renderSignumProgress(ctx)
}

export function pushSignumProgressEvent(ctx: ExtensionCommandContext, event: string) {
  const current = signumProgressState.get(ctx)
  if (!current) return
  current.recentEvents.push(event)
  current.recentEvents = current.recentEvents.slice(-SIGNUM_RECENT_EVENT_LIMIT)
  renderSignumProgress(ctx)
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

  setSignumProgress(ctx, phase, milestone, `Milestone: ${phase} ${milestone}`)
  const setHeartbeatStatus = () => {
    const state = signumProgressState.get(ctx)
    if (!state) return
    renderSignumProgress(ctx)
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

function renderSignumProgress(ctx: ExtensionCommandContext) {
  if (!ctx.hasUI) return

  const state = signumProgressState.get(ctx)
  if (!state) return

  const elapsed = formatHeartbeatElapsed(Date.now() - state.startedAt)
  const recentEvents = state.recentEvents.length > 0 ? state.recentEvents : ["waiting for milestone update"]
  const currentPhase = normalizePipelinePhase(state.phase)
  const spinner = SIGNUM_SPINNER_FRAMES[state.frameIndex % SIGNUM_SPINNER_FRAMES.length]
  const stepper = SIGNUM_PIPELINE_PHASES.map((phase) => formatStepperPhase(ctx, phase, currentPhase)).join(" ")
  const widgetLines = [
    `Signum ${spinner}`,
    stepper,
    `milestone: ${state.milestone}`,
    `elapsed: ${elapsed}`,
    "recent events:",
    ...recentEvents.map((event) => `- ${event}`),
  ]
  ctx.ui.setWidget(SIGNUM_PROGRESS_WIDGET_ID, widgetLines)
  setSignumStatus(ctx, `${currentPhase} ${state.milestone} · elapsed ${elapsed} · recent events ${recentEvents.join(" · ")}`)
}

function normalizePipelinePhase(phase: string): string {
  const upper = phase.trim().toUpperCase()
  return SIGNUM_PIPELINE_PHASES.includes(upper as (typeof SIGNUM_PIPELINE_PHASES)[number]) ? upper : "CONTRACT"
}

function formatStepperPhase(ctx: ExtensionCommandContext, phase: (typeof SIGNUM_PIPELINE_PHASES)[number], currentPhase: string): string {
  const isActive = phase === currentPhase
  const theme = ctx.ui.theme
  const label = isActive ? `[${phase}]` : phase
  return isActive ? theme.fg("accent", label) : theme.fg("dim", label)
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
