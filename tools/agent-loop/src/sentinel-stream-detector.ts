import { extractGrokScanText } from "./output-parsers/grok-json.js";
import { extractStreamResultText } from "./output-parsers/stream-json-terminal-result.js";
import { logContainsSentinel } from "./sentinel.js";
import type { AgentOutputFormat } from "./types.js";

export interface SentinelStreamDetector {
  /** True when canonical agent output contains a valid completion sentinel. */
  scan(capturedOutput: string): boolean;
}

/**
 * Mid-run sentinel detection must match post-run parsing.
 * stream-json: only the terminal `result` event (prompt echo must not trigger grace).
 */
export function createSentinelStreamDetector(
  outputFormat: AgentOutputFormat | undefined,
): SentinelStreamDetector {
  if (outputFormat === "stream-json") {
    return {
      scan(capturedOutput: string): boolean {
        const resultText = extractStreamResultText(capturedOutput);
        if (resultText !== undefined && logContainsSentinel(resultText)) {
          return true;
        }
        const grokText = extractGrokScanText(capturedOutput);
        if (grokText.length > 0 && logContainsSentinel(grokText)) {
          return true;
        }
        return false;
      },
    };
  }

  return {
    scan(capturedOutput: string): boolean {
      return logContainsSentinel(capturedOutput);
    },
  };
}
