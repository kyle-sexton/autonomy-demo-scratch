#!/usr/bin/env python3
"""Tests for tools/mcp-parity/check-cursor-mcp-policy.py.

Run from repo root:

    python tools/mcp-parity/check-cursor-mcp-policy.test.py

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


def _load_policy_module() -> object:
    script_path = Path(__file__).resolve().parent / "check-cursor-mcp-policy.py"
    spec = importlib.util.spec_from_file_location(
        "cursor_policy_under_test", script_path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load spec for {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


policy = _load_policy_module()


def _write_fixture(
    root: Path, mcp_payload: dict | None, settings_payload: dict | None
) -> None:
    if mcp_payload is not None:
        (root / ".mcp.json").write_text(json.dumps(mcp_payload), encoding="utf-8")
    if settings_payload is not None:
        (root / ".claude").mkdir(parents=True, exist_ok=True)
        (root / ".claude" / "settings.json").write_text(
            json.dumps(settings_payload), encoding="utf-8"
        )


def _run_capture(root: Path) -> tuple[int, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        exit_code = policy.run(root)
    return exit_code, out.getvalue() + err.getvalue()


class RunIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_all_servers_classified_passes(self) -> None:
        _write_fixture(
            self.root,
            {"mcpServers": {"a": {}, "b": {}}},
            {"enabledMcpjsonServers": ["a"], "disabledMcpjsonServers": ["b"]},
        )
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 0, output)
        self.assertIn("ENABLE:", output)
        self.assertIn("[ON]  a", output)
        self.assertIn("[OFF] b", output)

    def test_unknown_enabled_server_fails(self) -> None:
        _write_fixture(
            self.root,
            {"mcpServers": {"a": {}}},
            {"enabledMcpjsonServers": ["a", "ghost"], "disabledMcpjsonServers": []},
        )
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn("enabledMcpjsonServers lists unknown server: ghost", output)

    def test_unclassified_server_fails(self) -> None:
        _write_fixture(
            self.root,
            {"mcpServers": {"a": {}, "b": {}}},
            {"enabledMcpjsonServers": ["a"], "disabledMcpjsonServers": []},
        )
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(
            "b: in .mcp.json but not in enabledMcpjsonServers or disabledMcpjsonServers",
            output,
        )

    def test_missing_mcp_json_fails(self) -> None:
        _write_fixture(self.root, None, {"enabledMcpjsonServers": []})
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(".mcp.json is missing", output)

    def test_missing_settings_fails(self) -> None:
        _write_fixture(self.root, {"mcpServers": {}}, None)
        exit_code, output = _run_capture(self.root)
        self.assertEqual(exit_code, 1)
        self.assertIn(".claude/settings.json is missing", output)


class RealRepoSmokeTest(unittest.TestCase):
    """Run the policy check against the actual repo — guards against a server
    landing in .mcp.json without an enabled/disabled classification.
    """

    def test_repo_policy_passes(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        exit_code, output = _run_capture(repo_root)
        self.assertEqual(exit_code, 0, output)


if __name__ == "__main__":
    unittest.main()
