# Scribe

On-device PDF content extraction for iOS and macOS. Produces structured chapter/footnote/image output from any PDF using only Apple frameworks (PDFKit, Vision, CoreGraphics) — no server, no network, no ML models required.

## Why Scribe?

| | Scribe | Marker | MinerU | Nougat |
|---|---|---|---|---|
| **Runs on-device** | Yes (iOS/macOS) | No (GPU server) | No (GPU server) | No (GPU server) |
| **Dependencies** | Apple frameworks only | PyTorch, transformers | PyTorch, detectron2 | PyTorch, transformers |
| **Chapter detection** | PDF outline + TOC parsing + heuristics | ML-based | Layout analysis | Seq2seq |
| **Footnote separation** | 6 adaptive strategies | Basic | None | None |
| **Image extraction** | XObject streams + fallback render | ML segmentation | Layout detection | None |
| **Output format** | contentStructure JSON | Markdown/JSON | Markdown | Markdown |
| **Processing time** | 1-5s (on-device) | 30-120s (GPU) | 60-300s (GPU) | 60-300s (GPU) |

Scribe is purpose-built for the niche no competitor occupies: **fast, private, on-device PDF extraction** that produces reading-app-ready structured output.

## Quick Start

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/pleroma/scribe.git", from: "0.1.0")
]
```

### Usage

```swift
import Scribe

// Extract structured content from a PDF
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
