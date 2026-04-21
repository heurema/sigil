import { writeContractIndex, readContractIndex, resolveContractId, updateContractStatus, setContractTimestampField, clearActiveContract } from "../runtime/script-adapters/contract-dir.ts"

export async function runClosePhase(projectRoot: string, requestedContractId?: string): Promise<string> {
  const index = await readContractIndex(projectRoot)
  const contractId = resolveContractId(index, requestedContractId)
  const closedAt = toUtcTimestamp()

  const nextIndex = clearActiveContract(
    setContractTimestampField(updateContractStatus(index, contractId, "closed"), contractId, "closedAt", closedAt),
    contractId,
  )

  await writeContractIndex(projectRoot, nextIndex)

  const lines = []
  if (index.activeContractId === contractId) {
    lines.push(`Cleared active contract (was ${contractId})`)
  }
  lines.push(`Closed: ${contractId} at ${closedAt}`)
  lines.push("No proofpack generated. Contract directory preserved for reference.")

  return lines.join("\n")
}

function toUtcTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z")
}
