"""Output-based tests for the commit-time near-duplicate gate core (M2, Phase 4).

find_third_copies is a pure function of (corpus, staged_paths, params). Fixtures are
hand-crafted with KNOWN structure so copy counts and the Rule-of-Three boundary are
hand-verifiable. The marker test isolates the exemption by holding the chunk content
identical (Jaccard 1.0) and toggling only the ignore marker.
"""

import near_dup_gate

# A single heading-section chunk with > k=5 words, so it shingles.
_BODY = (
    "the quick brown fox jumps over the lazy dog repeatedly today here every morning"
)
_PLAIN = f"# Title\n\n{_BODY}\n"
_MARKED = f"# Title\n\n<!-- markdown-coupling-ignore -->\n{_BODY}\n"
_DISTINCT = "# Other\n\ncompletely unrelated vocabulary describing separate material entirely elsewhere now today\n"


def test_third_copy_is_flagged():
    # Two existing copies + the staged one == 3 occurrences -> staged chunk flagged.
    corpus = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _PLAIN)]
    findings = near_dup_gate.find_third_copies(corpus, {"staged.md"})
    assert len(findings) == 1
    assert findings[0]["relpath"] == "staged.md"
    assert findings[0]["copy_count"] == 3
    assert findings[0]["others"] == ["a.md#0", "b.md#0"]


def test_second_copy_is_not_flagged():
    # One existing copy + the staged one == 2 occurrences -> below Rule of Three.
    corpus = [("a.md", _PLAIN), ("staged.md", _PLAIN)]
    assert near_dup_gate.find_third_copies(corpus, {"staged.md"}) == []


def test_ignore_marker_exempts_the_staged_chunk():
    # Identical content (Jaccard 1.0) in all three; only the marker differs from the control.
    marked = [("a.md", _MARKED), ("b.md", _MARKED), ("staged.md", _MARKED)]
    assert near_dup_gate.find_third_copies(marked, {"staged.md"}) == []
    # Control: same three-copy shape WITHOUT the marker is flagged, proving the marker is the cause.
    plain = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _PLAIN)]
    assert len(near_dup_gate.find_third_copies(plain, {"staged.md"})) == 1


def test_non_staged_chunks_are_never_reported():
    # Three copies exist but none is staged -> nothing to report (the commit introduces none).
    corpus = [("a.md", _PLAIN), ("b.md", _PLAIN), ("c.md", _PLAIN)]
    assert near_dup_gate.find_third_copies(corpus, set()) == []


def test_distinct_corpus_has_no_findings():
    corpus = [("a.md", _PLAIN), ("staged.md", _DISTINCT)]
    assert near_dup_gate.find_third_copies(corpus, {"staged.md"}) == []


def test_is_deterministic_seed1():
    corpus = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _PLAIN)]
    first = near_dup_gate.find_third_copies(corpus, {"staged.md"})
    second = near_dup_gate.find_third_copies(corpus, {"staged.md"})
    assert first == second


def test_render_findings_empty_is_blank():
    assert near_dup_gate.render_findings([], 0.8, 3) == ""


def test_render_findings_includes_locations_and_fix():
    corpus = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _PLAIN)]
    findings = near_dup_gate.find_third_copies(corpus, {"staged.md"})
    rendered = near_dup_gate.render_findings(findings, 0.8, 3)
    assert "markdown near-dup (M2)" in rendered
    assert "staged.md" in rendered
    assert "also: a.md#0" in rendered
    assert "/extract-ssot" in rendered


# --- Cache (content-keyed MinHash index) ---------------------------------------------------
# The cache is an OPTIMIZATION ONLY: cold-write, warm-read, and uncached runs must all agree,
# and a file's content change must invalidate its cached MinHash (the stale-key failure mode).


def test_cache_cold_then_warm_match_uncached(tmp_path):
    # Exercise the cache on a real finding (not just empties): uncached == cold-write == warm-read.
    corpus = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _PLAIN)]
    uncached = near_dup_gate.find_third_copies(corpus, {"staged.md"})
    cold = near_dup_gate.find_third_copies(corpus, {"staged.md"}, cache_dir=tmp_path)
    warm = near_dup_gate.find_third_copies(corpus, {"staged.md"}, cache_dir=tmp_path)
    assert len(uncached) == 1
    assert uncached == cold == warm


def test_cache_reflects_content_change(tmp_path):
    # Cold run: three identical copies -> staged flagged + cache written.
    three = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _PLAIN)]
    assert (
        len(near_dup_gate.find_third_copies(three, {"staged.md"}, cache_dir=tmp_path))
        == 1
    )
    # staged.md content changes (now distinct) -> warm run must RECOMPUTE it from the new
    # content, not reuse the stale MinHash keyed to the old content (the stale-key bug).
    changed = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _DISTINCT)]
    assert (
        near_dup_gate.find_third_copies(changed, {"staged.md"}, cache_dir=tmp_path)
        == []
    )


def test_cache_invalidates_on_param_change(tmp_path):
    # Write a cache at the default num_perm, then read at a different num_perm: the param
    # mismatch must force a cold rebuild, never a stale-shaped reuse.
    corpus = [("a.md", _PLAIN), ("b.md", _PLAIN), ("staged.md", _PLAIN)]
    near_dup_gate.find_third_copies(corpus, {"staged.md"}, cache_dir=tmp_path)
    uncached64 = near_dup_gate.find_third_copies(corpus, {"staged.md"}, num_perm=64)
    cached64 = near_dup_gate.find_third_copies(
        corpus, {"staged.md"}, num_perm=64, cache_dir=tmp_path
    )
    assert uncached64 == cached64
