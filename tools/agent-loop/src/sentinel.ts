import type { Sentinel } from "./types.js";

const PROMISE_PATTERN = /<promise>(CONTINUE|NO_MORE_TASKS)<\/promise>/g;

/**
 * Parse the Ralph completion sentinel from an iteration's captured log.
 *
 * Returns the LAST valid occurrence — an iteration prints the token as its final
 * line, and loop.sh selects it with `grep ... | tail -1` — or null when no valid
 * token is present. Unknown or malformed tokens are ignored.
 */
export function parseSentinel(log: string): Sentinel | null {
  let last: Sentinel | null = null;
  for (const match of log.matchAll(PROMISE_PATTERN)) {
    const value = match[1];
    if (value === "CONTINUE" || value === "NO_MORE_TASKS") {
      last = value;
    }
  }
  return last;
}

/** True when any valid sentinel token appears in captured output (mid-run detection). */
export function logContainsSentinel(log: string): boolean {
  return parseSentinel(log) !== null;
}
