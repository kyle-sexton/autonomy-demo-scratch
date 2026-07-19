#!/usr/bin/env python3
"""Validate tier-3 MCP stdio spawn shape in .mcp.json (ADR 0014).

Read-only drift check: launcher-backed servers must use fnm exec + launcher.js
and MCP_LAUNCHER_FNM_ACTIVE=1. See docs/mcp/mcp-stdio-spawn.md.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, cast

SCHEMA_RELATIVE = Path("tools/schemas/mcp-tier3-spawn.json")


def _load_spawn_contract(repo_root: Path) -> dict[str, Any]:
    schema_path = repo_root / SCHEMA_RELATIVE
    payload = json.loads(schema_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{SCHEMA_RELATIVE}: root must be an object")
    return cast(dict[str, Any], payload)


def _spawn_contract(repo_root: Path) -> tuple[str, list[str]]:
    contract = _load_spawn_contract(repo_root)
    launcher_path = str(contract.get("launcherPath", "tools/mcp-launcher/launcher.js"))
    prefix_raw = contract.get("fnmExecPrefix", [])
    if not isinstance(prefix_raw, list):
        raise ValueError(f"{SCHEMA_RELATIVE}: fnmExecPrefix must be an array")
    fnm_exec_prefix = [str(item) for item in cast(list[Any], prefix_raw)]
    return launcher_path, fnm_exec_prefix


def _uses_launcher(args: list[Any], launcher_path: str) -> bool:
    return launcher_path in [str(arg) for arg in args]


def _failures_for_server(
    name: str,
    server: dict[str, Any],
    *,
    launcher_path: str,
    fnm_exec_prefix: list[str],
) -> list[str]:
    if server.get("type") != "stdio":
        return []

    args = [str(arg) for arg in server.get("args", [])]
    if not _uses_launcher(args, launcher_path):
        return []

    failures: list[str] = []
    command = str(server.get("command", ""))

    if command != "fnm":
        failures.append(
            f"{name}: tier-3 server must use command 'fnm' (got {command!r})",
        )

    if args[: len(fnm_exec_prefix)] != fnm_exec_prefix:
        failures.append(
            f"{name}: args must start with fnm exec prefix "
            f"{fnm_exec_prefix!r} (got {args[: len(fnm_exec_prefix)]!r})",
        )

    env_raw: Any = server.get("env", {})
    if not isinstance(env_raw, dict):
        failures.append(f"{name}: env must be an object when using launcher")
    else:
        env = cast(dict[str, Any], env_raw)
        if env.get("MCP_LAUNCHER_FNM_ACTIVE") != "1":
            failures.append(
                f"{name}: env.MCP_LAUNCHER_FNM_ACTIVE must be '1' "
                f"(got {env.get('MCP_LAUNCHER_FNM_ACTIVE')!r})",
            )

    return failures


def run(repo_root: Path) -> int:
    try:
        launcher_path, fnm_exec_prefix = _spawn_contract(repo_root)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"MCP stdio spawn check failed: {error}", file=sys.stderr)
        return 1

    mcp_path = repo_root / ".mcp.json"
    payload = json.loads(mcp_path.read_text(encoding="utf-8"))
    servers_raw = payload.get("mcpServers", {})
    if not isinstance(servers_raw, dict):
        print("Invalid .mcp.json: mcpServers must be an object", file=sys.stderr)
        return 1

    servers = cast(dict[str, Any], servers_raw)
    failures: list[str] = []
    for name, config in servers.items():
        if isinstance(config, dict):
            failures.extend(
                _failures_for_server(
                    name,
                    cast(dict[str, Any], config),
                    launcher_path=launcher_path,
                    fnm_exec_prefix=fnm_exec_prefix,
                ),
            )

    if failures:
        print("MCP stdio spawn check failed:")
        for failure in failures:
            print(f"- {failure}")
        print()
        print(
            "See docs/mcp/mcp-stdio-spawn.md and docs/adr/0014-mcp-stdio-fnm-launcher-spawn.md"
        )
        return 1

    print("MCP stdio spawn check passed.")
    return 0


def main() -> int:
    if len(sys.argv) > 2:
        print(
            "Usage: python tools/mcp-parity/check-mcp-stdio-spawn.py [repo-root]",
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
