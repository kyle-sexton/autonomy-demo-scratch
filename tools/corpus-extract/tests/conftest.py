# pyright: reportUntypedFunctionDecorator=false
# pytest fixtures are dynamically typed; suppress only this rule for test infra.
"""Shared fixtures and path constants for the corpus-extract tests."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Make the standalone script importable without packaging it.
_TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(_TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(_TOOL_ROOT))

SOURCE_DIR = _TOOL_ROOT / "source"

BOOK_GLOBS = {
    "book1": "Book1-*.epub",
    "book2": "Book2-*.epub",
    "book3": "Book3-*.epub",
    "book4": "Book4-*.epub",
}


def _epub(book: str) -> Path:
    matches = sorted(SOURCE_DIR.glob(BOOK_GLOBS[book]))
    if not matches:
        pytest.skip(f"source EPUB for {book} not present at {SOURCE_DIR}")
    return matches[0]


@pytest.fixture(scope="session")
def book1_epub() -> Path:
    return _epub("book1")


@pytest.fixture(scope="session")
def book2_epub() -> Path:
    return _epub("book2")


@pytest.fixture(scope="session")
def book3_epub() -> Path:
    return _epub("book3")


@pytest.fixture(scope="session")
def book4_epub() -> Path:
    return _epub("book4")
