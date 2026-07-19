"""Unit + golden-sample tests for the EPUB corpus extractor.

Unit tests exercise the pure parsing/normalization functions with small inline fixtures.
Golden-sample tests run the full extractor against the real tracked EPUBs and assert verbatim
fidelity, chapter coverage, and the Book 4 text-bearing verdict.
"""

from __future__ import annotations

import extract_epub as ex

NAV_TOC = b"""<?xml version='1.0' encoding='utf-8'?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol>
<li><a href="ch1.xhtml#a1">Chapter 1: Intro</a><ol><li><a href="ch1.xhtml#s1">Section A</a></li></ol></li>
<li><a href="ch2.xhtml">Chapter 2: Next</a></li>
</ol></nav></body></html>"""

NAV_PAGES = b"""<?xml version='1.0' encoding='utf-8'?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="page-list"><ol>
<li><a href="ch1.xhtml">1</a></li>
<li><a href="ch1.xhtml#page_2">2</a></li>
<li><a href="ch2.xhtml">3</a></li>
</ol></nav></body></html>"""

SEMANTIC_FILE = b"""<?xml version='1.0' encoding='utf-8'?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<h1>Chapter One</h1>
<p>First paragraph.</p>
<h2 id="s1">Section A</h2>
<p>Second   paragraph
spanning   wrapped lines.</p>
</body></html>"""

FIXED_FILE = b"""<?xml version='1.0' encoding='utf-8'?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<div class="img"><img src="page.jpg"/></div>
<div class="content">
  <div>Family Friends 39</div>
  <div>Some offer few results,</div>
  <div>cascading in.</div>
</div>
</body></html>"""

RICH_FILE = b"""<?xml version='1.0' encoding='utf-8'?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<p>Intro para.</p>
<ul><li>First item.</li><li>Second item.</li></ul>
<blockquote>A quoted line.</blockquote>
<table><tr><td>Singular</td><td>Plural</td></tr><tr><td>he</td><td>they</td></tr></table>
<div>Bare div text with <span>inline</span> span.</div>
</body></html>"""


class TestNormalizeWs:
    def test_collapses_runs_and_strips(self) -> None:
        assert ex.normalize_ws("  a\n\t b   c ") == "a b c"


class TestHeaderPageNumber:
    def test_bare_number(self) -> None:
        assert ex.header_page_number("39") == "39"

    def test_recto_header_trailing_number(self) -> None:
        assert ex.header_page_number("Family Friends 39") == "39"

    def test_verso_header_leading_number(self) -> None:
        assert ex.header_page_number("24 Chapter 3") == "24"

    def test_chapter_label_then_page_number(self) -> None:
        # The "Chapter N" running label is stripped, leaving the page number.
        assert ex.header_page_number("Chapter 3 page 24") == "24"

    def test_two_bare_numbers_is_ambiguous(self) -> None:
        assert ex.header_page_number("see 12 and 34") is None

    def test_no_number(self) -> None:
        assert ex.header_page_number("Foreword") is None


class TestSlugify:
    def test_lowercases_and_hyphenates(self) -> None:
        assert ex.slugify("Writing Better Lyrics") == "writing-better-lyrics"

    def test_drops_punctuation(self) -> None:
        assert (
            ex.slugify("Pat Pattison's Guide: Rhyming!")
            == "pat-pattisons-guide-rhyming"
        )

    def test_caps_length_at_word_boundary(self) -> None:
        long_title = "Songwriting: Essential Guide to Lyric Form and Structure: Tools and Techniques"
        slug = ex.slugify(long_title)
        assert len(slug) <= 60
        assert not slug.endswith("-")
        assert slug == "songwriting-essential-guide-to-lyric-form-and-structure"


class TestSplitHref:
    def test_with_anchor(self) -> None:
        assert ex._split_href("ch1.xhtml#a1") == ("ch1.xhtml", "a1")

    def test_without_anchor(self) -> None:
        assert ex._split_href("ch1.xhtml") == ("ch1.xhtml", None)


class TestParseToc:
    def test_levels_and_resolution(self) -> None:
        toc = ex.parse_toc(NAV_TOC, "OEBPS/nav.xhtml")
        assert toc == [
            ex.TocEntry(0, "Chapter 1: Intro", "OEBPS/ch1.xhtml", "a1"),
            ex.TocEntry(1, "Section A", "OEBPS/ch1.xhtml", "s1"),
            ex.TocEntry(0, "Chapter 2: Next", "OEBPS/ch2.xhtml", None),
        ]


class TestParsePageList:
    def test_first_page_per_file(self) -> None:
        pages = ex.parse_page_list(NAV_PAGES, "OEBPS/nav.xhtml")
        assert pages == {"OEBPS/ch1.xhtml": "1", "OEBPS/ch2.xhtml": "3"}


class TestExtractSemantic:
    def test_headings_paragraphs_and_dedup(self) -> None:
        blocks = ex.extract_semantic(SEMANTIC_FILE, {"s1": "Section A"}, "Chapter One")
        # h1 "Chapter One" is dropped as a duplicate of the chapter title;
        # the section emits once (anchor wins, the <h2> text dedupes).
        assert blocks == [
            ex.Block("para", "First paragraph."),
            ex.Block("section", "Section A"),
            ex.Block("para", "Second paragraph spanning wrapped lines."),
        ]

    def test_captures_non_paragraph_block_text(self) -> None:
        # List items, blockquotes, table cells, and bare divs must NOT be dropped.
        texts = [b.text for b in ex.extract_semantic(RICH_FILE, {}, "Chapter")]
        assert texts == [
            "Intro para.",
            "First item.",
            "Second item.",
            "A quoted line.",
            "Singular",
            "Plural",
            "he",
            "they",
            "Bare div text with inline span.",
        ]


class TestExtractFixedLayout:
    def test_strips_header_captures_page_joins_body(self) -> None:
        blocks = ex.extract_fixed_layout(FIXED_FILE, "999")
        assert blocks == [
            ex.Block("page", "39"),
            ex.Block("para", "Some offer few results, cascading in."),
        ]

    def test_strips_allcaps_running_header_and_falls_back_to_page_list_label(
        self,
    ) -> None:
        caps_header = FIXED_FILE.replace(b"Family Friends 39", b"ACKNOWLEDGMENTS")
        blocks = ex.extract_fixed_layout(caps_header, "999")
        # All-caps section label is a running header: stripped, page falls back to the label.
        assert blocks == [
            ex.Block("page", "999"),
            ex.Block("para", "Some offer few results, cascading in."),
        ]

    def test_strips_roman_numeral_header(self) -> None:
        roman_header = FIXED_FILE.replace(b"Family Friends 39", b"viii")
        blocks = ex.extract_fixed_layout(roman_header, "9")
        # Roman-numeral page marker is a running header: stripped, not folded into body.
        assert blocks == [
            ex.Block("page", "9"),
            ex.Block("para", "Some offer few results, cascading in."),
        ]

    def test_keeps_body_prose_leading_div_when_not_a_header(self) -> None:
        # A fixed-layout page whose first div is body prose (no running header) must keep
        # that line — it was previously dropped, losing the start of the page's text.
        body_first = FIXED_FILE.replace(
            b"Family Friends 39", b"If you are lonely you should go places"
        )
        blocks = ex.extract_fixed_layout(body_first, "55")
        assert blocks == [
            ex.Block("page", "55"),
            ex.Block(
                "para",
                "If you are lonely you should go places Some offer few results, cascading in.",
            ),
        ]


def _render(epub_path) -> str:
    zip_map = ex.read_epub(epub_path)
    title, blocks = ex.build_blocks(zip_map)
    return ex.render_markdown(title, blocks)


def _count(markdown: str, prefix: str) -> int:
    return sum(1 for line in markdown.splitlines() if line.startswith(prefix))


class TestGoldenBook1:
    def test_verbatim_passage_and_chapters(self, book1_epub) -> None:
        md = _render(book1_epub)
        assert md.startswith("# ")
        assert "Lyrics are made up of pieces: syllables gather into words" in md
        assert _count(md, "## ") >= 7  # seven chapters


class TestGoldenBook2:
    def test_chapter_coverage_and_body(self, book2_epub) -> None:
        md = _render(book2_epub)
        assert _count(md, "## ") >= 20  # 24 chapters in nav
        assert "Making Metaphors" in md


class TestGoldenBook3:
    def test_chapter_coverage(self, book3_epub) -> None:
        md = _render(book3_epub)
        assert _count(md, "## ") >= 10


class TestGoldenBook4:
    def test_text_bearing_verbatim_and_pages(self, book4_epub) -> None:
        md = _render(book4_epub)
        # Born-digital text layer is verbatim — no OCR. These are observed on printed page 39.
        assert "quadruple your choices with fricative rhymes" in md
        assert "My mommy misses me." in md
        # Page markers prove per-page text extraction across the book.
        assert _count(md, "<!-- page ") >= 100
        assert _count(md, "## ") >= 9  # nine chapters
