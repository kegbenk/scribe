# Scribe

[![CI](https://github.com/kegbenk/scribe/actions/workflows/ci.yml/badge.svg)](https://github.com/kegbenk/scribe/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-lightgrey.svg)](Package.swift)

On-device PDF and EPUB content extraction for iOS and macOS. Produces structured chapter/footnote/image output using only Apple frameworks (PDFKit, Vision, CoreGraphics, Foundation) — no server, no network, no ML models, no third-party dependencies.

## Why Scribe?

| | Scribe | Marker | MinerU | Nougat |
|---|---|---|---|---|
| **Runs on-device** | Yes (iOS/macOS) | No (GPU server) | No (GPU server) | No (GPU server) |
| **Dependencies** | Apple frameworks only | PyTorch, transformers | PyTorch, detectron2 | PyTorch, transformers |
| **Chapter detection** | PDF outline + TOC parsing + heuristics | ML-based | Layout analysis | Seq2seq |
| **Footnote separation** | 6 adaptive strategies | Basic | None | None |
| **Image extraction** | XObject streams + fallback render | ML segmentation | Layout detection | None |
| **Output format** | contentStructure JSON | Markdown/JSON | Markdown | Markdown |
| **Processing time** | 0.3–22s on-device ([measured](docs/benchmarks.md)) | 30-120s (GPU) | 60-300s (GPU) | 60-300s (GPU) |

Scribe is purpose-built for the niche no competitor occupies: **fast, private, on-device document extraction** that produces reading-app-ready structured output. PDF and EPUB go through the same pipeline and emit the same contract: one integration, both formats. Latency and fidelity numbers, with reproduction steps, live in [docs/benchmarks.md](docs/benchmarks.md).

## Quick Start

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/kegbenk/scribe.git", from: "0.1.0")
]
```

### Usage

```swift
import Scribe

// Extract structured content from a PDF or EPUB
if let result = ScribeProcessor.extractContent(from: pdfURL) {
    let text = result["text"] as! String
    let chapters = result["chapters"] as! [[String: Any]]
    let hasStructure = result["hasStructure"] as! Bool

    for chapter in chapters {
        print(chapter["title"] as? String ?? "Untitled")
        print("Words: \(chapter["wordCount"] as? Int ?? 0)")
    }
}
```

### CLI

```bash
cd swift/
swift run scribe-cli extract myfile.pdf --output content.json
swift run scribe-cli extract myfile.pdf --format text
```

## Document Intelligence (optional)

`ScribeProcessor` above is the deterministic core — pure, on-device extraction with
no models. `DocumentIntelligence` is an **optional** enrichment layer that adds NLP
and Apple Intelligence analysis on top of the same extraction. Per
[ADR-0002](docs/architecture/adr/0002-document-intelligence-as-optional-enrichment.md)
it **never gates extraction**: if the models are unavailable you still get full
`contentStructure`, just without the AI fields.

**Availability.** The whole `DocumentIntelligence` surface is gated
`@available(iOS 26.0, macOS 26.0, *)`, with two tiers inside it:

| Tier | Methods | Requires |
|---|---|---|
| **NaturalLanguage** (entities, language, sentiment) | `extract`, `extractWithNLP`, `extractEntities(from:)`, `detectLanguage(of:)`, `analyzeSentiment(of:)` | iOS 26+ / macOS 26+ — no Apple Intelligence needed |
| **FoundationModels** (summarize, classify, ask) | `process`, `analyze`, `summarize`, `classify(_:)`, `ask(_:context:)` | iOS 26+ / macOS 26+ **and** Apple Intelligence — check `DocumentIntelligence.isAvailable` |

The `scribe-cli analyze` subcommand and the `extract --entities` flag are likewise
gated to iOS/macOS 26+. Deterministic extraction via `ScribeProcessor` stays on
iOS 15+ / macOS 12+ and never touches this layer.

```swift
import Scribe

if #available(iOS 26.0, macOS 26.0, *) {
    let intelligence = DocumentIntelligence()

    // NLP-only enrichment — no Apple Intelligence required.
    // Returns a ContentStructure dict with per-chapter + global entities and language.
    let enriched = try intelligence.extractWithNLP(document: pdfURL)

    // Full AI analysis — only when Apple Intelligence is available.
    if DocumentIntelligence.isAvailable {
        let analysis = try await intelligence.analyze(document: pdfURL)
        print(analysis.summary.text)          // DocumentSummary
        print(analysis.classification.genre)  // DocumentClassification
        for person in analysis.entities where person.type == .person {
            print(person.text)                // [NamedEntity]
        }
    }
}
```

See [`swift/Sources/Scribe/DocumentIntelligence.swift`](swift/Sources/Scribe/DocumentIntelligence.swift)
for the full method list (`summarize`, `classify`, `ask`, `analyzePageStructure`,
`recognizeText`, …).

## Architecture

```
PDF file
  │
  ├─ Book Classifier ──── digital-clean vs scanned-OCR, academic vs general
  │
  ├─ Text Extraction ──── PDFKit text + Vision OCR fallback, two-column detection
  │
  ├─ Chapter Detection ── PDF outline → TOC page parse → heading heuristics
  │
  ├─ Footnote Detection ─ 6 adaptive strategies (gap, font-size, citation patterns)
  │
  ├─ Image Extraction ─── CGPDFPage XObject parsing, JPEG passthrough
  │
  ├─ Running Headers ──── Detect & strip repeated page headers
  │
  └─ Output ──────────── contentStructure JSON (chapters, footnotes, images, TOC)
```

### Processing Pipeline

1. **Classify** — Sample pages to determine book type (digital vs scanned) and content type (academic vs general). This drives adaptive strategy selection throughout the pipeline.

2. **Extract** — Pull text from each PDF page using PDFKit. For two-column layouts (common in scanned books), split into separate logical pages. Fall back to Vision OCR when PDFKit returns no text.

3. **Structure** — Detect chapters via PDF outline (bookmark tree), Contents/TOC page parsing, or heading-pattern heuristics. Detect back-matter sections (Bibliography, Index, Notes).

4. **Separate** — Split body text from footnotes using 6 strategies ranked by book profile. Academic scanned books prioritize citation-pattern matching; clean digital books use font-size differentials.

5. **Clean** — Strip running headers (repeated text across pages), normalize whitespace, calculate word boundaries with tokenization parity.

6. **Output** — Produce contentStructure JSON with chapters, footnotes, images, and table of contents.

## Output Format

Scribe produces `contentStructure` JSON — a universal document format designed for reading applications:

```json
{
  "chapters": [
    {
      "title": "Chapter 1: The Beginning",
      "plainText": "Full chapter text...",
      "htmlContent": "<p>Full chapter text...</p>",
      "startPage": 12,
      "startWordIndex": 0,
      "endWordIndex": 4521,
      "wordCount": 4521,
      "footnotes": [
        { "number": 1, "text": "See Smith (2020), p. 42." }
      ],
      "images": [
        { "src": "data:image/jpeg;base64,...", "width": 800, "height": 600 }
      ],
      "isBackMatter": false
    }
  ],
  "toc": [
    { "title": "Chapter 1: The Beginning", "wordIndex": 0, "chapterIndex": 0 }
  ],
  "hasStructure": true
}
```

See [`shared/content-structure.schema.json`](shared/content-structure.schema.json) for the full JSON Schema.

## Evaluation

Scribe includes a fidelity scoring pipeline that measures extraction quality across 7 dimensions:

| Dimension | What it measures |
|---|---|
| `chapter_boundaries` | Chapter start/end alignment vs ground truth |
| `titles` | Chapter title accuracy (fuzzy matching) |
| `footnotes` | Footnote detection and separation |
| `headers` | Running header removal completeness |
| `completeness` | Text coverage (no dropped content) |
| `reading_order` | Correct sequential ordering |
| `back_matter` | Bibliography/index/notes detection |

### Running the eval

```bash
cd eval/
npm install
node score.js ../corpus/healing-dream/native.json ../corpus/healing-dream/predicted.json
node regression.js   # Check all books against baselines
```

### Test corpus

The `corpus/` directory contains 10 books spanning different PDF types:

- **healing-dream** — Clean digital, academic (primary test book)
- **911-commission** — Government report, complex layout
- **alice-wonderland** — Fiction, illustrated
- **janus-faces** — Scanned OCR, academic with heavy footnotes
- **sherlock-holmes** — Fiction, clean digital
- **attention-paper** — Academic paper, two-column
- And more...

## Components

| Directory | Description | Language |
|---|---|---|
| `swift/` | Core PDF processor — Swift Package | Swift |
| `shared/` | contentStructure schema + tokenizer | JSON/JS/Swift |
| `eval/` | Fidelity scoring pipeline | Node.js |
| `vision/` | MLX-based vision inference (Apple Silicon) | Node.js/Python |
| `converters/` | Format converters (Marker JSON, etc.) | Node.js |
| `corpus/` | Test corpus with baselines | JSON |

## Requirements

- **Swift Package:** iOS 15+ or macOS 12+, Swift 5.9+
- **Eval pipeline:** Node.js 18+
- **Vision pipeline:** Apple Silicon Mac, Python 3.10+, MLX

## License

Apache 2.0 — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — the short version: tests green, the
fidelity regression gate green, no new dependencies, no eval theater.
