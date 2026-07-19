# corpus-extract

Extract the Pat Pattison craft EPUBs into verbatim normalized markdown with stable
locators, for the `CraftKnowledge` retrieval module (Phase 3 ingestion consumes the output).

Dependency-light: Python standard library plus `defusedxml` for safe XML parsing. The source
EPUBs are Calibre-produced and parse as well-formed XML.

## Usage

```bash
# From the repository root. Extracts all source EPUBs to the gitignored corpus directory.
uv run --project tools/corpus-extract python tools/corpus-extract/extract_epub.py
```

```bash
# Custom source / output directories.
uv run --project tools/corpus-extract python tools/corpus-extract/extract_epub.py \
  --source tools/corpus-extract/source \
  --out apps/monolith-api/Modules/CraftKnowledge/corpus
```

Source EPUBs: `tools/corpus-extract/source/*.epub` (tracked).
Output: `apps/monolith-api/Modules/CraftKnowledge/corpus/<book-slug>.md` (gitignored — verbatim
copyrighted text is never committed; regenerate on demand).

## Output format

One markdown file per book. Headings encode the source locator and `<!-- page N -->` comments
mark page boundaries:

```markdown
# <Book Title>

## <Chapter>

### <Section>

<!-- page 39 -->

<verbatim paragraph text>
```

Two extraction modes are auto-detected per content file:

- **semantic** — files with `<p>` elements (Books 1-3): headings from in-file `<hN>` tags plus the
  navigation table of contents; body text from `<p>` elements.
- **fixed-layout** — files without `<p>` elements (Book 4): a born-digital per-word `<span>` text
  layer behind a full-page image. The running header is stripped, its printed page number captured,
  and the line divs are joined into one verbatim page block per page.

## Tests

```bash
cd tools/corpus-extract && uv run pytest
```

Unit tests cover the pure parsing functions; golden-sample tests run the full extractor against the
real tracked EPUBs and assert verbatim fidelity and chapter coverage.
