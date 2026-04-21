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
import { clearSignumProgress, promptResumeDecision, setSignumProgress, setSignumStatus } from "./ui.ts"

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

interface ContractDocument {
  contractId?: string
}

interface ContractIndexDocument {
  activeContractId?: string | null
}

interface ExecuteReceipt {
  contract_id?: string
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
        setSignumProgress(ctx, "explain", "foreground")
        const message = await runExplainPhase()
        return {
          kind: "explain",
          message,
        }
      }

      case "init": {
        const projectRoot = parsed.command.projectRoot ?? ctx.cwd
        setSignumStatus(ctx, `init ${projectRoot}`)
        setSignumProgress(ctx, "init", "foreground")
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
        setSignumProgress(ctx, "archive", "foreground")
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
        setSignumProgress(ctx, "close", "foreground")
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
        setSignumProgress(ctx, "task", "preflight", "Foreground pipeline active")
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
            setSignumStatus(ctx, "task contract")
            setSignumProgress(ctx, "contract", "foreground", "Restart selected")
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

            setSignumStatus(ctx, "task execute")
            setSignumProgress(ctx, "execute", "foreground", "Foreground EXECUTE starting")
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

          setSignumStatus(ctx, "task execute")
          setSignumProgress(ctx, "execute", "foreground", "Resuming foreground pipeline")
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

        setSignumStatus(ctx, "task contract")
        setSignumProgress(ctx, "contract", "foreground", "Foreground CONTRACT starting")
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

        setSignumStatus(ctx, "task execute")
        setSignumProgress(ctx, "execute", "foreground", "Foreground EXECUTE starting")
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
    clearSignumProgress(ctx)
    setSignumStatus(ctx, undefined)
  }
}

async function runPipelineFromCurrentState(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
): Promise<PipelineRunResult> {
  const projectRoot = ctx.cwd
  const hasSuccessfulExecute = await readExecuteSuccess(projectRoot)

  setSignumStatus(ctx, hasSuccessfulExecute ? "task execute reuse" : "task execute")
  setSignumProgress(ctx, "execute", hasSuccessfulExecute ? "reuse" : "run", hasSuccessfulExecute ? "Reusing prior EXECUTE artifacts" : "Running EXECUTE inline")
  const executeResult = hasSuccessfulExecute
    ? { status: "success" as const, summary: "EXECUTE already completed earlier in this working set. Reusing existing artifacts." }
    : await runExecutePhase(pi, ctx)

  if (executeResult.status !== "success") {
    return {
      summary: executeResult.summary,
      executeStatus: executeResult.status,
    }
  }

  setSignumStatus(ctx, "task audit")
  setSignumProgress(ctx, "audit", "run", "Running AUDIT inline")
  const auditResult = await runAuditPhase(pi, ctx)
  if (auditResult.status !== "ok" || !auditResult.decision) {
    return {
      summary: [executeResult.summary, "", auditResult.summary].join("\n"),
      executeStatus: executeResult.status,
    }
  }

  setSignumStatus(ctx, "task pack")
  setSignumProgress(ctx, "pack", "run", "Running PACK inline")
  const packResult = await runPackPhase(pi, ctx)
  return {
    summary: [executeResult.summary, "", auditResult.summary, "", packResult.summary].join("\n"),
    executeStatus: executeResult.status,
    auditDecision: auditResult.decision,
    packDecision: packResult.decision,
  }
}

export async function readExecuteSuccess(projectRoot: string): Promise<boolean> {
  try {
    await stat(resolve(projectRoot, ".signum/receipts/execute.json"))

    const executeLog = JSON.parse(await readFile(resolve(projectRoot, ".signum/execute_log.json"), "utf8")) as { status?: string }
    if (executeLog.status !== "SUCCESS") {
      return false
    }

    const contract = JSON.parse(await readFile(resolve(projectRoot, ".signum/contract.json"), "utf8")) as ContractDocument
    const index = JSON.parse(await readFile(resolve(projectRoot, ".signum/contracts/index.json"), "utf8")) as ContractIndexDocument
    const executeReceipt = JSON.parse(await readFile(resolve(projectRoot, ".signum/receipts/execute.json"), "utf8")) as ExecuteReceipt

    const contractId = typeof contract.contractId === "string" ? contract.contractId : undefined
    const activeContractId = typeof index.activeContractId === "string" ? index.activeContractId : undefined
    const receiptContractId = typeof executeReceipt.contract_id === "string" ? executeReceipt.contract_id : undefined

    return Boolean(contractId && activeContractId && receiptContractId && contractId === activeContractId && receiptContractId === activeContractId)
  } catch {
    return false
  }
}
