#!/usr/bin/env python3
"""Tests for tools/mcp-parity/check-codex-mcp-parity.py.

Run from repo root:

    python tools/check-codex-mcp-parity.test.py

Filename uses the `<script>.test.py` convention to match the sibling
`*.test.sh` shell-test pattern in this directory.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import textwrap
import unittest
from pathlib import Path


def _load_parity_module() -> object:
    script_path = Path(__file__).resolve().parent / "check-codex-mcp-parity.py"
    spec = importlib.util.spec_from_file_location("parity_under_test", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load spec for {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


parity = _load_parity_module()


def _write_fixture(root: Path, mcp_payload: dict, codex_payload_toml: str) -> None:
    (root / ".codex").mkdir(parents=True, exist_ok=True)
    (root / ".mcp.json").write_text(json.dumps(mcp_payload), encoding="utf-8")
    (root / ".codex" / "config.toml").write_text(codex_payload_toml, encoding="utf-8")


def _run_capture(root: Path) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exit_code = parity.run(root)
    return exit_code, buf.getvalue()


class HelperFunctionTests(unittest.TestCase):
    def test_resolve_placeholders_default_value(self) -> None:
        self.assertEqual(parity._resolve_placeholders("${FOO:-bar}"), "bar")

    def test_resolve_placeholders_missing_default(self) -> None:
        self.assertEqual(parity._resolve_placeholders("${FOO}"), "")

    def test_resolve_placeholders_no_placeholder(self) -> None:
        self.assertEqual(parity._resolve_placeholders("plain"), "plain")

    def test_extract_package_pins_npm_scoped(self) -> None:
        args = ["-y", "@perplexity-ai/mcp-server@0.9.0", "--flag"]
        self.assertEqual(
            parity._extract_package_pins(args), {"@perplexity-ai/mcp-server@0.9.0"}
        )

    def test_extract_package_pins_bare_name_no_match(self) -> None:
        # No `@<version>` token → no pin captured.
        self.assertEqual(
            parity._extract_package_pins(["-y", "chrome-devtools-mcp"]), set()
        )

    def test_mcp_env_names_includes_headers_and_env(self) -> None:
        server = {
            "env": {"TOKEN_A": "${TOKEN_A}"},
            "headers": {"Authorization": "Bearer ${TOKEN_B}"},
        }
        self.assertEqual(parity._mcp_env_names(server), {"TOKEN_A", "TOKEN_B"})

    def test_codex_env_names_env_vars_list(self) -> None:
        server = {"env_vars": ["X", "Y"]}
        self.assertEqual(parity._codex_env_names(server), {"X", "Y"})

    def test_codex_env_names_env_table(self) -> None:
        server = {"env": {"K": "v"}}
        self.assertEqual(parity._codex_env_names(server), {"K"})

    def test_codex_env_names_env_http_headers(self) -> None:
        server = {"env_http_headers": {"x-api-key": "MY_KEY"}}
        self.assertEqual(parity._codex_env_names(server), {"MY_KEY"})

    def test_codex_env_names_bearer_token_env_var(self) -> None:
        # Codex 0.125.0+ dedicated bearer-token field — must be counted as
        # an authenticating env-var name for parity purposes.
        server = {"bearer_token_env_var": "GH_TOKEN"}
        self.assertEqual(parity._codex_env_names(server), {"GH_TOKEN"})

    def test_codex_env_names_combined_sources(self) -> None:
        server = {
            "env_vars": ["A"],
            "env": {"B": "v"},
            "env_http_headers": {"x-h": "C"},
            "bearer_token_env_var": "D",
        }
        self.assertEqual(parity._codex_env_names(server), {"A", "B", "C", "D"})


class RunIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_empty_configs_pass(self) -> None:
        _write_fixture(self.root, {"mcpServers": {}}, "[mcp_servers]\n")
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 0, output)
        self.assertIn("passed", output)

    def test_matching_http_server_passes(self) -> None:
        mcp = {
            "mcpServers": {
                "demo": {
                    "type": "http",
                    "url": "https://example.test/mcp",
                    "headers": {"x-api-key": "${DEMO_KEY}"},
                }
            }
        }
        codex = textwrap.dedent("""
            [mcp_servers.demo]
            url = "https://example.test/mcp"
            env_http_headers = { "x-api-key" = "DEMO_KEY" }
        """)
        _write_fixture(self.root, mcp, codex)
        exit_code, _ = _run_capture(self.root)
        self.assertEqual(exit_code, 0)

    def test_matching_stdio_server_passes(self) -> None:
        mcp = {
            "mcpServers": {
                "demo": {
                    "type": "stdio",
                    "command": "node",
                    "args": ["-y", "@example/pkg@1.2.3"],
                    "env": {"DEMO_TOKEN": "${DEMO_TOKEN}"},
                }
            }
        }
        codex = textwrap.dedent("""
            [mcp_servers.demo]
            command = "node"
            args = ["-y", "@example/pkg@1.2.3"]
            env_vars = ["DEMO_TOKEN"]
        """)
        _write_fixture(self.root, mcp, codex)
        exit_code, _ = _run_capture(self.root)
        self.assertEqual(exit_code, 0)

    def test_missing_in_codex_fails(self) -> None:
        mcp = {
            "mcpServers": {
                "orphan": {"type": "http", "url": "https://example.test/mcp"}
            }
        }
        _write_fixture(self.root, mcp, "[mcp_servers]\n")
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(
            "orphan: present in .mcp.json but missing in .codex/config.toml", output
        )

    def test_missing_in_mcp_fails(self) -> None:
        codex = textwrap.dedent("""
            [mcp_servers.orphan]
            url = "https://example.test/mcp"
        """)
        _write_fixture(self.root, {"mcpServers": {}}, codex)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(
            "orphan: present in .codex/config.toml but missing in .mcp.json", output
        )

    def test_codex_disabled_skipped_from_missing_check(self) -> None:
        # `enabled = false` is documented opt-out — should not fail when the
        # server is absent from .mcp.json (scaffolding for user/profile overrides).
        codex = textwrap.dedent("""
            [mcp_servers.scaffold]
            enabled = false
            url = "https://example.test/mcp"
            bearer_token_env_var = "FAKE_TOKEN"
        """)
        _write_fixture(self.root, {"mcpServers": {}}, codex)
        exit_code, _ = _run_capture(self.root)
        self.assertEqual(exit_code, 0)

    def test_allowed_codex_only_skipped(self) -> None:
        # `atlassian` / `figma` / `granola` are documented Codex-only placeholders.
        codex = textwrap.dedent("""
            [mcp_servers.atlassian]
            url = "https://mcp.atlassian.com/v1/mcp"
        """)
        _write_fixture(self.root, {"mcpServers": {}}, codex)
        exit_code, _ = _run_capture(self.root)
        self.assertEqual(exit_code, 0)

    def test_command_mismatch_fails(self) -> None:
        mcp = {"mcpServers": {"demo": {"type": "stdio", "command": "node", "args": []}}}
        codex = textwrap.dedent("""
            [mcp_servers.demo]
            command = "python"
            args = []
        """)
        _write_fixture(self.root, mcp, codex)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn("command mismatch", output)

    def test_url_mismatch_fails(self) -> None:
        mcp = {
            "mcpServers": {"demo": {"type": "http", "url": "https://example.test/a"}}
        }
        codex = textwrap.dedent("""
            [mcp_servers.demo]
            url = "https://example.test/b"
        """)
        _write_fixture(self.root, mcp, codex)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn("url mismatch", output)

    def test_package_pin_mismatch_fails(self) -> None:
        mcp = {
            "mcpServers": {
                "demo": {
                    "type": "stdio",
                    "command": "node",
                    "args": ["-y", "@example/pkg@1.0.0"],
                }
            }
        }
        codex = textwrap.dedent("""
            [mcp_servers.demo]
            command = "node"
            args = ["-y", "@example/pkg@2.0.0"]
        """)
        _write_fixture(self.root, mcp, codex)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        # args mismatch fires first; package pin diff is a sibling failure on the same row.
        self.assertIn("args mismatch", output)

    def test_env_name_mismatch_fails(self) -> None:
        mcp = {
            "mcpServers": {
                "demo": {
                    "type": "http",
                    "url": "https://example.test/mcp",
                    "headers": {"x-api-key": "${MCP_NAME}"},
                }
            }
        }
        codex = textwrap.dedent("""
            [mcp_servers.demo]
            url = "https://example.test/mcp"
            env_http_headers = { "x-api-key" = "CODEX_NAME" }
        """)
        _write_fixture(self.root, mcp, codex)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn("env name mismatch", output)

    def test_bearer_token_env_var_pairs_with_mcp_authorization_header(self) -> None:
        # When (someday) the github server is enabled and mirrored into .mcp.json,
        # the Codex `bearer_token_env_var` must compare equal to the env name
        # extracted from .mcp.json's `Authorization: Bearer ${...}` header.
        mcp = {
            "mcpServers": {
                "gh": {
                    "type": "http",
                    "url": "https://example.test/mcp",
                    "headers": {"Authorization": "Bearer ${GH_TOKEN}"},
                }
            }
        }
        codex = textwrap.dedent("""
            [mcp_servers.gh]
            url = "https://example.test/mcp"
            bearer_token_env_var = "GH_TOKEN"
        """)
        _write_fixture(self.root, mcp, codex)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 0, output)


class RealRepoSmokeTest(unittest.TestCase):
    """Run the parity check against the actual repo — guards against drift
    landing without a fixture-level test update.
    """

    def test_repo_parity_passes(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        exit_code, output = _run_capture(repo_root)
        self.assertEqual(exit_code, 0, output)


if __name__ == "__main__":
    unittest.main()
