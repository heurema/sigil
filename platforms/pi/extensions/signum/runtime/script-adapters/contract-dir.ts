import { mkdir, readFile, writeFile } from "node:fs/promises"

import { toUtcTimestamp } from "./checks.ts"
import { dirname, resolve } from "node:path"

export interface ContractIndexRecord {
  contractId: string
  status: string
  directory?: string
  createdAt?: string
  archivedAt?: string
  closedAt?: string
  [key: string]: unknown
}

export interface ContractIndex {
  activeContractId: string | null
  contracts: ContractIndexRecord[]
}

export interface SignumContractLike {
  contractId: string
  goal?: string
  inScope?: string[]
  assumptions?: Array<string | { text?: string }>
}

export function contractDirRelative(contractId: string): string {
  assertValidContractId(contractId)
  return `.signum/contracts/${contractId}/`
}

export function contractDirPath(projectRoot: string, contractId: string): string {
  assertValidContractId(contractId)
  return resolve(projectRoot, ".signum", "contracts", contractId)
}

export function archiveDirPath(projectRoot: string, contractId: string): string {
  assertValidContractId(contractId)
  return resolve(projectRoot, ".signum", "archive", contractId)
}

export function contractIndexPath(projectRoot: string): string {
  return resolve(projectRoot, ".signum", "contracts", "index.json")
}

export async function ensureContractIndex(projectRoot: string): Promise<ContractIndex> {
  const existing = await readContractIndexIfExists(projectRoot)
  if (existing) return existing

  const emptyIndex: ContractIndex = {
    activeContractId: null,
    contracts: [],
  }
  await writeContractIndex(projectRoot, emptyIndex)
  return emptyIndex
}

export async function readContractIndex(projectRoot: string): Promise<ContractIndex> {
  const path = contractIndexPath(projectRoot)
  const raw = await readFile(path, "utf8")
  const parsed = JSON.parse(raw) as ContractIndex

  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.contracts)) {
    throw new Error(`Invalid contract index: ${path}`)
  }

  return parsed
}

export async function readContractIndexIfExists(projectRoot: string): Promise<ContractIndex | null> {
  try {
    return await readContractIndex(projectRoot)
  } catch {
    return null
  }
}

export async function writeContractIndex(projectRoot: string, index: ContractIndex): Promise<void> {
  const path = contractIndexPath(projectRoot)
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, `${JSON.stringify(index, null, 2)}\n`, "utf8")
}

export function getActiveContractId(index: ContractIndex): string | undefined {
  return index.activeContractId ?? undefined
}

export function resolveContractId(index: ContractIndex, provided?: string): string {
  const contractId = provided?.trim() || index.activeContractId || ""
  if (!contractId) {
    throw new Error("No contract ID provided and no active contract found")
  }
  assertValidContractId(contractId)
  return contractId
}

export function getContractRecord(index: ContractIndex, contractId: string): ContractIndexRecord {
  const record = index.contracts.find((item) => item.contractId === contractId)
  if (!record) {
    throw new Error(`Contract ID not found in index: ${contractId}`)
  }
  return record
}

export function updateContractStatus(index: ContractIndex, contractId: string, status: string): ContractIndex {
  getContractRecord(index, contractId)

  return {
    ...index,
    contracts: index.contracts.map((item) =>
      item.contractId === contractId
        ? {
            ...item,
            status,
          }
        : item,
    ),
  }
}

export function setContractTimestampField(
  index: ContractIndex,
  contractId: string,
  field: "archivedAt" | "closedAt",
  value: string,
): ContractIndex {
  getContractRecord(index, contractId)

  return {
    ...index,
    contracts: index.contracts.map((item) =>
      item.contractId === contractId
        ? {
            ...item,
            [field]: value,
          }
        : item,
    ),
  }
}

export async function initContractDirectory(projectRoot: string, contractId: string): Promise<string> {
  const path = contractDirPath(projectRoot, contractId)
  await mkdir(resolve(path, "reviews"), { recursive: true })
  return path
}

export function registerContract(index: ContractIndex, contract: SignumContractLike, status = "draft"): ContractIndex {
  const createdAt = toUtcTimestamp()
  const record: ContractIndexRecord = {
    contractId: contract.contractId,
    status,
    createdAt,
    directory: contractDirRelative(contract.contractId),
    goal: contract.goal ?? "",
    inScope: contract.inScope ?? [],
    assumptions: (contract.assumptions ?? []).map((assumption) =>
      typeof assumption === "string" ? assumption : assumption.text ?? "",
    ),
  }

  const existing = index.contracts.find((item) => item.contractId === contract.contractId)
  return {
    ...index,
    activeContractId: contract.contractId,
    contracts: existing
      ? index.contracts.map((item) => (item.contractId === contract.contractId ? { ...item, ...record } : item))
      : [...index.contracts, record],
  }
}

export function clearActiveContract(index: ContractIndex, contractId: string): ContractIndex {
  if (index.activeContractId !== contractId) {
    return index
  }

  return {
    ...index,
    activeContractId: null,
  }
}

function assertValidContractId(contractId: string) {
  if (!contractId) {
    throw new Error("contractId is required")
  }
  if (contractId.includes("/") || contractId.includes("..")) {
    throw new Error(`Invalid contract ID: ${contractId}`)
  }
}
