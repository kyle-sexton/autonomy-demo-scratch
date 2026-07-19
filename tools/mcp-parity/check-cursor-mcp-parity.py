#!/usr/bin/env python3
"""Validate MCP parity between .mcp.json (SSOT) and .cursor/mcp.json (Cursor IDE).

Read-only drift check for CI and local verification. Cursor does not read the
repo-root .mcp.json file; it loads project MCP servers from .cursor/mcp.json
per https://cursor.com/docs/context/mcp — keep both files identical.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def run(repo_root: Path) -> int:
    source_path = repo_root / ".mcp.json"
    cursor_path = repo_root / ".cursor" / "mcp.json"

    if not cursor_path.is_file():
        print("Cursor MCP parity check failed:")
        print("- .cursor/mcp.json is missing (copy from .mcp.json)")
        return 1

    source_payload = json.loads(source_path.read_text(encoding="utf-8"))
    cursor_payload = json.loads(cursor_path.read_text(encoding="utf-8"))

    if source_payload == cursor_payload:
        print("Cursor MCP parity check passed.")
        return 0

    source_servers = source_payload.get("mcpServers", {})
    cursor_servers = cursor_payload.get("mcpServers", {})
    source_names = set(source_servers)
    cursor_names = set(cursor_servers)

    failures: list[str] = [
        f"{name}: present in .mcp.json but missing in .cursor/mcp.json"
        for name in sorted(source_names - cursor_names)
    ]
    failures.extend(
        f"{name}: present in .cursor/mcp.json but missing in .mcp.json"
        for name in sorted(cursor_names - source_names)
    )

    for name in sorted(source_names & cursor_names):
        if source_servers[name] != cursor_servers[name]:
            failures.append(
                f"{name}: server block differs between .mcp.json and .cursor/mcp.json"
            )

    print("Cursor MCP parity check failed:")
    for failure in failures:
        print(f"- {failure}")
    print()
    print("Update .cursor/mcp.json to match .mcp.json (SSOT), then re-run this check.")
    return 1


def main() -> int:
    if len(sys.argv) > 2:
        print(
            "Usage: python tools/mcp-parity/check-cursor-mcp-parity.py [repo-root]",
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
