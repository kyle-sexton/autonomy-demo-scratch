#!/usr/bin/env python3
"""Print Cursor IDE MCP enable/disable checklist from Claude Code team defaults.

Cursor has no in-repo MCP allowlist. This read-only script reads
.claude/settings.json (enabledMcpjsonServers / disabledMcpjsonServers) and
prints the Settings → Tools & MCP toggle state developers should match.

Does not modify Cursor configuration.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def run(repo_root: Path) -> int:
    mcp_path = repo_root / ".mcp.json"
    settings_path = repo_root / ".claude" / "settings.json"

    if not mcp_path.is_file():
        print("Cursor MCP policy check failed: .mcp.json is missing", file=sys.stderr)
        return 1
    if not settings_path.is_file():
        print(
            "Cursor MCP policy check failed: .claude/settings.json is missing",
            file=sys.stderr,
        )
        return 1

    registry = json.loads(mcp_path.read_text(encoding="utf-8"))
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    all_servers = sorted(registry.get("mcpServers", {}))
    enabled = sorted(settings.get("enabledMcpjsonServers", []))
    disabled = sorted(settings.get("disabledMcpjsonServers", []))

    unknown_enabled = sorted(set(enabled) - set(all_servers))
    unknown_disabled = sorted(set(disabled) - set(all_servers))
    unclassified = sorted(set(all_servers) - set(enabled) - set(disabled))

    if unknown_enabled or unknown_disabled:
        print("Cursor MCP policy check failed:", file=sys.stderr)
        for name in unknown_enabled:
            print(
                f"- enabledMcpjsonServers lists unknown server: {name}", file=sys.stderr
            )
        for name in unknown_disabled:
            print(
                f"- disabledMcpjsonServers lists unknown server: {name}",
                file=sys.stderr,
            )
        return 1

    if unclassified:
        print("Cursor MCP policy check failed:", file=sys.stderr)
        for name in unclassified:
            print(
                f"- {name}: in .mcp.json but not in enabledMcpjsonServers or disabledMcpjsonServers",
                file=sys.stderr,
            )
        return 1

    print("Cursor MCP policy (match in Settings -> Tools & MCP):\n")
    print("ENABLE:")
    for name in enabled:
        print(f"  [ON]  {name}")
    print("\nDISABLE:")
    for name in disabled:
        print(f"  [OFF] {name}")

    print("\nPlugin dedup (Cursor Settings - not in .claude/settings.json):")
    print("  [OFF] Context7 marketplace plugin  ->  keep project context7 server")
    print("  [OFF] Azure marketplace plugins    ->  per .claude/rules/azure-setup.md")
    print(
        "  [OFF] Playwright MCP plugin        ->  use cursor-ide-browser / Browse plugin"
    )
    print("  [ON]  cursor-ide-browser (built-in) for browser work")

    print("\nRegistry parity:")
    print("  python tools/mcp-parity/check-cursor-mcp-parity.py")
    print("\nFull setup: docs/cursor/setup.md")
    return 0


def main() -> int:
    if len(sys.argv) > 2:
        print(
            "Usage: python tools/mcp-parity/check-cursor-mcp-policy.py [repo-root]",
            file=sys.stderr,
        )
        return 2

    repo_root = (
        Path(sys.argv[1]).resolve()
        if len(sys.argv) == 2
        else Path(__file__).resolve().parents[2]
    )
    return run(repo_root)


if __name__ == "__main__":
    raise SystemExit(main())
