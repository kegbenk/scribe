# ADR-0005 — EPUB extraction in-repo, zero third-party dependencies

**Status:** Accepted — 2026-07-02

## Context

Scribe's schema always anticipated multiple producers (`sourceType: native | marker | epub | text`), but the Swift runtime only extracted PDFs. Every reader app that consumes Scribe also wants EPUB — it roughly doubles the addressable audience for the "on-device document extraction" positioning, and both existing consumers (rsvp-reader, velo-macos) import books in both formats.

The obvious implementation path was a third-party dependency (ZIPFoundation for the container, SwiftSoup for XHTML). That conflicts with two standing commitments:

1. The published root `Package.swift` is dependency-free — consumers get Apple frameworks only. This is a load-bearing line in the README competitive table.
2. ADR-0003 keeps extraction logic portable in spirit; a dependency graph makes an eventual second runtime port harder to reason about.

## Decision

EPUB (2 and 3) extraction is implemented in-repo, in the `Scribe` library target, with zero new dependencies:

- **`ZipReader.swift`** — a minimal read-only zip parser (central directory + local headers, stored and deflate methods). Deflate decoding uses the `Compression` framework (`COMPRESSION_ZLIB` is raw deflate, which is exactly zip's format). No encryption, no zip64.
- **`EPUBExtraction.swift`** — `container.xml` → OPF (manifest/spine/metadata) → toc (EPUB3 nav document, falling back to EPUB2 NCX) → per-spine-item XHTML text extraction, all via Foundation's `XMLParser`.
- **Dispatch** happens inside `ScribeProcessor.processFileForResult`: extension `.epub`, falling back to zip-magic + `mimetype` entry sniffing. `extractContent(from:)` / `processForTest(url:)` signatures are unchanged — consumers get EPUB support without any API change.

The EPUB path emits the **same chapter contract** as the PDF path (`title`, `level`, `plainText`, `htmlContent`, `tokens`, `paragraphStarts`, `images`, `startPage`, `footnotes`, word indices via the shared tokenizer), plus `sourceType: "epub"`.

Notable behaviors:

- **Fragment segmentation.** Classic single-file EPUBs put every chapter in one XHTML document with fragment hrefs (`book.html#ch3`). The XHTML parser records every `id`/`<a name>` anchor's paragraph boundary, and spine documents with multiple toc entries are split at those anchors. Without this, such books collapse into one giant chapter.
- **`startPage`** is the 1-based spine ordinal (EPUBs have no physical pages).
- **Toc fidelity is bounded by the source.** A conversion whose NCX labels are `page-1`, `page-16`, … extracts faithfully with those titles; Scribe does not attempt to out-guess the book's own declared structure.
- **Entity preprocessing.** `XMLParser` resolves only the five XML entities; common HTML named entities (`&nbsp;`, `&mdash;`, …) are translated before parsing so real-world XHTML doesn't abort the parse. On a parse error mid-document, text accumulated so far is kept.

## Consequences

- Both consumers gain EPUB import with no integration work.
- The zip reader is deliberately minimal. Encrypted EPUBs (DRM) and zip64 archives are rejected (extraction returns nil). This is correct behavior for DRM and an acceptable gap for >4GB archives.
- Footnote separation ships with the initial implementation: `epub:type="footnote"/"endnote"/"rearnote"` and `role="doc-footnote"/"doc-endnote"` containers are lifted out of body text into the `footnotes` array (leading numbers parsed; unnumbered notes numbered sequentially per chapter). Inline noteref markers stay in the body, matching the PDF path.
- The eval corpus includes an EPUB book (`corpus/pride-prejudice`, Gutenberg #1342). Its ground truth is *derived from the book's own declared NCX/spine structure* by `corpus/pride-prejudice/annotate.py` (Python stdlib, independent of the Swift path) and encodes the ideal cross-file chapter boundaries — the Swift implementation's file-boundary segmentation gap is visible in its `chapter_titles` score (~0.70) rather than annotated away.
- The XHTML text extractor is SAX-based and structural (block elements → paragraphs); it does not evaluate CSS. Books that hide content via stylesheets will include that content.
