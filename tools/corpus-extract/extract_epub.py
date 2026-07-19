"""Extract Pat Pattison craft EPUBs to verbatim normalized markdown with stable locators.

Dependency-free (Python standard library only). The source EPUBs are Calibre-produced and
emit well-formed XHTML, so ``xml.etree.ElementTree`` parses every content file without bs4/lxml.

Two extraction modes are auto-detected per content file:

* **semantic** — files containing ``<p>`` elements (Books 1-3). Headings come from in-file
  ``<hN>`` tags plus the navigation document's nested table of contents; body text comes from
  ``<p>`` elements.
* **fixed-layout** — files with no ``<p>`` elements (Book 4). Each page is a full-page scan image
  plus a born-digital per-word ``<span>`` text layer. The running header (first inner div, e.g.
  ``"24 Chapter 3"`` / ``"Family Friends 39"``) is stripped, its printed page number captured, and
  the remaining line divs are joined into one verbatim page block.

Output: one markdown file per book under the corpus directory. Headings encode the source locator
(``# Book`` / ``## Chapter`` / ``### Section``) and ``<!-- page N -->`` comments mark page
boundaries. The corpus is gitignored — verbatim copyrighted text is never committed.

Run ``python extract_epub.py --help`` for usage.
"""

from __future__ import annotations

import argparse
import posixpath
import re
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import cast
from xml.etree import (
    ElementTree as ET,  # type annotations only; parsing uses defusedxml below
)

import defusedxml.ElementTree


def parse_xml_element(data: bytes) -> ET.Element:
    """Parse XML bytes to a typed Element (defusedxml stubs are incomplete)."""
    return cast(
        ET.Element,
        defusedxml.ElementTree.fromstring(data),  # pyright: ignore[reportUnknownMemberType]
    )


XHTML = "{http://www.w3.org/1999/xhtml}"
OPF = "{http://www.idpf.org/2007/opf}"
OPS = "{http://www.idpf.org/2007/ops}"
CONTAINER = "{urn:oasis:names:tc:opendocument:xmlns:container}"

# Navigation labels for non-craft front/back matter pages that carry no body prose.
# Compared case-insensitively against the top-level table-of-contents title.
SKIP_LABELS = frozenset(
    {
        "cover",
        "coveri",
        "title page",
        "copyright",
        "copyright page",
        "contents",
        "table of contents",
        "permissions",
        "index",
        "about the author",
        "back cover",
        "spine",
    }
)

# Heading-tag local names in the XHTML namespace.
HEADING_TAGS = frozenset(f"{XHTML}h{n}" for n in range(1, 7))

# Block-level tags. An element is a "leaf block" (its full text is emitted as one paragraph) when it
# has no block-level child; otherwise it is a container and the walk descends into it. This captures
# text in <li>, <td>, <blockquote>, bare <div>, etc. — not just <p> — so nothing is dropped.
BLOCK_TAGS = HEADING_TAGS | frozenset(
    f"{XHTML}{tag}"
    for tag in (
        "p",
        "div",
        "section",
        "article",
        "aside",
        "main",
        "header",
        "footer",
        "figure",
        "figcaption",
        "blockquote",
        "pre",
        "ul",
        "ol",
        "li",
        "dl",
        "dd",
        "dt",
        "table",
        "thead",
        "tbody",
        "tfoot",
        "tr",
        "td",
        "th",
        "caption",
    )
)


@dataclass(frozen=True, slots=True)
class TocEntry:
    """One table-of-contents anchor. ``level`` 0 is a chapter; deeper levels are sections."""

    level: int
    title: str
    file: str
    anchor: str | None


@dataclass(frozen=True, slots=True)
class Block:
    """A rendered unit of output. ``kind`` is chapter | section | page | para."""

    kind: str
    text: str


def normalize_ws(text: str) -> str:
    """Collapse all runs of whitespace to a single space and strip the ends."""
    return re.sub(r"\s+", " ", text).strip()


def element_text(element: ET.Element) -> str:
    """Return the whitespace-normalized concatenation of all descendant text."""
    return normalize_ws("".join(element.itertext()))


def _resolve_href(base_dir: str, href: str) -> str:
    """Resolve a manifest/nav href against its containing directory.

    The empty-``base_dir`` branch returns the href unchanged: applying ``normpath`` there
    would rewrite the string (drop ``./``, collapse ``//``, resolve ``..``) and these
    resolved hrefs are used as dict keys, so a normalized key could silently miss a lookup.
    """
    if not base_dir:
        return href
    return posixpath.normpath(posixpath.join(base_dir, href))


def find_opf_path(zip_map: dict[str, bytes]) -> str:
    """Resolve the OPF package path via ``META-INF/container.xml`` (the authoritative pointer)."""
    container = parse_xml_element(zip_map["META-INF/container.xml"])
    rootfile = container.find(f".//{CONTAINER}rootfile")
    if rootfile is None or not rootfile.get("full-path"):
        msg = "container.xml has no rootfile full-path"
        raise ValueError(msg)
    return rootfile.get("full-path", "")


def parse_opf(opf_bytes: bytes, opf_path: str) -> tuple[str, list[str], str]:
    """Parse the OPF package document.

    Returns ``(book_title, spine_hrefs, nav_href)`` where hrefs are zip-relative paths resolved
    against the OPF directory. ``spine_hrefs`` is the reading order; ``nav_href`` points at the
    EPUB 3 navigation document (manifest item with ``properties`` containing ``nav``).
    """
    root = parse_xml_element(opf_bytes)
    opf_dir = posixpath.dirname(opf_path)

    title_el = root.find(".//{http://purl.org/dc/elements/1.1/}title")
    book_title = element_text(title_el) if title_el is not None else "Untitled"

    manifest: dict[str, str] = {}
    nav_href = ""
    for item in root.iter(f"{OPF}item"):
        item_id = item.get("id", "")
        href = item.get("href", "")
        resolved = _resolve_href(opf_dir, href)
        manifest[item_id] = resolved
        properties = item.get("properties", "")
        if "nav" in properties.split():
            nav_href = resolved

    spine_hrefs: list[str] = []
    spine = root.find(f"{OPF}spine")
    if spine is not None:
        for itemref in spine.iter(f"{OPF}itemref"):
            idref = itemref.get("idref", "")
            if idref in manifest:
                spine_hrefs.append(manifest[idref])

    return book_title, spine_hrefs, nav_href


def _nav_by_type(nav_root: ET.Element, nav_type: str) -> ET.Element | None:
    for nav in nav_root.iter(f"{XHTML}nav"):
        if nav.get(f"{OPS}type") == nav_type:
            return nav
    return None


def _split_href(href: str) -> tuple[str, str | None]:
    if "#" in href:
        file, anchor = href.split("#", 1)
        return file, anchor
    return href, None


def parse_toc(nav_bytes: bytes, nav_path: str) -> list[TocEntry]:
    """Parse the nested table-of-contents ``<ol>`` into flat ``TocEntry`` rows with depth levels."""
    root = parse_xml_element(nav_bytes)
    toc = _nav_by_type(root, "toc")
    if toc is None:
        return []
    nav_dir = posixpath.dirname(nav_path)
    entries: list[TocEntry] = []

    def walk(ol: ET.Element, level: int) -> None:
        for li in ol.findall(f"{XHTML}li"):
            anchor_el = li.find(f"{XHTML}a")
            if anchor_el is not None and anchor_el.get("href"):
                file, anchor = _split_href(anchor_el.get("href", ""))
                resolved = _resolve_href(nav_dir, file)
                entries.append(
                    TocEntry(level, element_text(anchor_el), resolved, anchor)
                )
            child_ol = li.find(f"{XHTML}ol")
            if child_ol is not None:
                walk(child_ol, level + 1)

    top = toc.find(f"{XHTML}ol")
    if top is not None:
        walk(top, 0)
    return entries


def parse_page_list(nav_bytes: bytes, nav_path: str) -> dict[str, str]:
    """Map content-file path -> first printed page label from the ``page-list`` navigation."""
    root = parse_xml_element(nav_bytes)
    page_list = _nav_by_type(root, "page-list")
    if page_list is None:
        return {}
    nav_dir = posixpath.dirname(nav_path)
    pages: dict[str, str] = {}
    for anchor_el in page_list.iter(f"{XHTML}a"):
        file, _ = _split_href(anchor_el.get("href", ""))
        resolved = _resolve_href(nav_dir, file)
        label = element_text(anchor_el)
        pages.setdefault(resolved, label)
    return pages


def header_page_number(header_text: str) -> str | None:
    """Extract the printed page number from a fixed-layout running header.

    Headers look like ``"39"``, ``"Family Friends 39"`` (recto) or ``"24 Chapter 3"`` (verso).
    The running ``Chapter N`` label is removed first so the page number is the lone remaining
    integer. Returns ``None`` when no single page number can be isolated (caller falls back to the
    page-list label).
    """
    cleaned = re.sub(r"\bchapter\s+\d+\b", " ", header_text, flags=re.IGNORECASE)
    numbers = re.findall(r"\b\d{1,4}\b", cleaned)
    if len(numbers) == 1:
        return numbers[0]
    return None


def _content_div(body: ET.Element) -> ET.Element | None:
    """Find the fixed-layout text container — the body div with the most child divs."""
    best: ET.Element | None = None
    best_count = 0
    for div in body.iter(f"{XHTML}div"):
        child_divs = [c for c in div if c.tag == f"{XHTML}div"]
        if len(child_divs) > best_count:
            best_count = len(child_divs)
            best = div
    return best if best_count >= 2 else None


_ROMAN_NUMERAL_RE = re.compile(r"^[ivxlcdm]+$")


def _is_structural_header(text: str) -> bool:
    """True when a fixed-layout page's leading div is a running header or page marker
    rather than body prose.

    A leading div is structural when it is an arabic page number, a roman-numeral page
    number, or a short all-caps section label (e.g. ``ACKNOWLEDGMENTS``). Body-prose
    leading divs (normal sentences, which on some pages carry no running header) return
    ``False`` so their text is preserved.
    """
    stripped = normalize_ws(text)
    if not stripped:
        return True
    if header_page_number(stripped) is not None:
        return True
    if _ROMAN_NUMERAL_RE.match(stripped.casefold()):
        return True
    letters = [c for c in stripped if c.isalpha()]
    if letters:
        upper_ratio = sum(1 for c in letters if c.isupper()) / len(letters)
        if upper_ratio >= 0.8 and len(stripped.split()) <= 5:
            return True
    return False


def extract_fixed_layout(
    xhtml_bytes: bytes, page_list_label: str | None
) -> list[Block]:
    """Extract one verbatim page block from a fixed-layout (Book 4) page file.

    The leading line div is stripped only when it is a running header or page marker
    (see :func:`_is_structural_header`); a body-prose leading div is kept so its text is
    not lost. The printed page number drives the page marker (falling back to the page-list
    label), and the remaining line divs join into a single page block.
    """
    root = parse_xml_element(xhtml_bytes)
    body = root.find(f"{XHTML}body")
    if body is None:
        return []
    content = _content_div(body)
    if content is None:
        return []
    line_divs = [c for c in content if c.tag == f"{XHTML}div"]
    if not line_divs:
        return []

    header_text = element_text(line_divs[0])
    if _is_structural_header(header_text):
        page_label = header_page_number(header_text) or page_list_label
        body_divs = line_divs[1:]
    else:
        page_label = page_list_label
        body_divs = line_divs
    body_text = normalize_ws(" ".join(element_text(d) for d in body_divs))
    if not body_text:
        return []

    blocks: list[Block] = []
    if page_label:
        blocks.append(Block("page", page_label))
    blocks.append(Block("para", body_text))
    return blocks


def extract_semantic(
    xhtml_bytes: bytes,
    section_anchors: dict[str, str],
    chapter_title: str,
) -> list[Block]:
    """Extract heading/paragraph blocks from a semantic (Books 1-3) content file in document order.

    Walks the body depth-first. ``<hN>`` tags and elements whose ``id`` is in ``section_anchors``
    emit section headings (deduplicated against the chapter title and each other). Every leaf block
    (a block element with no block-level child — ``<p>``, ``<li>``, ``<td>``, ``<blockquote>``, bare
    ``<div>``, …) emits its full verbatim text as one paragraph, so no body text is dropped.
    """
    root = parse_xml_element(xhtml_bytes)
    body = root.find(f"{XHTML}body")
    if body is None:
        return []
    chapter_norm = normalize_ws(chapter_title).casefold()
    blocks: list[Block] = []
    seen_sections: set[str] = set()

    def emit_section(title: str) -> None:
        norm = normalize_ws(title).casefold()
        if title and norm not in seen_sections and norm != chapter_norm:
            blocks.append(Block("section", title))
            seen_sections.add(norm)

    def walk(parent: ET.Element) -> None:
        for element in parent:
            if element.tag == f"{XHTML}img":
                continue
            element_id = element.get("id")
            if element_id and element_id in section_anchors:
                emit_section(section_anchors[element_id])
            if element.tag in HEADING_TAGS:
                emit_section(element_text(element))
                continue
            if any(child.tag in BLOCK_TAGS for child in element):
                walk(element)
            else:
                text = element_text(element)
                if text:
                    blocks.append(Block("para", text))

    walk(body)
    return blocks


def slugify(text: str, max_len: int = 60) -> str:
    """Lowercase, hyphenate, drop punctuation, cap length at a word boundary — for filenames."""
    text = re.sub(r"[^\w\s-]", "", text.casefold())
    slug = re.sub(r"[\s_]+", "-", text).strip("-")
    if len(slug) > max_len:
        slug = slug[:max_len].rsplit("-", 1)[0]
    return slug


def build_blocks(zip_map: dict[str, bytes]) -> tuple[str, list[Block]]:
    """Walk the spine and produce the ordered block stream for a whole book."""
    opf_path = find_opf_path(zip_map)
    book_title, spine_hrefs, nav_href = parse_opf(zip_map[opf_path], opf_path)
    toc = parse_toc(zip_map[nav_href], nav_href)
    page_labels = parse_page_list(zip_map[nav_href], nav_href)

    chapters = {e.file: e.title for e in toc if e.level == 0}
    sections_by_file: dict[str, dict[str, str]] = {}
    for entry in toc:
        if entry.level > 0 and entry.anchor:
            sections_by_file.setdefault(entry.file, {})[entry.anchor] = entry.title

    blocks: list[Block] = []
    current_chapter = ""
    emitted_chapter = ""
    for href in spine_hrefs:
        if href in chapters:
            current_chapter = chapters[href]
        if (
            not current_chapter
            or normalize_ws(current_chapter).casefold() in SKIP_LABELS
        ):
            continue
        if href not in zip_map:
            continue
        xhtml = zip_map[href]
        if b"<p>" in xhtml or b"<p " in xhtml:
            file_blocks = extract_semantic(
                xhtml, sections_by_file.get(href, {}), current_chapter
            )
        else:
            file_blocks = extract_fixed_layout(xhtml, page_labels.get(href))
        if not file_blocks:
            continue
        if current_chapter != emitted_chapter:
            blocks.append(Block("chapter", current_chapter))
            emitted_chapter = current_chapter
        blocks.extend(file_blocks)
    return book_title, blocks


def render_markdown(book_title: str, blocks: list[Block]) -> str:
    """Render the block stream to locator-encoding markdown."""
    lines: list[str] = [f"# {book_title}", ""]
    last_chapter = ""
    for block in blocks:
        if block.kind == "chapter":
            if block.text != last_chapter:
                lines += [f"## {block.text}", ""]
                last_chapter = block.text
        elif block.kind == "section":
            lines += [f"### {block.text}", ""]
        elif block.kind == "page":
            lines += [f"<!-- page {block.text} -->", ""]
        else:
            lines += [block.text, ""]
    return "\n".join(lines).rstrip() + "\n"


def read_epub(path: Path) -> dict[str, bytes]:
    """Read an EPUB (zip) into a name -> bytes map."""
    with zipfile.ZipFile(path) as zf:
        return {name: zf.read(name) for name in zf.namelist()}


def extract_epub(epub_path: Path, out_dir: Path) -> Path:
    """Extract one EPUB to ``<out_dir>/<book-slug>.md`` and return the output path."""
    zip_map = read_epub(epub_path)
    book_title, blocks = build_blocks(zip_map)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{slugify(book_title)}.md"
    out_path.write_text(render_markdown(book_title, blocks), encoding="utf-8")
    return out_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Extract Pat Pattison craft EPUBs to verbatim normalized markdown.",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("tools/corpus-extract/source"),
        help="Directory containing the source .epub files.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("apps/monolith-api/Modules/CraftKnowledge/corpus"),
        help="Output directory for the extracted markdown corpus (gitignored).",
    )
    args = parser.parse_args(argv)

    epubs = sorted(args.source.glob("*.epub"))
    if not epubs:
        print(f"No .epub files found in {args.source}", file=sys.stderr)
        return 1

    for epub in epubs:
        out_path = extract_epub(epub, args.out)
        chars = out_path.stat().st_size
        print(f"{epub.name} -> {out_path}  ({chars:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
