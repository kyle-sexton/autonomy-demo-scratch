#!/usr/bin/env python3
"""Commit-time near-duplicate gate (markdown-coupling M2).

The MinHash half of the lexical detector, at its commit-time tier: a lefthook pre-commit
ADVISORY lane. Given the staged markdown plus the rest of the tracked corpus, report any
STAGED chunk that reaches the Rule-of-Three — a near-duplicate that becomes the 3rd-or-later
copy of the same content. That is the signal `AGENTS.md` "Reference, don't duplicate" turns
into an extract-to-SSOT action.

Mechanism (reuses lexical.py — the axis-1 core — verbatim, no fork): heading-section chunk
-> k=5 word shingles -> datasketch MinHashLSH candidate generation -> EXACT Jaccard verify.
Deterministic (seed=1). The corpus passed in is the COMBINED working-tree corpus (it already
contains the staged files' current content exactly once), so a modified file's chunk never
matches its own stale HEAD copy — self-match is avoided by construction, not by a special
case. Only chunks ORIGINATING in a staged file are reported; the rest of the corpus is
context for the copy count.

Latency: computing a MinHash for every corpus chunk is the dominant cost (seconds at repo
scale), too slow per-commit. A content-keyed cache (see `_minhash_index`) persists each
chunk's MinHash keyed to its file's content hash, so a commit recomputes MinHashes only for
the handful of files it actually changed — the warm path. The cache is an OPTIMIZATION only:
its output is byte-identical to the uncached path (a deterministic function of the same
shingles + params), enforced by an explicit cached-vs-uncached equality test.

Exemptions (a chunk that should not fire):
  - a chunk carrying the `markdown-coupling-ignore` marker on any line (the author's explicit
    "intentional repeat" escape hatch — same token the resolver honors); this is also how a
    deliberately-repeated CONTRACT IDENTIFIER block is exempted.
  - path-scope exemptions (`.work/`, the deferred-SSOT `journal.md`, build/noise + template
    dirs) are applied by the calling lane (markdown-near-dup-check.sh) when it enumerates the
    corpus, matching the resolver's scope — this core stays path-agnostic and operates on
    values.

ADVISORY: the CLI always exits 0 (datasketch absent -> skip notice, still 0). Detection lives
here (re-runnable, unit-tested); the thin lefthook glue lives in the .lefthook lane.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any, NamedTuple, cast

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import detect  # noqa: E402  # read_path_list / read_corpus (pure I/O helpers; no main() on import)
import lexical  # noqa: E402  # chunk_markdown / word_shingles / jaccard (axis-1 core, reused verbatim)

DEFAULT_THRESHOLD = (
    0.8  # matches the lexical baseline's reported near-dup line (axis 1)
)
DEFAULT_MIN_COPIES = 3  # Rule of Three — flag the 3rd-or-later occurrence
IGNORE_MARKER = "markdown-coupling-ignore"
# Gitignored cache home (created on demand). Persists the per-chunk MinHash index so a commit
# recomputes only the files it changed. Safe serialization (numpy .npy + JSON, no pickle).
DEFAULT_CACHE_DIR = SCRIPT_DIR / ".cache" / "near-dup-index"
# Bump when the cache's on-disk shape or the MinHash params' meaning changes — a version
# mismatch forces a full rebuild rather than reading a stale-shaped index.
CACHE_VERSION = 1


class _Chunk(NamedTuple):
    """One corpus chunk record. chunk_id is "<relpath>#<chunk-index>"."""

    chunk_id: str
    relpath: str
    is_staged: bool
    text: str
    shingles: frozenset[str]


def _enumerate_chunks(
    corpus: list[tuple[str, str]], staged_paths: set[str], k: int
) -> list[_Chunk]:
    """Flatten the corpus to sorted chunk records, dropping chunks with too few words.

    Sorted by chunk_id so insertion + counting are order-independent (determinism).
    """
    out: list[_Chunk] = []
    for relpath, text in corpus:
        for index, chunk in enumerate(lexical.chunk_markdown(text)):
            shingles = lexical.word_shingles(chunk, k)
            if shingles:
                out.append(
                    _Chunk(
                        chunk_id=f"{relpath}#{index}",
                        relpath=relpath,
                        is_staged=relpath in staged_paths,
                        text=chunk,
                        shingles=shingles,
                    )
                )
    out.sort(key=lambda record: record.chunk_id)
    return out


def _preview(text: str) -> str:
    """A one-line label for a chunk: its heading, else its first non-empty line, truncated."""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:80]
    return ""


def _load_cache(
    cache_dir: Path, *, k: int, num_perm: int, seed: int
) -> tuple[dict[str, Any] | None, Any]:
    """Load (manifest, hashvalues array) when present and matching params, else (None, None).

    Any failure (missing files, corrupt JSON/array, version/param mismatch, length skew)
    degrades to a cold rebuild — the cache is best-effort and never blocks or corrupts a run.
    allow_pickle=False on load refuses any object array, so a tampered cache cannot execute code.
    """
    import numpy as np

    try:
        manifest = json.loads((cache_dir / "index.json").read_text(encoding="utf-8"))
        if (
            manifest.get("version") != CACHE_VERSION
            or manifest.get("k") != k
            or manifest.get("num_perm") != num_perm
            or manifest.get("seed") != seed
        ):
            return None, None
        rows = np.load(cache_dir / "index.npy", allow_pickle=False)
        if rows.shape[0] != len(manifest.get("order", [])):
            return None, None
        return manifest, rows
    except OSError, ValueError, json.JSONDecodeError:
        return None, None


def _write_cache(
    cache_dir: Path,
    chunks: list[_Chunk],
    index: dict[str, Any],
    sha_by_path: dict[str, str],
    *,
    k: int,
    num_perm: int,
    seed: int,
) -> None:
    """Persist the index atomically (.npy hashvalues + JSON manifest). Best-effort: swallow errors.

    Writes to temp siblings then os.replace, so an interrupted write never leaves a half-file
    the next load would trust (the load's length-skew check is the backstop if it does).
    """
    import numpy as np

    if not chunks:
        return
    order = [record.chunk_id for record in chunks]
    try:
        cache_dir.mkdir(parents=True, exist_ok=True)
        hashvalues = np.array(
            [index[chunk_id].hashvalues for chunk_id in order], dtype=np.uint64
        )
        manifest = {
            "version": CACHE_VERSION,
            "k": k,
            "num_perm": num_perm,
            "seed": seed,
            "files": sha_by_path,
            "order": order,
        }
        rows_tmp = cache_dir / "index.tmp.npy"
        manifest_tmp = cache_dir / "index.tmp.json"
        np.save(rows_tmp, hashvalues, allow_pickle=False)
        manifest_tmp.write_text(json.dumps(manifest), encoding="utf-8")
        Path(rows_tmp).replace(cache_dir / "index.npy")
        Path(manifest_tmp).replace(cache_dir / "index.json")
    except OSError:
        return


def _minhash_index(
    chunks: list[_Chunk],
    corpus: list[tuple[str, str]],
    *,
    k: int,
    num_perm: int,
    cache_dir: Path | None,
) -> dict[str, Any]:
    """Return {chunk_id: LeanMinHash} for every chunk.

    With cache_dir set, reuse the persisted MinHash for any chunk whose FILE content hash is
    unchanged since the cache was written, recompute only changed/new files, and rewrite the
    cache. Without cache_dir (or whenever the cache is absent/stale), compute every MinHash
    fresh. The returned index is identical either way — content-hash keying guarantees a reused
    MinHash corresponds to byte-identical chunk text, so the cache never changes findings.
    """
    from datasketch import LeanMinHash, MinHash

    seed = MinHash(num_perm=num_perm).seed

    def compute(shingles: frozenset[str]) -> Any:
        minhash = MinHash(num_perm=num_perm)
        for shingle in shingles:
            minhash.update(shingle.encode("utf-8"))
        return LeanMinHash(minhash)

    if cache_dir is None:
        return {record.chunk_id: compute(record.shingles) for record in chunks}

    manifest, rows = _load_cache(cache_dir, k=k, num_perm=num_perm, seed=seed)
    cached_files: dict[str, str] = manifest["files"] if manifest else {}
    row_by_id: dict[str, int] = (
        {chunk_id: i for i, chunk_id in enumerate(manifest["order"])}
        if manifest
        else {}
    )
    sha_by_path = {
        relpath: hashlib.sha256(text.encode("utf-8")).hexdigest()
        for relpath, text in corpus
    }

    index: dict[str, Any] = {}
    for chunk_id, relpath, _is_staged, _text, shingles in chunks:
        if (
            rows is not None
            and cached_files.get(relpath) == sha_by_path.get(relpath)
            and chunk_id in row_by_id
        ):
            index[chunk_id] = LeanMinHash(
                seed=seed, hashvalues=rows[row_by_id[chunk_id]]
            )
        else:
            index[chunk_id] = compute(shingles)

    _write_cache(
        cache_dir, chunks, index, sha_by_path, k=k, num_perm=num_perm, seed=seed
    )
    return index


def find_third_copies(
    corpus: list[tuple[str, str]],
    staged_paths: set[str],
    *,
    k: int = lexical.K_SHINGLE,
    num_perm: int = lexical.NUM_PERM,
    threshold: float = DEFAULT_THRESHOLD,
    min_copies: int = DEFAULT_MIN_COPIES,
    ignore_marker: str = IGNORE_MARKER,
    cache_dir: Path | None = None,
) -> list[dict[str, Any]]:
    """Report staged chunks whose near-duplicate copy count (incl. itself) reaches min_copies.

    Pure function of (corpus, staged_paths, params): the copy counts are computed via exact
    Jaccard on MinHashLSH candidates, so the result is deterministic regardless of candidate
    iteration order. `corpus` is the COMBINED working-tree corpus; `staged_paths` selects which
    chunks are reported. `cache_dir` (when set) persists the per-chunk MinHash index across runs
    so only changed files are recomputed — an optimization that does not change the result.
    """
    from datasketch import MinHashLSH

    chunks = _enumerate_chunks(corpus, staged_paths, k)
    record_by_id = {record.chunk_id: record for record in chunks}

    minhash_by_id = _minhash_index(
        chunks, corpus, k=k, num_perm=num_perm, cache_dir=cache_dir
    )
    lsh = MinHashLSH(threshold=threshold, num_perm=num_perm)
    for chunk_id, minhash in minhash_by_id.items():
        lsh.insert(chunk_id, minhash)

    findings: list[dict[str, Any]] = []
    for chunk_id, relpath, is_staged, text, shingles in chunks:
        if not is_staged:
            continue
        if ignore_marker and ignore_marker in text:
            continue
        copies = [
            other
            for other in lsh.query(minhash_by_id[chunk_id])
            if other != chunk_id
            and lexical.jaccard(shingles, record_by_id[other].shingles) >= threshold
        ]
        copy_count = len(copies) + 1  # the staged chunk itself is the +1
        if copy_count >= min_copies:
            findings.append(
                {
                    "chunk_id": chunk_id,
                    "relpath": relpath,
                    "copy_count": copy_count,
                    "others": sorted(copies),
                    "preview": _preview(text),
                }
            )
    findings.sort(key=lambda finding: finding["chunk_id"])
    return findings


def render_findings(
    findings: list[dict[str, Any]], threshold: float, min_copies: int
) -> str:
    """Render the advisory block; empty string when there is nothing to report."""
    if not findings:
        return ""
    lines = [
        f"markdown near-dup (M2): {len(findings)} staged chunk(s) reach the "
        f"{min_copies}-copy rule (Jaccard >= {threshold}):",
        "",
    ]
    for finding in findings:
        lines.append(
            f'  {finding["relpath"]}: "{finding["preview"]}" '
            f"— {finding['copy_count']} near-copies across the corpus"
        )
        for other in cast(list[str], finding["others"]):
            lines.append(f"      also: {other}")
    lines.extend(
        [
            "",
            "Rule of Three: a concept restated in 3+ places should live in one SSOT the others "
            'cite (AGENTS.md "Reference, don\'t duplicate").',
            "Fix: extract to an SSOT + cite by heading (/extract-ssot), or mark an intentional "
            "repeat with a `markdown-coupling-ignore` line.",
        ]
    )
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Advisory commit-time near-duplicate gate (markdown-coupling M2). Reports staged "
            "markdown chunks that reach the Rule-of-Three near-duplicate threshold. Always "
            "exits 0."
        )
    )
    parser.add_argument(
        "--corpus-file",
        required=True,
        help="Newline-delimited relpaths of the COMBINED corpus (staged + the rest).",
    )
    parser.add_argument(
        "--staged-file",
        required=True,
        help="Newline-delimited relpaths of the staged files to report on.",
    )
    parser.add_argument(
        "--root", required=True, help="Repo root to resolve relpaths against."
    )
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--min-copies", type=int, default=DEFAULT_MIN_COPIES)
    parser.add_argument(
        "--ignore-marker",
        default=IGNORE_MARKER,
        help="Lines carrying this marker exempt their chunk (intentional repeat).",
    )
    parser.add_argument(
        "--cache-dir",
        default=str(DEFAULT_CACHE_DIR),
        help="Gitignored MinHash-index cache home (default: tools/markdown-coupling/.cache/).",
    )
    parser.add_argument(
        "--no-cache",
        action="store_true",
        help="Recompute every MinHash fresh; skip reading/writing the cache.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    # stdout defaults to the locale encoding (cp1252 on Western Windows); the advisory carries
    # em-dashes, so force UTF-8 to keep the bytes correct.
    cast(Any, sys.stdout).reconfigure(encoding="utf-8")
    args = parse_args(argv)

    corpus = detect.read_corpus(detect.read_path_list(args.corpus_file), args.root)
    staged_paths = set(detect.read_path_list(args.staged_file))
    if not corpus or not staged_paths:
        return 0

    cache_dir = None if args.no_cache else Path(args.cache_dir)
    try:
        findings = find_third_copies(
            corpus,
            staged_paths,
            threshold=args.threshold,
            min_copies=args.min_copies,
            ignore_marker=args.ignore_marker,
            cache_dir=cache_dir,
        )
    except ImportError:
        # datasketch absent — advisory lane degrades to a skip, never blocks the commit.
        print("markdown near-dup (M2): datasketch not installed — skipped (advisory).")
        return 0

    out = render_findings(findings, args.threshold, args.min_copies)
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
