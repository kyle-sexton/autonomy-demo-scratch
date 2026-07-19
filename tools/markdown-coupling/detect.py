#!/usr/bin/env python3
"""Functional-core orchestrator for the markdown-coupling baseline detector.

Reads the enumerated corpus path lists + a git-log dump + hotspot definitions and
emits the deterministic baseline body (denominators + 3 axes + reproduction). All
non-determinism (the timestamp) lives in measure.sh; given identical inputs this
module produces byte-identical output, so two runs at the same HEAD differ only on
the frontmatter `generated` line.

Axes degrade independently: a missing sibling module (cochange / lexical) or missing
datasketch reports SKIPPED for that axis while the others still run — this is what lets
the skeleton run end-to-end before every axis is wired.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any, cast

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

try:
    import cochange
except ImportError:
    cochange = None

try:
    import lexical
except ImportError:
    lexical = None


def read_path_list(path: str) -> list[str]:
    """Return non-empty stripped lines from a newline-delimited path-list file."""
    p = Path(path)
    if not p.is_file():
        return []
    return [
        ln.strip() for ln in p.read_text(encoding="utf-8").splitlines() if ln.strip()
    ]


def read_corpus(rel_paths: list[str], root: str) -> list[tuple[str, str]]:
    """Resolve and read each corpus file; return sorted (relpath, text) pairs.

    Sorted by relpath so every downstream collection has a stable order (determinism).
    Unreadable files are skipped rather than aborting the whole measurement.
    """
    root_p = Path(root)
    out: list[tuple[str, str]] = []
    for rel in rel_paths:
        try:
            text = (root_p / rel).read_text(encoding="utf-8")
        except OSError, UnicodeDecodeError:
            continue
        out.append((rel, text))
    out.sort(key=lambda pair: pair[0])
    return out


def chunk_count(corpus: list[tuple[str, str]]) -> int | None:
    """Total heading-section chunk count across the corpus, or None if unavailable."""
    if lexical is None:
        return None
    return sum(len(lexical.chunk_markdown(text)) for _, text in corpus)


def section_denominators(
    primary: list[tuple[str, str]], secondary: list[tuple[str, str]]
) -> str:
    """Corpus-size denominators so Phase 6 normalizes raw counts like-for-like."""
    chunks = chunk_count(primary)
    chunk_line = str(chunks) if chunks is not None else "pending (lexical not wired)"
    return (
        "## Denominators\n\n"
        f'- Primary files (markdown-discipline "Scope"): {len(primary)}\n'
        f"- Primary heading-section chunks: {chunk_line}\n"
        f"- Secondary files (`.work/**`): {len(secondary)}\n"
    )


def section_axis1(primary: list[tuple[str, str]]) -> str:
    """Axis 1 — lexical near-duplication (MinHash over heading-section chunks)."""
    if lexical is None:
        return "## Axis 1 — lexical near-duplication\n\nSKIPPED (lexical module not wired).\n"
    try:
        return lexical.near_dup_section(primary)
    except ImportError:
        # datasketch absent — the module docstring promises this axis SKIPs while
        # the others still run (mirrors near_dup_gate.py's advisory-lane handling
        # of the same lazy import).
        return "## Axis 1 — lexical near-duplication\n\nSKIPPED (datasketch not installed).\n"


def section_axis2(log_file: str, since: str | None) -> str:
    """Axis 2 — co-change coupling (git history support + confidence)."""
    if cochange is None:
        return (
            "## Axis 2 — co-change coupling\n\nSKIPPED (cochange module not wired).\n"
        )
    log_text = (
        Path(log_file).read_text(encoding="utf-8") if Path(log_file).is_file() else ""
    )
    return cochange.cochange_section(log_text, since=since)


def read_hotspots(hotspots_file: str) -> list[tuple[str, str, str, str]]:
    """Parse hotspots.tsv rows: (name, ssot_file, heading, grep_pattern).

    Skips blank lines and `#`-prefixed comments; ignores malformed rows.
    """
    p = Path(hotspots_file)
    if not p.is_file():
        return []
    rows: list[tuple[str, str, str, str]] = []
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) >= 4:
            rows.append((fields[0], fields[1], fields[2], fields[3]))
    return rows


def section_axis3(primary: list[tuple[str, str]], hotspots_file: str) -> str:
    """Axis 3 — per-hotspot blast radius (file + site counts per semantic hotspot).

    For each hotspot's grep_pattern, count primary files containing >=1 match (files) and
    total matches (sites). This present-state structural count is directly comparable across
    time (no windowing), so it is Phase 6's cleanest verdict metric.
    """
    rows = read_hotspots(hotspots_file)
    if not rows:
        return "## Axis 3 — per-hotspot blast radius\n\nSKIPPED (no hotspots.tsv).\n"
    lines = [
        "## Axis 3 — per-hotspot blast radius\n",
        "| Hotspot | SSOT | Files | Sites |",
        "|---|---|---:|---:|",
    ]
    for name, ssot_file, _heading, pattern in rows:
        try:
            rx = re.compile(pattern)
        except re.error:
            lines.append(
                f"| {name} | {ssot_file} | invalid-pattern | invalid-pattern |"
            )
            continue
        files = 0
        sites = 0
        for _rel, text in primary:
            hits = len(rx.findall(text))
            if hits:
                files += 1
                sites += hits
        lines.append(f"| {name} | `{ssot_file}` | {files} | {sites} |")
    return "\n".join(lines) + "\n"


def section_reproduction(since: str | None) -> str:
    cmd = "bash tools/markdown-coupling/measure.sh"
    if since:
        cmd += f" --since {since}"
    return f"## Reproduction\n\n```bash\n{cmd}\n```\n"


def build_body(
    primary: list[tuple[str, str]],
    secondary: list[tuple[str, str]],
    log_file: str,
    hotspots_file: str,
    head_sha: str,
    since: str | None,
) -> str:
    window = f"forward window `{since}..HEAD`" if since else "full history"
    sections = [
        "# Markdown-coupling baseline\n",
        f"Corpus enumerated at `{head_sha}` (co-change axis: {window}).\n",
        section_denominators(primary, secondary),
        section_axis1(primary),
        section_axis2(log_file, since),
        section_axis3(primary, hotspots_file),
        section_reproduction(since),
    ]
    return "\n".join(sections)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit the markdown-coupling baseline body."
    )
    parser.add_argument("--primary-file", required=True)
    parser.add_argument("--secondary-file", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--hotspots", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--since", default=None)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    # Python's stdout defaults to the locale encoding (cp1252 on Western Windows), which
    # mangles the Unicode the body carries; force UTF-8 so the baseline bytes are correct.
    cast(Any, sys.stdout).reconfigure(encoding="utf-8")
    args = parse_args(argv)
    primary = read_corpus(read_path_list(args.primary_file), args.root)
    secondary = read_corpus(read_path_list(args.secondary_file), args.root)
    body = build_body(
        primary, secondary, args.log_file, args.hotspots, args.head_sha, args.since
    )
    print(body, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
