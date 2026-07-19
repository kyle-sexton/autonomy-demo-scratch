/**
 * Parses one iteration's agent stdout for sentinel, usage, and sidecar artifacts.
 * Vendor-specific shapes live in per-format modules; orchestrator dispatches via registry.
 */
export interface AgentOutputParser {
  /** Log label for orchestrator reference lines (e.g. stream-json, text). */
  readonly formatLabel: string;
  /** When true, orchestrator.log links to the iter log instead of inlining body. */
  readonly referencesLogFile: boolean;
  /** Text scanned for the completion sentinel — may differ from raw log (NDJSON result event). */
  extractSentinelScanText(log: string): string;
  extractUsage?(log: string): Record<string, unknown> | undefined;
  extractToolSidecarLines?(log: string): string[];
}
