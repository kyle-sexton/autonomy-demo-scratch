#!/usr/bin/env python3
"""Tests for tools/mcp-parity/check-cursor-mcp-parity.py.

Run from repo root:

    python tools/mcp-parity/check-cursor-mcp-parity.test.py

Filename uses the `<script>.test.py` convention to match the sibling
`check-codex-mcp-parity.test.py` and the `*.test.sh` shell-test pattern in
this directory.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


def _load_parity_module() -> object:
    script_path = Path(__file__).resolve().parent / "check-cursor-mcp-parity.py"
    spec = importlib.util.spec_from_file_location(
        "cursor_parity_under_test", script_path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load spec for {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


parity = _load_parity_module()


def _write_fixture(root: Path, mcp_payload: dict, cursor_payload: dict | None) -> None:
    (root / ".mcp.json").write_text(json.dumps(mcp_payload), encoding="utf-8")
    if cursor_payload is not None:
        (root / ".cursor").mkdir(parents=True, exist_ok=True)
        (root / ".cursor" / "mcp.json").write_text(
            json.dumps(cursor_payload), encoding="utf-8"
        )


def _run_capture(root: Path) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exit_code = parity.run(root)
    return exit_code, buf.getvalue()


class RunIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_empty_configs_pass(self) -> None:
        _write_fixture(self.root, {"mcpServers": {}}, {"mcpServers": {}})
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 0, output)
        self.assertIn("passed", output)

    def test_identical_servers_pass(self) -> None:
        payload = {
            "mcpServers": {
                "demo": {
                    "type": "http",
                    "url": "https://example.test/mcp",
                    "headers": {"x-api-key": "${DEMO_KEY}"},
                }
            }
        }
        _write_fixture(self.root, payload, json.loads(json.dumps(payload)))
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 0, output)

    def test_missing_cursor_file_fails(self) -> None:
        _write_fixture(self.root, {"mcpServers": {}}, None)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(".cursor/mcp.json is missing", output)

    def test_server_missing_in_cursor_fails(self) -> None:
        _write_fixture(
            self.root,
            {"mcpServers": {"orphan": {"type": "http", "url": "https://x.test/mcp"}}},
            {"mcpServers": {}},
        )
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(
            "orphan: present in .mcp.json but missing in .cursor/mcp.json", output
        )

    def test_server_extra_in_cursor_fails(self) -> None:
        _write_fixture(
            self.root,
            {"mcpServers": {}},
            {"mcpServers": {"orphan": {"type": "http", "url": "https://x.test/mcp"}}},
        )
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(
            "orphan: present in .cursor/mcp.json but missing in .mcp.json", output
        )

    def test_server_block_differs_fails(self) -> None:
        # Mirrors the github-events env-block drift this check is meant to catch.
        _write_fixture(
            self.root,
            {
                "mcpServers": {
                    "demo": {
                        "type": "stdio",
                        "command": "node",
                        "args": ["x.js"],
                        "env": {"A": "${A:-}"},
                    }
                }
            },
            {
                "mcpServers": {
                    "demo": {
                        "type": "stdio",
                        "command": "node",
                        "args": ["x.js"],
                        "env": {"A": "${A:-}", "B": "${B:-default}"},
                    }
                }
            },
        )
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(
            "demo: server block differs between .mcp.json and .cursor/mcp.json", output
        )


class RealRepoSmokeTest(unittest.TestCase):
    """Run the parity check against the actual repo — guards against
    .mcp.json / .cursor/mcp.json drift landing without a test update.
    """

    def test_repo_parity_passes(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        exit_code, output = _run_capture(repo_root)
        self.assertEqual(exit_code, 0, output)


if __name__ == "__main__":
    unittest.main()
