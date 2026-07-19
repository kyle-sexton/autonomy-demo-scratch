import type { AgentCliAdapter, AgentCliKind } from "../types.js";
import { claudeAdapter } from "./claude.js";
import { codexAdapter } from "./codex.js";
import { cursorAdapter } from "./cursor.js";
import { grokAdapter } from "./grok.js";

const adapters: Partial<Record<AgentCliKind, AgentCliAdapter>> = {
  claude: claudeAdapter,
  codex: codexAdapter,
  cursor: cursorAdapter,
  grok: grokAdapter,
};

export function selectAdapter(cli: AgentCliKind): AgentCliAdapter {
  const adapter = adapters[cli];
  if (adapter === undefined) {
    const implemented = Object.keys(adapters).join(", ");
    throw new Error(`No adapter for CLI "${cli}". Implemented: ${implemented}.`);
  }
  return adapter;
}
