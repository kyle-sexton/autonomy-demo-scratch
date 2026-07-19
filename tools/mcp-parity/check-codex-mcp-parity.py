#!/usr/bin/env python3
"""Validate MCP parity between .mcp.json and .codex/config.toml.

This is a read-only drift check intended for CI and local verification.
It ensures server identity, transport shape, command/url targets, package pins,
and required environment variable names stay aligned.
"""

from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any, cast

ALLOWED_CODEX_ONLY = {"atlassian", "figma", "granola"}

PLACEHOLDER_PATTERN = re.compile(r"\$\{([A-Z0-9_]+)(?::-([^}]*))?\}")
PACKAGE_PIN_PATTERN = re.compile(r"^(@?[^@]+(?:/[^@]+)?@[^@]+)$")


def _resolve_placeholders(value: str) -> str:
    def replacer(match: re.Match[str]) -> str:
        default = match.group(2)
        return default if default is not None else ""

    return PLACEHOLDER_PATTERN.sub(replacer, value)


def _normalize_args(raw_args: list[Any]) -> list[str]:
    return [_resolve_placeholders(str(argument)) for argument in raw_args]


def _extract_package_pins(args: list[str]) -> set[str]:
    return {token for token in args if PACKAGE_PIN_PATTERN.match(token)}


def _extract_env_names_from_value(value: Any) -> set[str]:
    if not isinstance(value, str):
        return set()
    return {match.group(1) for match in PLACEHOLDER_PATTERN.finditer(value)}


def _mcp_env_names(server_config: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for key, value in server_config.get("env", {}).items():
        names.add(str(key))
        names.update(_extract_env_names_from_value(value))
    for value in server_config.get("headers", {}).values():
        names.update(_extract_env_names_from_value(value))
    return names


def _codex_env_names(server_config: dict[str, Any]) -> set[str]:
    names: set[str] = {str(value) for value in server_config.get("env_vars", [])}
    env_table = server_config.get("env", {})
    if isinstance(env_table, dict):
        env_names = cast(dict[str, Any], env_table)
        names.update(str(key) for key in env_names)
    names.update(
        str(value) for value in server_config.get("env_http_headers", {}).values()
    )
    bearer_env = server_config.get("bearer_token_env_var")
    if bearer_env is not None:
        names.add(str(bearer_env))
    return names


def _failures_for_server(
    name: str,
    mcp_server: dict[str, Any],
    codex_server: dict[str, Any],
) -> list[str]:
    failures: list[str] = []

    mcp_type = mcp_server.get("type")
    if mcp_type == "http":
        if "url" not in codex_server:
            failures.append(f"{name}: expected HTTP url in .codex/config.toml")
        else:
            mcp_url = _resolve_placeholders(str(mcp_server.get("url", "")))
            codex_url = str(codex_server.get("url", ""))
            if mcp_url != codex_url:
                failures.append(
                    f"{name}: url mismatch (.mcp.json='{mcp_url}', .codex/config.toml='{codex_url}')",
                )
    elif mcp_type == "stdio":
        mcp_command = str(mcp_server.get("command", ""))
        codex_command = str(codex_server.get("command", ""))
        if mcp_command != codex_command:
            failures.append(
                f"{name}: command mismatch (.mcp.json='{mcp_command}', .codex/config.toml='{codex_command}')",
            )

        mcp_args = _normalize_args(mcp_server.get("args", []))
        codex_args = [str(argument) for argument in codex_server.get("args", [])]
        if mcp_args != codex_args:
            failures.append(
                f"{name}: args mismatch (.mcp.json={mcp_args}, .codex/config.toml={codex_args})",
            )

        mcp_pins = _extract_package_pins(mcp_args)
        codex_pins = _extract_package_pins(codex_args)
        if mcp_pins != codex_pins:
            failures.append(
                f"{name}: package pin mismatch (.mcp.json={sorted(mcp_pins)}, .codex/config.toml={sorted(codex_pins)})",
            )
    else:
        failures.append(f"{name}: unsupported type in .mcp.json: {mcp_type!r}")

    mcp_env = _mcp_env_names(mcp_server)
    codex_env = _codex_env_names(codex_server)
    if mcp_env != codex_env:
        failures.append(
            f"{name}: env name mismatch (.mcp.json={sorted(mcp_env)}, .codex/config.toml={sorted(codex_env)})",
        )

    return failures


def run(repo_root: Path) -> int:
    mcp_path = repo_root / ".mcp.json"
    codex_path = repo_root / ".codex" / "config.toml"

    mcp_payload = json.loads(mcp_path.read_text(encoding="utf-8"))
    codex_payload = tomllib.loads(codex_path.read_text(encoding="utf-8"))

    mcp_servers_raw = mcp_payload.get("mcpServers", {})
    codex_servers_raw = codex_payload.get("mcp_servers", {})
    if not isinstance(mcp_servers_raw, dict):
        print("Invalid .mcp.json: mcpServers must be an object", file=sys.stderr)
        return 1
    if not isinstance(codex_servers_raw, dict):
        print(
            "Invalid .codex/config.toml: mcp_servers must be a table", file=sys.stderr
        )
        return 1
    mcp_servers = cast(dict[str, Any], mcp_servers_raw)
    codex_servers = cast(dict[str, Any], codex_servers_raw)

    # Codex servers with `enabled = false` are documented opt-outs (see
    # `.codex/mcp-servers.md` "Configured but Disabled"). Treat them like
    # ALLOWED_CODEX_ONLY for the missing-in-mcp check — they may exist in
    # codex config as scaffolding for user/profile overrides without a
    # corresponding `.mcp.json` entry.
    codex_disabled: set[str] = set()
    for name, config_raw in codex_servers.items():
        if isinstance(config_raw, dict):
            config = cast(dict[str, Any], config_raw)
            if config.get("enabled") is False:
                codex_disabled.add(name)

    mcp_names = set(mcp_servers)
    codex_names = set(codex_servers)

    failures: list[str] = [
        f"{name}: present in .mcp.json but missing in .codex/config.toml"
        for name in sorted(mcp_names - codex_names)
    ]
    failures.extend(
        f"{name}: present in .codex/config.toml but missing in .mcp.json"
        for name in sorted(
            (codex_names - mcp_names) - ALLOWED_CODEX_ONLY - codex_disabled,
        )
    )

    for name in sorted(mcp_names & codex_names):
        failures.extend(
            _failures_for_server(name, mcp_servers[name], codex_servers[name]),
        )

    if failures:
        print("Codex MCP parity check failed:")
        for failure in failures:
            print(f"- {failure}")
        print()
        print(
            "Fix drift between .mcp.json and .codex/config.toml, or document intentional differences in .codex/mcp-servers.md.",
        )
        return 1

    print("Codex MCP parity check passed.")
    return 0


def main() -> int:
    if len(sys.argv) > 2:
        print(
            "Usage: python tools/mcp-parity/check-codex-mcp-parity.py [repo-root]",
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
