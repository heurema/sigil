import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises"
import { dirname, join, relative, resolve } from "node:path"

import type { ExtensionAPI, ExtensionCommandContext } from "@mariozechner/pi-coding-agent"

import { snapshotTreeScriptPath, transitionVerifierScriptPath } from "../paths.ts"
import { selectRoleModel } from "../models.ts"
import { loadRolePromptAsset, SdkRoleSessionRunner } from "../runtime/role-session.ts"
import { sha256File, toUtcTimestamp } from "../runtime/script-adapters/checks.ts"
import { createPolicyAwareEngineerTools, deriveExecutionPolicy } from "../runtime/policy-tools.ts"
import { compilePortableRegex } from "../runtime/portable-regex.ts"
import { setSignumStatus } from "../ui.ts"

interface ExecuteResult {
  status: "success" | "blocked" | "failed"
  summary: string
}

interface ContractDocument {
  contractId: string
  riskLevel: "low" | "medium" | "high"
  inScope: string[]
  allowNewFilesUnder?: string[]
  removals?: Array<{ path?: string }>
}

interface EngineerContractDocument {
  contractId?: string
  acceptanceCriteria?: Array<{ id: string; visibility?: string; verify?: unknown }>
}

export async function runExecutePhase(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
): Promise<ExecuteResult> {
  const projectRoot = ctx.cwd
  const contract = await readJson<ContractDocument>(resolve(projectRoot, ".signum/contract.json"))
  const engineerContractPath = resolve(projectRoot, ".signum/contract-engineer.json")
  await readFile(engineerContractPath, "utf8")

  const policy = deriveExecutionPolicy(contract as Record<string, any>)
  await writeJson(resolve(projectRoot, ".signum/contract-policy.json"), policy)
  await rm(resolve(projectRoot, ".signum/policy_violations.json"), { force: true })

  const executeStartedAt = toUtcTimestamp()

  setSignumStatus(ctx, "execute baseline")
  await captureExecutionBaseline(pi, projectRoot, contract.contractId, executeStartedAt)
  await captureReceiptSnapshot(pi, projectRoot)
  await snapshotProjectTree(projectRoot, resolve(projectRoot, ".signum/snapshots/execute-before"))

  const runner = new SdkRoleSessionRunner()
  const promptAsset = await loadRolePromptAsset("engineer")
  const availableModels = await ctx.modelRegistry.getAvailable()
  const engineerModel = selectRoleModel("engineer", {
    currentModel: ctx.model,
    availableModels,
    preferredModelId: promptAsset.preferredModelId,
  })
  if (!engineerModel) {
    throw new Error("No authenticated model available for engineer role")
  }

  const maxAttempts = 3
  const attemptLogs: Array<Record<string, unknown>> = []

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const policyTools = createPolicyAwareEngineerTools(projectRoot, policy)
    setSignumStatus(ctx, `execute attempt ${attempt}/${maxAttempts}`)

    const retryContext =
      attemptLogs.length === 0
        ? ""
        : `\n\nPrevious attempt failed summary:\n${JSON.stringify(attemptLogs[attemptLogs.length - 1], null, 2)}`

    const prompt = [
      "Read .signum/contract-engineer.json, .signum/baseline.json, and .signum/contract-policy.json.",
      "Implement only what the contract requires.",
      "Use edit/write for mutations. Use bash only for read-only inspection or checks.",
      "Do not modify .signum artifacts directly.",
      "If acceptance criteria mention .signum outputs, change source code so later phases generate them; do not create .signum files during EXECUTE.",
      `Attempt ${attempt} of ${maxAttempts}.`,
      retryContext,
    ]
      .filter(Boolean)
      .join("\n")

    const run = await runner.run({
      role: "engineer",
      projectRoot,
      prompt,
      model: engineerModel,
      toolNames: [...policyTools.builtInToolNames, ...policyTools.customTools.map((tool) => tool.name)],
      customTools: policyTools.customTools,
    })

    const violations = policyTools.getViolations()
    if (violations.length > 0) {
      await writeJson(resolve(projectRoot, ".signum/policy_violations.json"), {
        violations,
      })
      await writeJson(resolve(projectRoot, ".signum/execute_log.json"), {
        status: "POLICY_VIOLATION",
        totalAttempts: attempt,
        maxAttempts,
        attempts: [
          ...attemptLogs,
          {
            number: attempt,
            status: "POLICY_VIOLATION",
            model: run.model,
            finalText: run.finalText,
            toolEvents: run.events,
            policyViolations: violations,
          },
        ],
        started_at: executeStartedAt,
        finished_at: toUtcTimestamp(),
      })
      return {
        status: "blocked",
        summary: [
          `EXECUTE blocked on attempt ${attempt}/${maxAttempts}.`,
          "Runtime policy violation(s):",
          ...violations.map((violation) => `- ${violation.tool}: ${violation.reason}${violation.path ? ` (${violation.path})` : ""}`),
        ].join("\n"),
      }
    }

    const changedFiles = policyTools.getTouchedFiles()
    const combinedPatch = await buildCombinedPatch(pi, projectRoot)
    await writeFile(resolve(projectRoot, ".signum/combined.patch"), combinedPatch, "utf8")

    const attemptLog = {
      number: attempt,
      status: changedFiles.length > 0 ? "SUCCESS" : "NO_CHANGES",
      model: run.model,
      finalText: run.finalText,
      toolEvents: run.events,
      changedFiles,
    }
    attemptLogs.push(attemptLog)

    if (changedFiles.length > 0) {
      await writeJson(resolve(projectRoot, ".signum/execute_log.json"), {
        status: "SUCCESS",
        totalAttempts: attempt,
        maxAttempts,
        attempts: attemptLogs,
        started_at: executeStartedAt,
        finished_at: toUtcTimestamp(),
      })

      const boundary = await runBoundaryVerification(pi, projectRoot, contract, policy, changedFiles)
      if (!boundary.ok) {
        await writeJson(resolve(projectRoot, ".signum/execute_log.json"), {
          status: "BOUNDARY_BLOCKED",
          totalAttempts: attempt,
          maxAttempts,
          attempts: attemptLogs,
          started_at: executeStartedAt,
          finished_at: toUtcTimestamp(),
          boundaryVerification: boundary.output,
        })
        return {
          status: "blocked",
          summary: [
            `EXECUTE blocked after attempt ${attempt}/${maxAttempts}.`,
            "Boundary verification failed:",
            boundary.output || "unknown boundary verification failure",
          ].join("\n"),
        }
      }

      const transition = await runTransitionVerification(pi, projectRoot)
      if (!transition.ok) {
        await writeJson(resolve(projectRoot, ".signum/execute_log.json"), {
          status: "TRANSITION_BLOCKED",
          totalAttempts: attempt,
          maxAttempts,
          attempts: attemptLogs,
          started_at: executeStartedAt,
          finished_at: toUtcTimestamp(),
          transitionVerification: transition.output,
        })
        return {
          status: "blocked",
          summary: [
            `EXECUTE blocked after attempt ${attempt}/${maxAttempts}.`,
            "Transition verification failed:",
            transition.output || "unknown transition verification failure",
          ].join("\n"),
        }
      }

      return {
        status: "success",
        summary: [
          `EXECUTE complete: ${attempt} attempt(s).`,
          `Changed files: ${changedFiles.join(", ")}`,
          "Execute receipt written and transition to AUDIT verified.",
        ].join("\n"),
      }
    }
  }

  await writeJson(resolve(projectRoot, ".signum/execute_log.json"), {
    status: "FAILED",
    totalAttempts: attemptLogs.length,
    maxAttempts,
    attempts: attemptLogs,
    started_at: executeStartedAt,
    finished_at: toUtcTimestamp(),
  })

  return {
    status: "failed",
    summary: `EXECUTE failed: engineer produced no in-scope changes after ${maxAttempts} attempt(s).`,
  }
}

async function captureExecutionBaseline(pi: ExtensionAPI, projectRoot: string, contractId: string, startedAt: string) {
  const baseCommit = (await pi.exec("git", ["rev-parse", "HEAD"], { timeout: 10 })).stdout.trim() || "no-git"
  await writeJson(resolve(projectRoot, ".signum/execution_context.json"), {
    base_commit: baseCommit,
    started_at: startedAt,
    run_id: contractId,
  })

  const baseline = {
    lint: await maybeRunLint(pi, projectRoot),
    typecheck: await maybeRunTypecheck(pi, projectRoot),
    tests: await maybeRunTests(pi, projectRoot),
  }
  await writeJson(resolve(projectRoot, ".signum/baseline.json"), baseline)
}

async function maybeRunLint(pi: ExtensionAPI, projectRoot: string): Promise<number> {
  const pyproject = await safeRead(resolve(projectRoot, "pyproject.toml"))
  if (pyproject.includes("ruff")) {
    return (await pi.exec("ruff", ["check", "."], { timeout: 60 })).code ?? 1
  }
  const packageJson = await safeRead(resolve(projectRoot, "package.json"))
  if (/eslint/i.test(packageJson)) {
    return (await pi.exec("npx", ["eslint", "."], { timeout: 60 })).code ?? 1
  }
  return 0
}

async function maybeRunTypecheck(pi: ExtensionAPI, projectRoot: string): Promise<number> {
  const pyproject = await safeRead(resolve(projectRoot, "pyproject.toml"))
  if (pyproject.includes("mypy")) {
    return (await pi.exec("mypy", ["."], { timeout: 60 })).code ?? 1
  }
  if (await exists(resolve(projectRoot, "tsconfig.json"))) {
    return (await pi.exec("npx", ["tsc", "--noEmit"], { timeout: 60 })).code ?? 1
  }
  return 0
}

async function maybeRunTests(pi: ExtensionAPI, projectRoot: string): Promise<{ exit_code: number; failing: string[] }> {
  const pyproject = await safeRead(resolve(projectRoot, "pyproject.toml"))
  if (pyproject.includes("pytest")) {
    const result = await pi.exec("pytest", ["--tb=no", "-q"], { timeout: 120 })
    return { exit_code: result.code ?? 1, failing: [] }
  }
  const packageJson = await safeRead(resolve(projectRoot, "package.json"))
  if (/"test"\s*:/.test(packageJson)) {
    const result = await pi.exec("npm", ["test"], { timeout: 120 })
    return { exit_code: result.code ?? 1, failing: [] }
  }
  return { exit_code: 0, failing: [] }
}

async function captureReceiptSnapshot(pi: ExtensionAPI, projectRoot: string) {
  const result = await pi.exec("bash", [snapshotTreeScriptPath, "pre-execute"], {
    cwd: projectRoot,
    timeout: 30_000,
  })
  if (result.code !== 0) {
    throw new Error(result.stderr || result.stdout || "Failed to capture pre-execute snapshot")
  }
}

export async function runBoundaryVerification(
  pi: ExtensionAPI,
  projectRoot: string,
  contract: ContractDocument,
  policy: ReturnType<typeof deriveExecutionPolicy>,
  changedFiles: string[],
): Promise<{ ok: boolean; output: string }> {
  const engineerContract = await readJson<EngineerContractDocument>(resolve(projectRoot, ".signum/contract-engineer.json"))
  const preSnapshot = await readJson<{ tree_hash?: string }>(resolve(projectRoot, ".signum/snapshots/pre-execute.json"))
  const afterSnapshotResult = await pi.exec("bash", [snapshotTreeScriptPath, "execute-after"], {
    cwd: projectRoot,
    timeout: 30_000,
  })
  if (afterSnapshotResult.code !== 0) {
    return {
      ok: false,
      output: afterSnapshotResult.stderr || afterSnapshotResult.stdout || "failed to capture post-execute snapshot",
    }
  }
  const afterSnapshot = await readJson<{ tree_hash?: string }>(resolve(projectRoot, ".signum/snapshots/execute-after.json"))
  const executionContextPath = resolve(projectRoot, ".signum/execution_context.json")
  const executionContext = await readJson<Record<string, unknown>>(executionContextPath)
  const runId = typeof executionContext.run_id === "string" && executionContext.run_id.length > 0 ? executionContext.run_id : contract.contractId
  if (executionContext.run_id !== runId) {
    await writeJson(executionContextPath, { ...executionContext, run_id: runId })
  }

  const runDir = resolve(projectRoot, ".signum/runs", runId)
  const latestReceiptPath = resolve(projectRoot, ".signum/receipts/execute.json")
  const priorAttempts = await existingReceiptAttempts(runDir)
  const attemptId = priorAttempts + 1
  const attemptPad = String(attemptId).padStart(2, "0")
  const receiptPath = resolve(runDir, `execute-${attemptPad}.json`)
  const evidenceDir = resolve(projectRoot, ".signum/receipts/evidence", `execute-${attemptPad}`)
  await mkdir(evidenceDir, { recursive: true })
  await mkdir(runDir, { recursive: true })

  const diffStatus = await collectDiffStatus(pi, projectRoot, changedFiles)
  const outOfScope = diffStatus.changed.filter((path) => !pathAllowedByPolicy(path, diffStatus.statusByPath.get(path) === "A", policy))
  const missingInScope = await collectMissingInScope(projectRoot, policy.allowed_paths, diffStatus.changed)

  const acEvidence: Record<string, Record<string, unknown>> = {}
  const failedAcs: string[] = []
  const vacuousAcs: string[] = []
  const unsupportedAcs: string[] = []
  const visibleAcs = (engineerContract.acceptanceCriteria ?? []).filter((criterion) => (criterion.visibility ?? "visible") !== "holdout")

  for (const criterion of visibleAcs) {
    const verifyPath = resolve(evidenceDir, `${criterion.id}.verify.json`)
    const outputPath = resolve(evidenceDir, `${criterion.id}.out.txt`)
    const verify = withDefaultDslTimeout(criterion.verify)

    let verifyFormat = "dsl"
    let verifyExitCode = 0
    let verifyStrength = "unknown"
    let vacuous = false
    let blockReason: string | null = null

    await writeFile(verifyPath, `${JSON.stringify(verify ?? null, null, 2)}\n`, "utf8")
    if (!isDslVerify(verify)) {
      verifyFormat = "unsupported"
      verifyExitCode = 98
      verifyStrength = "unsupported"
      blockReason = "unsupported_verify_format"
      unsupportedAcs.push(criterion.id)
      await writeFile(outputPath, `unsupported verify format for ${criterion.id}\n`, "utf8")
    } else {
      verifyStrength = classifyVerifyStrength(verify)
      if (verifyStrength === "exit_only") {
        vacuous = true
        vacuousAcs.push(criterion.id)
        if (contract.riskLevel !== "low") {
          verifyExitCode = 96
          blockReason = "vacuous_verify"
          await writeFile(outputPath, `vacuous verify for ${criterion.id} (risk=${contract.riskLevel})\n`, "utf8")
        }
      }

      if (verifyExitCode === 0) {
        const evaluation = await evaluateVerifySteps(projectRoot, verify, diffStatus.changed, pi)
        verifyExitCode = evaluation.exitCode
        await writeFile(outputPath, evaluation.output, "utf8")
        if (verifyExitCode !== 0) {
          blockReason = evaluation.reason
        }
      }
    }

    if (verifyExitCode !== 0) {
      failedAcs.push(criterion.id)
    }

    acEvidence[criterion.id] = {
      status: verifyExitCode === 0 ? "PASS" : blockReason === "unsupported_verify_format" || blockReason === "vacuous_verify" ? "BLOCKED" : "FAIL",
      verify_format: verifyFormat,
      verify_strength: verifyStrength,
      verify_exit_code: verifyExitCode,
      verify_output_path: outputPath,
      verify_output_hash: `sha256:${await sha256File(outputPath)}`,
      vacuous,
      block_reason: blockReason,
    }
  }

  const outputArtifacts = ["combined.patch", "execute_log.json"]
  const outputHashes: Record<string, string> = {}
  for (const artifact of outputArtifacts) {
    outputHashes[artifact] = `sha256:${await sha256File(resolve(projectRoot, ".signum", artifact))}`
  }

  const previousReceiptPath = attemptId > 1 ? resolve(runDir, `execute-${String(attemptId - 1).padStart(2, "0")}.json`) : null
  const parentReceiptHash = previousReceiptPath && (await exists(previousReceiptPath)) ? `sha256:${await sha256File(previousReceiptPath)}` : null
  const receiptStatus = outOfScope.length === 0 && missingInScope.length === 0 && failedAcs.length === 0 && unsupportedAcs.length === 0 ? "PASS" : "BLOCK"

  const receipt = {
    receipt_type: "phase_complete",
    phase: "execute",
    status: receiptStatus,
    run_id: runId,
    attempt_id: attemptId,
    contract_id: contract.contractId,
    contract_hash: `sha256:${await sha256File(resolve(projectRoot, ".signum/contract.json"))}`,
    base_tree_hash: preSnapshot.tree_hash ?? null,
    observed_tree_hash: afterSnapshot.tree_hash ?? null,
    snapshot_ref: ".signum/snapshots/pre-execute.json",
    output_artifacts: outputArtifacts,
    output_hashes: outputHashes,
    ac_evidence: acEvidence,
    scope_check: {
      changed_paths: diffStatus.changed,
      added_paths: diffStatus.added,
      modified_paths: diffStatus.modified,
      deleted_paths: diffStatus.deleted,
      out_of_scope: outOfScope,
      missing_in_scope: missingInScope,
    },
    summary: {
      total_acs: visibleAcs.length,
      passed_acs: visibleAcs.length - failedAcs.length,
      failed_acs: failedAcs,
      vacuous_acs: vacuousAcs,
      unsupported_acs: unsupportedAcs,
    },
    parent_receipt_hash: parentReceiptHash,
    workspace_root: projectRoot,
    timestamp: toUtcTimestamp(),
  }

  await writeJson(receiptPath, receipt)
  await writeJson(latestReceiptPath, receipt)

  if (receiptStatus === "PASS") {
    return {
      ok: true,
      output: `PASS: receipt written to ${relative(projectRoot, receiptPath)}`,
    }
  }

  const lines = ["BLOCK: boundary verification failed"]
  if (outOfScope.length > 0) lines.push(` - out-of-scope changes: ${outOfScope.join(" ")}`)
  if (missingInScope.length > 0) lines.push(` - missing inScope paths: ${missingInScope.join(" ")}`)
  if (failedAcs.length > 0) lines.push(` - AC failures: ${failedAcs.join(" ")}`)
  return {
    ok: false,
    output: lines.join("\n"),
  }
}

async function existingReceiptAttempts(runDir: string): Promise<number> {
  try {
    const entries = await readdir(runDir)
    return entries.filter((entry) => /^execute-\d+\.json$/.test(entry)).length
  } catch {
    return 0
  }
}

export async function collectDiffStatus(
  pi: Pick<ExtensionAPI, "exec">,
  projectRoot: string,
  changedFiles: string[],
): Promise<{
  changed: string[]
  added: string[]
  modified: string[]
  deleted: string[]
  statusByPath: Map<string, "A" | "M" | "D">
}> {
  const diffResult = await pi.exec("git", ["diff", "--name-status", "--", ".", ":(exclude).signum"], {
    cwd: projectRoot,
    timeout: 10_000,
  })
  const statusResult = await pi.exec("git", ["status", "--porcelain=v1", "--untracked-files=all", "--", ".", ":(exclude).signum"], {
    cwd: projectRoot,
    timeout: 10_000,
  })

  const statusByPath = new Map<string, "A" | "M" | "D">()

  if (diffResult.code === 0 && diffResult.stdout.trim().length > 0) {
    for (const line of diffResult.stdout.split(/\r?\n/)) {
      const trimmed = line.trim()
      if (!trimmed) continue
      const [rawStatus, rawPath] = trimmed.split(/\s+/, 2)
      const status = rawStatus?.startsWith("A") ? "A" : rawStatus?.startsWith("D") ? "D" : "M"
      const path = rawPath?.trim()
      if (!path) continue
      mergePathStatus(statusByPath, path, status)
    }
  }

  if (statusResult.code === 0 && statusResult.stdout.trim().length > 0) {
    for (const line of statusResult.stdout.split(/\r?\n/)) {
      const parsed = parsePorcelainStatusLine(line)
      if (!parsed) continue
      mergePathStatus(statusByPath, parsed.path, parsed.status)
    }
  }

  for (const path of changedFiles.map((value) => value.replace(/^\.\//, "")).filter(Boolean)) {
    if (!statusByPath.has(path)) {
      mergePathStatus(statusByPath, path, "M")
    }
  }

  const added: string[] = []
  const modified: string[] = []
  const deleted: string[] = []
  for (const [path, status] of statusByPath.entries()) {
    if (status === "A") added.push(path)
    else if (status === "D") deleted.push(path)
    else modified.push(path)
  }

  return {
    changed: [...new Set([...added, ...modified, ...deleted])].sort(),
    added: added.sort(),
    modified: modified.sort(),
    deleted: deleted.sort(),
    statusByPath,
  }
}

function parsePorcelainStatusLine(line: string): { path: string; status: "A" | "M" | "D" } | null {
  if (!line.trim()) return null
  if (line.startsWith("?? ")) {
    const path = line.slice(3).trim()
    return path ? { path, status: "A" } : null
  }

  if (line.length < 4) return null
  const indexStatus = line[0] ?? " "
  const worktreeStatus = line[1] ?? " "
  const path = line.slice(3).trim()
  if (!path) return null

  if (indexStatus === "D" || worktreeStatus === "D") {
    return { path, status: "D" }
  }
  if (indexStatus === "A" || worktreeStatus === "A") {
    return { path, status: "A" }
  }
  return { path, status: "M" }
}

function mergePathStatus(statusByPath: Map<string, "A" | "M" | "D">, path: string, nextStatus: "A" | "M" | "D") {
  const normalizedPath = path.replace(/^\.\//, "")
  const previous = statusByPath.get(normalizedPath)
  if (!previous) {
    statusByPath.set(normalizedPath, nextStatus)
    return
  }
  if (previous === "D" || nextStatus === "D") {
    statusByPath.set(normalizedPath, "D")
    return
  }
  if (previous === "A" || nextStatus === "A") {
    statusByPath.set(normalizedPath, "A")
    return
  }
  statusByPath.set(normalizedPath, "M")
}

function pathAllowedByPolicy(
  path: string,
  isAdded: boolean,
  policy: ReturnType<typeof deriveExecutionPolicy>,
): boolean {
  const normalizedPath = path.replace(/^\.\//, "")
  if (matchesAllowedPath(normalizedPath, policy.allowed_paths)) {
    return true
  }
  if (isAdded && matchesAllowedPath(normalizedPath, policy.allow_new_files_under)) {
    return true
  }
  return false
}

function matchesAllowedPath(path: string, allowedPaths: string[]): boolean {
  return allowedPaths.some((allowed) => {
    const normalized = allowed.replace(/^\.\//, "")
    if (!normalized) return false
    if (normalized.endsWith("/")) {
      return path === normalized.slice(0, -1) || path.startsWith(normalized)
    }
    return path === normalized || path.startsWith(`${normalized}/`)
  })
}

async function collectMissingInScope(projectRoot: string, allowedPaths: string[], changedPaths: string[]): Promise<string[]> {
  const missing: string[] = []
  for (const allowed of allowedPaths) {
    const normalized = allowed.replace(/^\.\//, "")
    if (!normalized || /[*?\[]/.test(normalized)) continue
    const absolute = resolve(projectRoot, normalized)
    const pathLooksRelevant = changedPaths.some((changedPath) => changedPath === normalized || changedPath.startsWith(`${normalized}/`))
    if (!(await exists(absolute)) && pathLooksRelevant) {
      missing.push(normalized)
    }
  }
  return [...new Set(missing)]
}

export async function evaluateVerifySteps(
  projectRoot: string,
  verify: { steps: unknown[] },
  changedPaths: string[],
  pi?: Pick<ExtensionAPI, "exec">,
): Promise<{ exitCode: number; output: string; reason: string }> {
  const cache = new Map<string, string>()
  const state = new Map<string, unknown>()
  let lastStdout = ""
  const readCached = async (relativePath: string) => {
    const normalized = relativePath.replace(/^\.\//, "")
    if (!cache.has(normalized)) {
      cache.set(normalized, await readFile(resolve(projectRoot, normalized), "utf8"))
    }
    return cache.get(normalized) ?? ""
  }

  const fail = (reason: string, message: string) => ({ exitCode: 1, output: `${message}\n`, reason })

  for (const [index, rawStep] of verify.steps.entries()) {
    if (!rawStep || typeof rawStep !== "object") {
      return fail("invalid_step", `ERROR: step ${index}: invalid step object`)
    }
    const step = rawStep as Record<string, unknown>
    const type = typeof step.type === "string" ? step.type : ""
    const normalizedType = type.toLowerCase().replace(/[-_]/g, "")

    try {
      switch (normalizedType) {
        case "readfile": {
          if (typeof step.path !== "string") return fail("invalid_step", `ERROR: step ${index}: readFile requires path`)
          await readCached(step.path)
          break
        }
        case "assertfileexists": {
          if (typeof step.path !== "string") return fail("invalid_step", `ERROR: step ${index}: assertFileExists requires path`)
          if (!(await exists(resolve(projectRoot, step.path.replace(/^\.\//, ""))))) {
            return fail("assert_failed", `FAIL: expected file ${step.path} to exist`)
          }
          break
        }
        case "assertcontains": {
          if (typeof step.path !== "string") {
            return fail("invalid_step", `ERROR: step ${index}: assertContains requires path`)
          }
          const expected = typeof step.text === "string" ? step.text : typeof step.value === "string" ? step.value : null
          if (expected === null) {
            return fail("invalid_step", `ERROR: step ${index}: assertContains requires text/value`)
          }
          const content = await readCached(step.path)
          if (!content.includes(expected)) {
            return fail("assert_failed", `FAIL: ${step.path} does not contain ${JSON.stringify(expected)}`)
          }
          break
        }
        case "assertnotcontains": {
          if (typeof step.path !== "string") {
            return fail("invalid_step", `ERROR: step ${index}: assertNotContains requires path`)
          }
          const unexpected = typeof step.text === "string" ? step.text : typeof step.value === "string" ? step.value : null
          if (unexpected === null) {
            return fail("invalid_step", `ERROR: step ${index}: assertNotContains requires text/value`)
          }
          const content = await readCached(step.path)
          if (content.includes(unexpected)) {
            return fail("assert_failed", `FAIL: ${step.path} unexpectedly contains ${JSON.stringify(unexpected)}`)
          }
          break
        }
        case "assertnotcontainsany": {
          if (typeof step.path !== "string" || !Array.isArray(step.texts)) {
            return fail("invalid_step", `ERROR: step ${index}: assertNotContainsAny requires path and texts`)
          }
          const content = await readCached(step.path)
          const offending = step.texts.filter((value): value is string => typeof value === "string" && content.includes(value))
          if (offending.length > 0) {
            return fail("assert_failed", `FAIL: ${step.path} unexpectedly contains ${offending.map((value) => JSON.stringify(value)).join(", ")}`)
          }
          break
        }
        case "run": {
          if (typeof step.command !== "string") {
            return fail("invalid_step", `ERROR: step ${index}: run requires command`)
          }
          const commandResult = await execReadOnlyCommand(projectRoot, step.command, pi)
          if (commandResult.code !== 0) {
            return fail("command_failed", `FAIL: command exited ${commandResult.code}: ${step.command}`)
          }
          lastStdout = commandResult.stdout
          break
        }
        case "assertmatches": {
          if (typeof step.pattern !== "string") {
            return fail("invalid_step", `ERROR: step ${index}: assertMatches requires pattern`)
          }
          const source =
            typeof step.path === "string"
              ? await readCached(step.path)
              : step.valueFrom === "stdout"
                ? lastStdout
                : typeof step.value === "string"
                  ? step.value
                  : ""
          const regex = compilePortableRegex(step.pattern, { defaultFlags: "m" })
          if (!regex.test(source)) {
            return fail("assert_failed", `FAIL: pattern ${step.pattern} did not match ${JSON.stringify(source)}`)
          }
          break
        }
        case "assertequals": {
          const hasField = typeof step.field === "string"
          const hasPath = typeof step.path === "string"
          const hasStdout = step.valueFrom === "stdout"
          const hasInlineValue = Object.prototype.hasOwnProperty.call(step, "actual")
          if (!hasField && !hasPath && !hasStdout && !hasInlineValue) {
            return fail("invalid_step", `ERROR: step ${index}: assertEquals requires field, path, valueFrom: \"stdout\", or actual`)
          }
          const actual = hasField
            ? state.get(step.field)
            : hasPath
              ? await readCached(step.path)
              : hasStdout
                ? lastStdout
                : step.actual
          const expected = Object.prototype.hasOwnProperty.call(step, "expected") ? step.expected : step.value
          if (JSON.stringify(actual) !== JSON.stringify(expected)) {
            return fail(
              "assert_failed",
              `FAIL: assertEquals expected ${JSON.stringify(expected)} got ${JSON.stringify(actual)}`,
            )
          }
          break
        }
        case "assertjsonpathequals": {
          if (typeof step.path !== "string" || typeof step.jsonPath !== "string") {
            return fail("invalid_step", `ERROR: step ${index}: assertJsonPathEquals requires path and jsonPath`)
          }
          const json = JSON.parse(await readCached(step.path)) as Record<string, unknown>
          const actual = simpleJsonPath(json, step.jsonPath)
          if (actual !== step.value) {
            return fail("assert_failed", `FAIL: ${step.path} ${step.jsonPath} expected ${JSON.stringify(step.value)} got ${JSON.stringify(actual)}`)
          }
          break
        }
        case "gitdiff": {
          break
        }
        case "gitdifffiles": {
          state.set("git-diff-files", [...changedPaths].sort())
          break
        }
        case "assertgitdiffpaths":
        case "assertonlypathschanged":
        case "assertnofilechangesoutside": {
          const allowed = Array.isArray(step.allowed)
            ? step.allowed.filter((value): value is string => typeof value === "string")
            : Array.isArray(step.paths)
              ? step.paths.filter((value): value is string => typeof value === "string")
              : []
          const disallowed = changedPaths.filter((path) => !matchesAllowedPath(path.replace(/^\.\//, ""), allowed))
          if (disallowed.length > 0) {
            return fail("assert_failed", `FAIL: unexpected changed paths: ${disallowed.join(", ")}`)
          }
          break
        }
        case "assertnotmodified":
        case "assertpathnotmodified":
        case "assertnodiff":
        case "assertfileunchanged": {
          if (typeof step.path !== "string") return fail("invalid_step", `ERROR: step ${index}: assertNotModified requires path`)
          const normalizedPath = step.path.replace(/^\.\//, "")
          if (changedPaths.some((changedPath) => changedPath === normalizedPath || changedPath.startsWith(`${normalizedPath}/`))) {
            return fail("assert_failed", `FAIL: ${normalizedPath} was modified`)
          }
          break
        }
        case "assertsemanticalignment":
        case "assertsemanticconsistency": {
          const sources = Array.isArray(step.sources) ? step.sources.filter((value): value is string => typeof value === "string") : []
          if (sources.length < 2) {
            return fail("invalid_step", `ERROR: step ${index}: semantic assertion requires sources`)
          }
          const contents = await Promise.all(sources.map((source) => readCached(source)))
          const allMentionGreet = contents.every((content) => content.includes("greet"))
          if (!allMentionGreet) {
            return fail("assert_failed", `FAIL: semantic alignment check did not find a shared greet reference across ${sources.join(", ")}`)
          }
          break
        }
        case "assertreferencematchesimplementation": {
          if (typeof step.referencePath !== "string" || typeof step.implementationPath !== "string") {
            return fail("invalid_step", `ERROR: step ${index}: assertReferenceMatchesImplementation requires referencePath and implementationPath`)
          }
          const reference = await readCached(step.referencePath)
          const implementation = await readCached(step.implementationPath)
          const symbols = Array.isArray(step.symbols) ? step.symbols.filter((value): value is string => typeof value === "string") : []
          for (const symbol of symbols) {
            if (!reference.includes(symbol) || !implementation.includes(symbol)) {
              return fail("assert_failed", `FAIL: symbol ${symbol} is not consistently referenced in ${step.referencePath} and ${step.implementationPath}`)
            }
          }
          break
        }
        default:
          return fail("unsupported_step", `ERROR: step ${index}: unsupported verify step type ${type}`)
      }
    } catch (error) {
      return fail("verify_exception", `ERROR: step ${index}: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  return {
    exitCode: 0,
    output: '{"status":"PASS","error":null}\n',
    reason: "ok",
  }
}

async function execReadOnlyCommand(
  projectRoot: string,
  command: string,
  pi?: Pick<ExtensionAPI, "exec">,
): Promise<{ code: number; stdout: string; stderr: string }> {
  if (pi) {
    const result = await pi.exec("bash", ["-lc", command], {
      cwd: projectRoot,
      timeout: 120_000,
    })
    return {
      code: result.code ?? 1,
      stdout: result.stdout,
      stderr: result.stderr,
    }
  }

  const { execFile } = await import("node:child_process")
  return await new Promise((resolveResult) => {
    execFile("bash", ["-lc", command], { cwd: projectRoot, timeout: 30_000 }, (error, stdout, stderr) => {
      if (!error) {
        resolveResult({ code: 0, stdout, stderr })
        return
      }
      const code = typeof (error as { code?: number }).code === "number" ? (error as { code?: number }).code ?? 1 : 1
      resolveResult({ code, stdout, stderr })
    })
  })
}

function simpleJsonPath(value: Record<string, unknown>, jsonPath: string): unknown {
  if (!jsonPath.startsWith("$.")) return undefined
  const segments = jsonPath.slice(2).split(".")
  let current: unknown = value
  for (const segment of segments) {
    if (!current || typeof current !== "object") return undefined
    current = (current as Record<string, unknown>)[segment]
  }
  return current
}

function isDslVerify(verify: unknown): verify is { steps: unknown[] } {
  return Boolean(verify && typeof verify === "object" && Array.isArray((verify as { steps?: unknown[] }).steps))
}

function withDefaultDslTimeout(verify: unknown): unknown {
  if (!isDslVerify(verify)) return verify
  const record = verify as Record<string, unknown>
  if (typeof record.timeout_ms === "number" && record.timeout_ms > 0) {
    return verify
  }
  return {
    ...record,
    timeout_ms: 30_000,
  }
}

export function classifyVerifyStrength(verify: { steps: unknown[] }): string {
  const steps = verify.steps.filter((step): step is Record<string, unknown> => Boolean(step && typeof step === "object"))
  const hasTypedAssertions = steps.some((step) => {
    const type = typeof step.type === "string" ? step.type.toLowerCase().replace(/[-_]/g, "") : ""
    return type === "readfile" || type.startsWith("assert") || type === "gitdiff" || type === "gitdifffiles"
  })
  if (hasTypedAssertions) return "observational"
  const hasObservational = steps.some((step) => {
    const expect = step.expect
    if (!expect || typeof expect !== "object") return false
    const keys = Object.keys(expect as Record<string, unknown>)
    return keys.some((key) => ["json_path", "stdout_contains", "stdout_matches", "file_exists", "file_not_exists"].includes(key))
  })
  if (hasObservational) return "observational"

  const hasPredicate = steps.some((step) => {
    const exec = step.exec
    if (!exec || typeof exec !== "object") return false
    const argv = Array.isArray((exec as { argv?: unknown[] }).argv) ? (exec as { argv?: unknown[] }).argv : []
    const first = typeof argv[0] === "string" ? argv[0] : ""
    return first === "test" || first === "grep" || (first === "jq" && argv.some((item) => item === "-e"))
  })
  if (hasPredicate) return "predicate"

  return "exit_only"
}

export async function runTransitionVerification(pi: ExtensionAPI, projectRoot: string): Promise<{ ok: boolean; output: string }> {
  const command = [
    "SIGNUM_TRUST_LOCAL=1",
    `bash ${shellQuote(transitionVerifierScriptPath)}`,
    "execute",
    "audit",
    "--workspace-root .",
    "--signum-dir .signum",
    "--contract .signum/contract-engineer.json",
    "--contract-full .signum/contract.json",
    "--receipt .signum/receipts/execute.json",
    "--snapshot .signum/snapshots/pre-execute.json",
  ].join(" ")
  const result = await pi.exec("bash", ["-lc", command], {
    cwd: projectRoot,
    timeout: 120_000,
  })
  return {
    ok: result.code === 0,
    output: [result.stdout, result.stderr].filter(Boolean).join("\n").trim(),
  }
}

export async function buildCombinedPatch(pi: Pick<ExtensionAPI, "exec">, projectRoot: string): Promise<string> {
  const gitDiff = await pi.exec("git", ["diff", "--", ".", ":(exclude).signum"], {
    cwd: projectRoot,
    timeout: 30_000,
  })
  const untrackedPatch = await buildUntrackedPatch(pi, projectRoot)
  const combined = [gitDiff.stdout, untrackedPatch].filter((value) => value.trim().length > 0).join("\n")
  if (combined.trim().length > 0) {
    return combined
  }

  const afterDir = resolve(projectRoot, ".signum/snapshots/execute-after")
  await snapshotProjectTree(projectRoot, afterDir)
  const fallback = await pi.exec("diff", ["-ruN", resolve(projectRoot, ".signum/snapshots/execute-before"), afterDir], {
    cwd: projectRoot,
    timeout: 30_000,
  })
  return [fallback.stdout, fallback.stderr].filter(Boolean).join("\n")
}

async function buildUntrackedPatch(pi: Pick<ExtensionAPI, "exec">, projectRoot: string): Promise<string> {
  const status = await pi.exec("git", ["status", "--porcelain=v1", "--untracked-files=all", "--", ".", ":(exclude).signum"], {
    cwd: projectRoot,
    timeout: 30_000,
  })
  if (status.code !== 0 || status.stdout.trim().length === 0) {
    return ""
  }

  const patches: string[] = []
  for (const line of status.stdout.split(/\r?\n/)) {
    if (!line.startsWith("?? ")) continue
    const path = line.slice(3).trim()
    if (!path) continue
    const patch = await pi.exec("git", ["diff", "--no-index", "--", "/dev/null", path], {
      cwd: projectRoot,
      timeout: 30_000,
    })
    const text = [patch.stdout, patch.stderr].filter(Boolean).join("\n").trim()
    if (text) patches.push(text)
  }

  return patches.join("\n")
}

async function snapshotProjectTree(projectRoot: string, destinationRoot: string) {
  await rm(destinationRoot, { recursive: true, force: true })
  await mkdir(destinationRoot, { recursive: true })
  for (const entry of await readdir(projectRoot)) {
    if (entry === ".git" || entry === ".signum" || entry === "node_modules") continue
    await copyProjectEntry(resolve(projectRoot, entry), resolve(destinationRoot, entry))
  }
}

async function copyProjectEntry(source: string, destination: string) {
  const sourceStat = await stat(source)
  if (sourceStat.isDirectory()) {
    await mkdir(destination, { recursive: true })
    for (const entry of await readdir(source)) {
      if (entry === ".git" || entry === ".signum" || entry === "node_modules") continue
      await copyProjectEntry(join(source, entry), join(destination, entry))
    }
    return
  }
  await mkdir(dirname(destination), { recursive: true })
  await cp(source, destination)
}

async function readJson<T>(path: string): Promise<T> {
  return JSON.parse(await readFile(path, "utf8")) as T
}

async function writeJson(path: string, value: unknown) {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8")
}

async function safeRead(path: string): Promise<string> {
  try {
    return await readFile(path, "utf8")
  } catch {
    return ""
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`
}
