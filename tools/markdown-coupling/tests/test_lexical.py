"""Output-based tests for the lexical near-duplication pure core (axis 1).

chunk_markdown / word_shingles / jaccard are pure string functions; near_dup_report is a
pure function of (corpus, params). Inputs are hand-crafted with KNOWN structure so chunk
boundaries, shingles, and near-dup counts are all hand-verifiable.
"""

import lexical


def test_chunk_markdown_splits_heading_sections_with_paragraph_preamble():
    text = (
        "preamble line one here.\n\n"
        "# Heading A\n\nbody a here.\n\n"
        "# Heading B\n\nbody b here.\n"
    )
    assert lexical.chunk_markdown(text) == [
        "preamble line one here.",  # headingless preamble -> paragraph fallback
        "# Heading A\n\nbody a here.",
        "# Heading B\n\nbody b here.",
    ]


def test_chunk_markdown_headingless_file_falls_back_to_paragraphs():
    text = "para one has several words here.\n\npara two also has several words.\n"
    assert lexical.chunk_markdown(text) == [
        "para one has several words here.",
        "para two also has several words.",
    ]


def test_chunk_markdown_strips_leading_frontmatter():
    # Frontmatter is metadata, not prose — co-scoped rule files share byte-identical
    # frontmatter, so chunking it would register a spurious near-duplicate.
    text = '---\npaths:\n  - "**/PLAN.md"\n---\n\n# Heading A\n\nbody a here.\n'
    assert lexical.chunk_markdown(text) == ["# Heading A\n\nbody a here."]


def test_chunk_markdown_lone_leading_rule_is_not_frontmatter():
    # A single `---` with no closing fence is a horizontal rule, not frontmatter — it is
    # kept (surfaces as the headingless-preamble paragraph), not consumed as metadata.
    text = "---\n\n# Real Heading\n\nbody with several words here now.\n"
    assert lexical.chunk_markdown(text) == [
        "---",
        "# Real Heading\n\nbody with several words here now.",
    ]


def test_word_shingles_lowercased_k5_windows():
    assert lexical.word_shingles("The Quick Brown Fox Jumps Over") == frozenset(
        {"the quick brown fox jumps", "quick brown fox jumps over"}
    )


def test_word_shingles_below_k_is_empty():
    assert lexical.word_shingles("only four words here") == frozenset()


def test_jaccard_known_sets():
    a = frozenset({"1", "2", "3"})
    b = frozenset({"2", "3", "4"})
    assert lexical.jaccard(a, b) == 0.5  # intersection 2 / union 4


def test_jaccard_empty_is_zero():
    assert lexical.jaccard(frozenset(), frozenset({"x"})) == 0.0


# Corpus with one exact-duplicate pair (a == b) and one distinct doc (c).
_DUP = "# Title\n\nThe quick brown fox jumps over the lazy dog repeatedly today here.\n"
_DISTINCT = "# Other\n\nCompletely unrelated vocabulary describing separate material entirely elsewhere now.\n"


def test_near_dup_report_finds_identical_pair_at_every_threshold():
    report = lexical.near_dup_report(
        [("a.md", _DUP), ("b.md", _DUP), ("c.md", _DISTINCT)]
    )
    assert report["n_chunks"] == 3
    # only (a#0, b#0) is a near-dup; c shares no shingles with a/b.
    assert report["counts"][0.7] == 1
    assert report["counts"][0.8] == 1
    assert report["counts"][0.9] == 1


def test_near_dup_report_distinct_corpus_has_no_pairs():
    report = lexical.near_dup_report([("a.md", _DUP), ("c.md", _DISTINCT)])
    assert report["counts"][0.7] == 0
    assert report["counts"][0.8] == 0
    assert report["counts"][0.9] == 0


def test_near_dup_report_is_deterministic_seed1():
    corpus = [("a.md", _DUP), ("b.md", _DUP), ("c.md", _DISTINCT)]
    assert lexical.near_dup_report(corpus) == lexical.near_dup_report(corpus)


def test_near_dup_section_renders_threshold_table():
    section = lexical.near_dup_section([("a.md", _DUP), ("b.md", _DUP)])
    assert "## Axis 1 — lexical near-duplication" in section
    assert "Shingled chunks" in section
    assert "| 0.9 |" in section
