import type { AgentCliKind, AgentOutputFormat } from "../types.js";
import { codexJsonOutputParser } from "./codex-json.js";
import { grokJsonOutputParser } from "./grok-json.js";
import { plainTextOutputParser } from "./plain-text.js";
import { streamJsonOutputParser } from "./stream-json-parser.js";
import type { AgentOutputParser } from "./types.js";

/** CLIs that emit NDJSON with a terminal `result` event when format is stream-json. */
const STREAM_JSON_TERMINAL_RESULT_CLIS: ReadonlySet<AgentCliKind> = new Set(["cursor", "claude"]);

/**
 * Select output parser for one iteration.
 * Orchestrator never imports vendor stream modules directly.
 */
export function selectOutputParser(
  cli: AgentCliKind,
  outputFormat: AgentOutputFormat | undefined,
): AgentOutputParser {
  if (cli === "codex") {
    return codexJsonOutputParser;
  }
  if (cli === "grok") {
    if (outputFormat === "stream-json" || outputFormat === "json") {
      return grokJsonOutputParser;
    }
    return plainTextOutputParser;
  }
  if (outputFormat === "stream-json" && STREAM_JSON_TERMINAL_RESULT_CLIS.has(cli)) {
    return streamJsonOutputParser;
  }
  return plainTextOutputParser;
}
