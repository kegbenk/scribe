# Scribe benchmarks

Measured numbers behind the README's positioning claims. Everything here is
reproducible from this repo: fidelity scores come from the locked eval
baselines (`corpus/*/baseline.json`, scored by `eval/score.js` against
hand-annotated ground truth), and latency is wall-clock time for
`scribe-cli extract` measured as below.

## Setup

- **Hardware:** Mac mini, Apple M4, 24 GB RAM
- **Build:** `swift build -c release`, Scribe 0.3.0 (2026-07-02)
- **Measurement:** wall-clock for the full CLI invocation (process start →
  JSON written), single run, no warm-up. On-device, no network.
- **Reproduce:** `swift build -c release --package-path swift`, then
  `node eval/perf.js` (sources via `corpus/download.sh` /
  `corpus/sources.json`); it reports wall-clock and peak RSS per book.

## PDF extraction

| Book | Kind | Size | Words | Latency | Fidelity* |
|---|---|---|---|---|---|
| attention-paper | two-column academic paper | 2.1 MB | 4.8k | **0.3 s** | 91.7% |
| sherlock-holmes | scanned fiction | 1.6 MB | 107k | **2.9 s** | 90.3% |
| self-help-smiles | scanned nonfiction, illustrated | 21.4 MB | 131k | **6.4 s** | 90.0% |
| healing-dream | clean digital academic | 4.7 MB | 45k | **7.8 s** | 96.2% |
| prometheus-atlas | digital nonfiction | 2.3 MB | 156k | **8.0 s** | 98.0% |
| 911-commission | government report, heavy footnotes | 2.4 MB | 424k | **17.4 s** | 77.9% |
| anatomy-melancholy | 1868 scan, dense OCR | 63.8 MB | 466k | **21.5 s** | — |
| alice-wonderland | scanned, heavily illustrated | 31.6 MB | 27k | **22.2 s** | 61.0% |

Peak memory (RSS, via `node eval/perf.js`) ranges from 64 MB
(attention-paper) through 733 MB (911-commission) up to **1.7 GB**
(anatomy-melancholy, a 64 MB scan). The big scanned books are fine on Macs
but above comfortable iOS budgets — worth knowing before pointing an iPhone
at a 600-page scan.

\* Fidelity is the weighted overall score against hand-annotated ground truth
across seven dimensions (chapter boundaries, chapter titles, footnote
separation, running-header removal, body-text completeness, reading order,
back-matter detection — see `docs/product/benchmark-definition.md`). Scores
are the locked regression baselines; CI fails if any dimension drops >2%.
anatomy-melancholy has no locked baseline yet. The two low scores are honest:
alice-wonderland's chapter boundaries and 911-commission's back-matter
detection are open problems, tracked in the baselines' justification notes.

## EPUB extraction

EPUB skips OCR and page-layout analysis entirely, so it is roughly an order
of magnitude faster than PDF:

| Book | Kind | Words | Chapters | Latency | Fidelity* |
|---|---|---|---|---|---|
| pride-prejudice (Gutenberg #1342) | EPUB2, fragment-anchor toc | 132k | 64 | **0.24 s** | 96.1% |
| Heaven and Hell (Swedenborg, NCE) | EPUB2, NCX toc, nested levels | 248k | 93 | **0.45 s** | — |

pride-prejudice is part of the locked regression corpus; its ground truth is
derived from the book's own declared NCX/spine structure
(`corpus/pride-prejudice/annotate.py`). Its `chapter_titles` dimension
(~0.70) honestly reflects a known gap: fragment segmentation cuts at
spine-file boundaries rather than across them (tracked in BACKLOG).

## Context: server-side extraction tools

Scribe does not compete with GPU document-AI pipelines on layout
reconstruction or table extraction, and the numbers below come from *their*
benchmarks on *their* corpora — they are order-of-magnitude context, not a
same-corpus comparison.

- [Procycons' 2025 benchmark](https://procycons.com/en/blogs/pdf-data-extraction-benchmark/)
  measures Docling, Unstructured, and LlamaParse for pipeline use; server-side
  processing for document batches runs tens of seconds to minutes per
  document on GPU hardware, and Docling leads complex-table accuracy (97.9%).
- [pdfmux's 2026 comparison](https://pdfmux.com/blog/pdfmux-vs-llamaparse-vs-docling-vs-unstructured-2026/)
  reports LlamaParse's cloud API at a consistent ~6 s per document — plus
  network round-trip, plus your documents leaving the device.
- [Firecrawl's 2026 parser roundup](https://www.firecrawl.dev/blog/best-pdf-parsers)
  covers the same tools for RAG ingestion.

What none of them offer is Scribe's actual niche: extraction that runs
*inside an iOS/macOS app*, in seconds, with a hard no-network guarantee
(`docs/ops/privacy-principles.md`), producing reading-app-ready chapters
with word-index precision. If you need bulk server ingestion with maximal
table fidelity, use Docling. If you need a book open on a phone with the
document never leaving it, that's Scribe.
