import type { ExtensionAPI } from "@mariozechner/pi-coding-agent"

import { runSignumCommand } from "./orchestrator.ts"

export default function signumPiExtension(pi: ExtensionAPI) {
  pi.registerCommand("signum", {
    description: "Run Signum inside pi",
    handler: async (args, ctx) => {
      const result = await runSignumCommand(pi, args, ctx)

      pi.sendMessage({
        customType: "signum",
        content: result.message,
        display: true,
        details: {
          ...result.details,
          kind: result.kind,
          timestamp: Date.now(),
        },
      })
    },
  })
}
