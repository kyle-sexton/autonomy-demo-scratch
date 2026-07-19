"""Co-change coupling pure core (axis 2).

Mines git history for files that change together: a convention restated across files
(semantic coupling the lexical layer is blind to) leaves no shared shingles, but those
files co-change when the convention moves. Standard association-rule metrics
(Zimmermann): support = commits touching both files; confidence(A->B) = support / commits
touching A. Pure functions of (git-log text, support floor) so they are output-testable.
"""

from __future__ import annotations

from collections import Counter
from itertools import combinations
from typing import Any

# Minimum co-change commits for a pair to count. No canonical threshold exists
# (RESEARCH gap); 3 is the empirical-by-design floor picked on this corpus.
SUPPORT_FLOOR = 3
TOP_PAIRS = 25
TOP_DEGREE = 15
# measure.sh emits `--pretty=format:'__COMMIT__%H'`, so commit boundaries are
# unambiguous (no .md path begins with this marker).
COMMIT_MARKER = "__COMMIT__"


def parse_commits(log_text: str) -> list[list[str]]:
    """Group a git-log dump into per-commit file lists (each sorted + de-duplicated).

    Sorting per commit makes downstream pair generation order-independent (determinism).
    """
    commits: list[list[str]] = []
    current: list[str] | None = None
    for raw in log_text.splitlines():
        line = raw.strip()
        if raw.startswith(COMMIT_MARKER):
            current = []
            commits.append(current)
        elif line:
            if current is None:
                current = []
                commits.append(current)
            current.append(line)
    return [sorted(set(files)) for files in commits]


def cochange_report(
    commits: list[list[str]], support_floor: int = SUPPORT_FLOOR
) -> dict[str, Any]:
    """Compute support + confidence per co-change pair above the floor.

    Returns a dict of n_commits / n_multi / pairs / degrees, every collection sorted
    deterministically (pairs by support desc then key asc; degrees by degree desc then file).
    """
    n_commits = len(commits)
    multi = [c for c in commits if len(c) >= 2]

    file_support: Counter[str] = Counter()
    for commit in commits:
        file_support.update(commit)

    pair_support: Counter[tuple[str, str]] = Counter()
    for commit in multi:
        # commit is sorted, so each combination is already (a, b) with a < b.
        pair_support.update(combinations(commit, 2))

    pairs: list[dict[str, Any]] = []
    degree: Counter[str] = Counter()
    for (a, b), support in pair_support.items():
        if support < support_floor:
            continue
        degree[a] += 1
        degree[b] += 1
        pairs.append(
            {
                "a": a,
                "b": b,
                "support": support,
                "conf_a_to_b": round(support / file_support[a], 4),
                "conf_b_to_a": round(support / file_support[b], 4),
            }
        )

    def pair_sort_key(pair: dict[str, Any]) -> tuple[int, str, str]:
        return (-int(pair["support"]), str(pair["a"]), str(pair["b"]))

    pairs.sort(key=pair_sort_key)

    degrees = [{"file": f, "degree": d} for f, d in degree.items()]

    def degree_sort_key(entry: dict[str, Any]) -> tuple[int, str]:
        return (-int(entry["degree"]), str(entry["file"]))

    degrees.sort(key=degree_sort_key)

    return {
        "n_commits": n_commits,
        "n_multi": len(multi),
        "pairs": pairs,
        "degrees": degrees,
    }


def cochange_section(
    log_text: str, since: str | None = None, support_floor: int = SUPPORT_FLOOR
) -> str:
    """Render the axis-2 markdown section from a git-log dump."""
    report = cochange_report(parse_commits(log_text), support_floor)
    window = f"forward window since `{since}`" if since else "full history"
    lines = [
        "## Axis 2 — co-change coupling\n",
        f"- Window: {window}",
        f"- Commits touching markdown: {report['n_commits']}",
        f"- Commits touching 2+ markdown files: {report['n_multi']}",
        f"- Coupled pairs (support >= {support_floor}): {len(report['pairs'])}\n",
    ]
    if not report["pairs"]:
        lines.append(
            "No co-change pairs at or above the support floor in this window.\n"
        )
        return "\n".join(lines)

    pairs = report["pairs"][:TOP_PAIRS]
    lines.append(f"Top {len(pairs)} coupled pairs (support, directional confidence):\n")
    lines.append("| File A | File B | Support | Conf A→B | Conf B→A |")
    lines.append("|---|---|---:|---:|---:|")
    lines += [
        f"| `{p['a']}` | `{p['b']}` | {p['support']} | {p['conf_a_to_b']} | {p['conf_b_to_a']} |"
        for p in pairs
    ]

    degrees = report["degrees"][:TOP_DEGREE]
    lines.append("")
    lines.append(f"Top {len(degrees)} files by co-change degree:\n")
    lines.append("| File | Degree |")
    lines.append("|---|---:|")
    lines += [f"| `{d['file']}` | {d['degree']} |" for d in degrees]
    return "\n".join(lines) + "\n"
