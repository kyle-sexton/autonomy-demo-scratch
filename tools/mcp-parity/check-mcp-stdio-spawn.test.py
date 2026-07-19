#!/usr/bin/env python3
"""Tests for tools/mcp-parity/check-mcp-stdio-spawn.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path


def _load_module() -> object:
    script_path = Path(__file__).resolve().parent / "check-mcp-stdio-spawn.py"
    spec = importlib.util.spec_from_file_location("spawn_check", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load spec for {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


spawn_check = _load_module()
REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_SOURCE = REPO_ROOT / "tools/schemas/mcp-tier3-spawn.json"


def _contract_kwargs(repo_root: Path) -> dict[str, object]:
    launcher_path, fnm_exec_prefix, forbidden_commands = spawn_check._spawn_contract(
        repo_root,
    )
    return {
        "launcher_path": launcher_path,
        "fnm_exec_prefix": fnm_exec_prefix,
        "forbidden_commands": forbidden_commands,
    }


def _valid_tier3(name: str, suffix: list[str]) -> dict:
    return {
        "type": "stdio",
        "command": "fnm",
        "args": [
            "exec",
            "--version-file-strategy=recursive",
            "--using=.nvmrc",
            "--",
            "node",
            "tools/mcp-launcher/launcher.js",
            *suffix,
        ],
        "env": {"MCP_LAUNCHER_FNM_ACTIVE": "1"},
    }


def _write_spawn_schema(root: Path) -> None:
    schema_dir = root / "tools/schemas"
    schema_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SCHEMA_SOURCE, schema_dir / "mcp-tier3-spawn.json")


class SpawnShapeTests(unittest.TestCase):
    def test_valid_tier3_passes(self) -> None:
        failures = spawn_check._failures_for_server(
            "ccusage",
            _valid_tier3("ccusage", ["-y", "@ccusage/mcp@18.0.11"]),
            **_contract_kwargs(REPO_ROOT),
        )
        self.assertEqual(failures, [])

    def test_bash_command_fails(self) -> None:
        server = _valid_tier3("x", ["-y", "@x/mcp@1.0.0"])
        server["command"] = "bash"
        failures = spawn_check._failures_for_server(
            "x",
            server,
            **_contract_kwargs(REPO_ROOT),
        )
        self.assertTrue(any("command 'fnm'" in item for item in failures))

    def test_missing_fnm_active_fails(self) -> None:
        server = _valid_tier3("x", ["-y", "@x/mcp@1.0.0"])
        server["env"] = {}
        failures = spawn_check._failures_for_server(
            "x",
            server,
            **_contract_kwargs(REPO_ROOT),
        )
        self.assertTrue(any("MCP_LAUNCHER_FNM_ACTIVE" in item for item in failures))

    def test_native_stdio_skipped(self) -> None:
        server = {"type": "stdio", "command": "dotnet", "args": ["dnx"]}
        self.assertEqual(
            spawn_check._failures_for_server(
                "nuget",
                server,
                **_contract_kwargs(REPO_ROOT),
            ),
            [],
        )

    def test_run_against_repo_root(self) -> None:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            exit_code = spawn_check.run(REPO_ROOT)
        self.assertEqual(exit_code, 0)
        self.assertIn("passed", buf.getvalue())

    def test_run_invalid_fixture_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_spawn_schema(root)
            payload = {
                "mcpServers": {
                    "bad": {
                        "type": "stdio",
                        "command": "node",
                        "args": ["tools/mcp-launcher/launcher.js", "-y", "@x@1"],
                    },
                },
            }
            (root / ".mcp.json").write_text(json.dumps(payload), encoding="utf-8")
            exit_code = spawn_check.run(root)
            self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()
