"""Lexical near-duplication pure core (axis 1).

Detection unit is a sub-document CHUNK, not a whole file — a convention restated across
files leaves partial overlap that whole-file Jaccard misses. Cascade: heading-section chunk
(paragraph fallback for headingless regions) -> lower-cased k=5 word shingles -> datasketch
MinHash (num_perm=128, default seed=1) -> MinHashLSH candidate generation -> EXACT Jaccard on
candidate pairs for the reported numbers (scalable + exact-where-it-counts + deterministic).

datasketch is imported lazily inside near_dup_report so chunk_markdown / word_shingles / jaccard
stay usable (e.g. for the chunk-count denominator) even where the dependency is absent.
"""

from __future__ import annotations

import re
from typing import Any, cast

K_SHINGLE = 5
NUM_PERM = 128
REPORT_THRESHOLDS = (0.7, 0.8, 0.9)

_HEADING = re.compile(r"^#{1,6}\s")
# A leading YAML frontmatter block: `---` on its own line, body, closing `---` on its own
# line, at file start only (\A, non-greedy to the FIRST closing fence). Frontmatter is
# structural metadata (paths globs, status), not instruction prose — co-scoped files share
# byte-identical frontmatter (e.g. every `**/PLAN.md` rule), which would otherwise register
# as a near-duplicate. A lone leading `---` with no closing fence is NOT matched (it is a
# horizontal rule, not frontmatter).
_FRONTMATTER = re.compile(r"\A---[ \t]*\r?\n.*?\r?\n---[ \t]*\r?\n?", re.DOTALL)


def _strip_frontmatter(text: str) -> str:
    """Drop a leading YAML frontmatter block so metadata is never chunked as prose."""
    return _FRONTMATTER.sub("", text, count=1)


def chunk_markdown(text: str) -> list[str]:
    """Split markdown into heading-section chunks, paragraph fallback for headingless regions.

    Leading YAML frontmatter is stripped first (metadata, not prose). Each chunk is then a
    heading line plus its body up to the next heading. Content before the first heading (or a
    file with no headings) falls back to blank-line-delimited paragraphs.
    """
    sections: list[list[str]] = []
    current: list[str] = []
    for line in _strip_frontmatter(text).splitlines():
        if _HEADING.match(line):
            if current:
                sections.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        sections.append(current)

    chunks: list[str] = []
    for section in sections:
        if section and _HEADING.match(section[0]):
            chunk = "\n".join(section).strip()
            if chunk:
                chunks.append(chunk)
        else:
            chunks.extend(_paragraphs(section))
    return chunks


def _paragraphs(lines: list[str]) -> list[str]:
    paragraphs: list[str] = []
    buffer: list[str] = []
    for line in lines:
        if line.strip():
            buffer.append(line)
        elif buffer:
            paragraphs.append("\n".join(buffer).strip())
            buffer = []
    if buffer:
        paragraphs.append("\n".join(buffer).strip())
    return [p for p in paragraphs if p]


def word_shingles(text: str, k: int = K_SHINGLE) -> frozenset[str]:
    """Lower-cased, whitespace-collapsed k-word shingle set; empty if fewer than k words."""
    words = text.lower().split()
    if len(words) < k:
        return frozenset()
    return frozenset(" ".join(words[i : i + k]) for i in range(len(words) - k + 1))


def jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    """Exact Jaccard similarity; 0.0 when either set is empty (no spurious near-dup)."""
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _shingle_chunks(
    corpus: list[tuple[str, str]], k: int
) -> list[tuple[str, frozenset[str]]]:
    """Flatten the corpus to a sorted list of (chunk_id, shingles), dropping empty shingles.

    Sorted by chunk_id so insertion + counting are order-independent (determinism).
    """
    out: list[tuple[str, frozenset[str]]] = []
    for relpath, text in corpus:
        for index, chunk in enumerate(chunk_markdown(text)):
            shingles = word_shingles(chunk, k)
            if shingles:
                out.append((f"{relpath}#{index}", shingles))
    out.sort(key=lambda pair: pair[0])
    return out


def near_dup_report(
    corpus: list[tuple[str, str]],
    k: int = K_SHINGLE,
    num_perm: int = NUM_PERM,
    thresholds: tuple[float, ...] = REPORT_THRESHOLDS,
) -> dict[str, Any]:
    """MinHashLSH candidate generation + exact-Jaccard verification -> per-threshold pair counts.

    Counts are exact (computed via real Jaccard on LSH candidates), so they are deterministic
    regardless of candidate-set iteration order.
    """
    from datasketch import MinHash, MinHashLSH

    chunks = _shingle_chunks(corpus, k)
    shingles_by_id = dict(chunks)
    lsh = MinHashLSH(threshold=min(thresholds), num_perm=num_perm)
    minhash_by_id: dict[str, Any] = {}
    for chunk_id, shingles in chunks:
        minhash = MinHash(num_perm=num_perm)
        for shingle in shingles:
            minhash.update(shingle.encode("utf-8"))
        minhash_by_id[chunk_id] = minhash
        lsh.insert(chunk_id, minhash)

    candidates: set[tuple[str, str]] = set()
    for chunk_id, _ in chunks:
        for other in lsh.query(minhash_by_id[chunk_id]):
            if other != chunk_id:
                candidates.add(cast(tuple[str, str], tuple(sorted((chunk_id, other)))))

    counts = dict.fromkeys(thresholds, 0)
    for a, b in candidates:
        similarity = jaccard(shingles_by_id[a], shingles_by_id[b])
        for t in thresholds:
            if similarity >= t:
                counts[t] += 1
    return {
        "n_chunks": len(chunks),
        "n_candidates": len(candidates),
        "counts": counts,
    }


def near_dup_section(
    corpus: list[tuple[str, str]],
    k: int = K_SHINGLE,
    num_perm: int = NUM_PERM,
    thresholds: tuple[float, ...] = REPORT_THRESHOLDS,
) -> str:
    """Render the axis-1 markdown section from the primary corpus."""
    report = near_dup_report(corpus, k, num_perm, thresholds)
    n_chunks = report["n_chunks"]
    lines = [
        "## Axis 1 — lexical near-duplication\n",
        f"- Shingled chunks (>= k={k} words): {n_chunks}",
        f"- MinHash num_perm={num_perm} (seed=1), LSH candidate threshold {min(thresholds)}",
        f"- Candidate pairs (MinHashLSH): {report['n_candidates']}\n",
        "| Jaccard >= | Near-dup pairs | Pairs per 1k chunks |",
        "|---:|---:|---:|",
    ]
    for t in thresholds:
        count = report["counts"][t]
        per_1k = round(1000 * count / n_chunks, 3) if n_chunks else 0
        lines.append(f"| {t} | {count} | {per_1k} |")
    return "\n".join(lines) + "\n"
