import type { AgentOutputParser } from "./types.js";

export const plainTextOutputParser: AgentOutputParser = {
  formatLabel: "text",
  referencesLogFile: false,
  extractSentinelScanText(log: string): string {
    return log;
  },
};
