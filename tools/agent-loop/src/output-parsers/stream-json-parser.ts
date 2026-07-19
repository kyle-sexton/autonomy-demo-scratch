import {
  extractStreamResultText,
  extractStreamUsage,
  extractToolSidecarLines,
} from "./stream-json-terminal-result.js";
import type { AgentOutputParser } from "./types.js";

export const streamJsonOutputParser: AgentOutputParser = {
  formatLabel: "stream-json",
  referencesLogFile: true,
  extractSentinelScanText(log: string): string {
    return extractStreamResultText(log) ?? "";
  },
  extractUsage: extractStreamUsage,
  extractToolSidecarLines: extractToolSidecarLines,
};
