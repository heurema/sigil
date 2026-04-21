import { readFile, stat } from "node:fs/promises"
import { resolve } from "node:path"

import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import { parseSignumArgs } from "./args.ts"
import { runArchivePhase } from "./phases/archive.ts"
import { runClosePhase } from "./phases/close.ts"
import { runContractPhase } from "./phases/contract.ts"
import { runAuditPhase } from "./phases/audit.ts"
import { runExecutePhase } from "./phases/execute.ts"
import { runExplainPhase } from "./phases/explain.ts"
import { runInitPhase } from "./phases/init.ts"
import { runPackPhase } from "./phases/pack.ts"
import { clearWorkingSet, detectRunState } from "./state.ts"
import { promptResumeDecision, setSignumStatus } from "./ui.ts"

export interface SignumCommandResult {
  kind: string
  message: string
  details?: Record<string, unknown>
}

interface PipelineRunResult {
  summary: string
  executeStatus: string
  auditDecision?: string
  packDecision?: string
}

export async function runSignumCommand(
  pi: ExtensionAPI,
  rawArgs: string,
  ctx: ExtensionCommandContext,
): Promise<SignumCommandResult> {
  const parsed = parseSignumArgs(rawArgs)
  if (!parsed.ok) {
    return {
      kind: "error",
      message: parsed.message,
    }
  }

  try {
    switch (parsed.command.kind) {
      case "explain": {
        setSignumStatus(ctx, "explain")
        const message = await runExplainPhase()
        return {
          kind: "explain",
          message,
        }
      }

      case "init": {
        const projectRoot = parsed.command.projectRoot ?? ctx.cwd
        setSignumStatus(ctx, `init ${projectRoot}`)
        const message = await runInitPhase(pi, ctx, parsed.command)
        return {
          kind: "init",
          message,
          details: {
            projectRoot,
            force: parsed.command.force,
            harness: parsed.command.harness,
          },
        }
      }

      case "archive": {
        setSignumStatus(ctx, "archive")
        const message = await runArchivePhase(ctx.cwd, parsed.command.contractId)
        return {
          kind: "archive",
          message,
          details: {
            contractId: parsed.command.contractId,
          },
        }
      }

      case "close": {
        setSignumStatus(ctx, "close")
        const message = await runClosePhase(ctx.cwd, parsed.command.contractId)
        return {
          kind: "close",
          message,
          details: {
            contractId: parsed.command.contractId,
          },
        }
      }

      case "task": {
        setSignumStatus(ctx, "task preflight")
        const runState = await detectRunState(ctx.cwd)

        if (runState.kind !== "none") {
          if (!ctx.hasUI) {
            return {
              kind: "task",
              message: [
                `Detected run state: ${runState.kind}`,
                "Interactive pi is required to choose resume, restart, or cancel.",
                "Existing .signum working set left unchanged.",
              ].join("\n"),
              details: {
                task: parsed.command.task,
                runState: runState.kind,
                decision: "interactive-required",
              },
            }
          }

          const decision = await promptResumeDecision(ctx, runState)
          if (decision === "cancel") {
            return {
              kind: "task",
              message: "Cancelled. Existing .signum working set left unchanged.",
              details: {
                task: parsed.command.task,
                runState: runState.kind,
                decision,
              },
            }
          }

          if (decision === "restart") {
            const cleared = await clearWorkingSet(ctx.cwd)
            const contractResult = await runContractPhase(pi, ctx, { task: parsed.command.task })
            if (contractResult.status !== "approved") {
              return {
                kind: "task",
                message: [
                  `Restart selected for task: ${parsed.command.task}`,
                  `Cleared ${cleared.removedPaths.length} working-set path(s).`,
                  cleared.clearedActiveContract ? "Cleared activeContractId in .signum/contracts/index.json." : "",
                  "",
                  contractResult.summary,
                ]
                  .filter((line) => line.length > 0)
                  .join("\n"),
                details: {
                  task: parsed.command.task,
                  runState: runState.kind,
                  decision,
                  removedPaths: cleared.removedPaths,
                  contractId: contractResult.contractId,
                  contractStatus: contractResult.status,
                },
              }
            }

            const pipelineResult = await runPipelineFromCurrentState(pi, ctx)
            return {
              kind: "task",
              message: [
                `Restart selected for task: ${parsed.command.task}`,
                `Cleared ${cleared.removedPaths.length} working-set path(s).`,
                cleared.clearedActiveContract ? "Cleared activeContractId in .signum/contracts/index.json." : "",
                "",
                contractResult.summary,
                "",
                pipelineResult.summary,
              ]
                .filter((line) => line.length > 0)
                .join("\n"),
              details: {
                task: parsed.command.task,
                runState: runState.kind,
                decision,
                removedPaths: cleared.removedPaths,
                contractId: contractResult.contractId,
                contractStatus: contractResult.status,
                executeStatus: pipelineResult.executeStatus,
                auditDecision: pipelineResult.auditDecision,
                packDecision: pipelineResult.packDecision,
              },
            }
          }

          const pipelineResult = await runPipelineFromCurrentState(pi, ctx)
          return {
            kind: "task",
            message: [
              `Resume selected for task: ${parsed.command.task}`,
              `Detected run state: ${runState.kind}`,
              pipelineResult.summary,
            ].join("\n"),
            details: {
              task: parsed.command.task,
              runState: runState.kind,
              decision,
              executeStatus: pipelineResult.executeStatus,
              auditDecision: pipelineResult.auditDecision,
              packDecision: pipelineResult.packDecision,
            },
          }
        }

        const contractResult = await runContractPhase(pi, ctx, { task: parsed.command.task })
        if (contractResult.status !== "approved") {
          return {
            kind: "task",
            message: contractResult.summary,
            details: {
              task: parsed.command.task,
              runState: "none",
              contractId: contractResult.contractId,
              contractStatus: contractResult.status,
            },
          }
        }

        const pipelineResult = await runPipelineFromCurrentState(pi, ctx)
        return {
          kind: "task",
          message: [contractResult.summary, "", pipelineResult.summary].join("\n"),
          details: {
            task: parsed.command.task,
            runState: "none",
            contractId: contractResult.contractId,
            contractStatus: contractResult.status,
            executeStatus: pipelineResult.executeStatus,
            auditDecision: pipelineResult.auditDecision,
            packDecision: pipelineResult.packDecision,
          },
        }
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return {
      kind: "error",
      message: `Signum for pi failed: ${message}`,
    }
  } finally {
    setSignumStatus(ctx, undefined)
  }
}

async function runPipelineFromCurrentState(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
): Promise<PipelineRunResult> {
  const projectRoot = ctx.cwd
  const hasSuccessfulExecute = await readExecuteSuccess(projectRoot)

  const executeResult = hasSuccessfulExecute
    ? { status: "success" as const, summary: "EXECUTE already completed earlier in this working set. Reusing existing artifacts." }
    : await runExecutePhase(pi, ctx)

  if (executeResult.status !== "success") {
    return {
      summary: executeResult.summary,
      executeStatus: executeResult.status,
    }
  }

  const auditResult = await runAuditPhase(pi, ctx)
  if (auditResult.status !== "ok" || !auditResult.decision) {
    return {
      summary: [executeResult.summary, "", auditResult.summary].join("\n"),
      executeStatus: executeResult.status,
    }
  }

  const packResult = await runPackPhase(pi, ctx)
  return {
    summary: [executeResult.summary, "", auditResult.summary, "", packResult.summary].join("\n"),
    executeStatus: executeResult.status,
    auditDecision: auditResult.decision,
    packDecision: packResult.decision,
  }
}

async function readExecuteSuccess(projectRoot: string): Promise<boolean> {
  try {
    await stat(resolve(projectRoot, ".signum/receipts/execute.json"))
    const parsed = JSON.parse(await readFile(resolve(projectRoot, ".signum/execute_log.json"), "utf8")) as { status?: string }
    return parsed.status === "SUCCESS"
  } catch {
    return false
  }
}
