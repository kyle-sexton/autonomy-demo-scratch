"""Put the tool root on sys.path so tests can import the flat modules.

The detector modules (cochange, lexical, detect) live directly under
tools/markdown-coupling/ rather than in an installed package, so the test dir's
own parent must be importable.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
