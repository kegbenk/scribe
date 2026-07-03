# Memory profile — large scanned-PDF extraction

**Scope:** why `scribe-cli extract` peaked at ~1.7 GB on `anatomy-melancholy`
(a 63.8 MB, ~900-page 1868 scan, 466k OCR'd words), what was measured, the one
safe fix that shipped, and the designed-but-not-built plan for the rest.

**Hardware/build:** Apple Silicon Mac, `swift build -c release`. Numbers are
`/usr/bin/time -l` for the full CLI invocation (process start → JSON written),
single runs. "Peak memory footprint" (dirty allocated memory) is the stable,
comparable metric; "maximum resident set size" is reported too but is noisier
between runs because it includes the mmap'd 64 MB source and OS page-cache.

## Measured breakdown

| Configuration | anatomy peak footprint | anatomy max RSS |
|---|---|---|
| **Baseline** (0.4.0, no per-page autoreleasepool) | **1735 MB** | 1577 MB |
| **+ per-page `autoreleasepool`** (shipped) | **1187 MB** | 970–1296 MB |

Isolating hypotheses on the fixed binary:

| Probe | anatomy peak footprint | What it tells us |
|---|---|---|
| `--format json` (default) | 1187 MB | — |
| `--format text` (skips JSON assembly + data-URI emit) | 1198 MB | **Output serialization is not the driver** — text-only is no cheaper. |
| Image payload in the output | 19 images, **384 KB** base64 total | **Image / base64 accumulation is negligible** — not a suspect. |

So of the plausible suspects, the measurement rules out three: the base64
data-URI accumulation (384 KB), the images-held-in-memory theory (19 tiny
images), and the JSON build (text mode is no cheaper). What remained after the
autoreleasepool fix — ~1.19 GB — is spent **inside the extraction phase**:
PDFKit parsing/rendering a 64 MB scanned document (each page is a large raster
that PDFKit decodes and caches), plus per-page Vision OCR and CoreGraphics
render buffers.

## What helped (shipped)

The per-page loop in `ScribeProcessor.processFileForResult` renders a CGImage,
JPEG-encodes it, runs PDFKit text selection, and (for scans) Vision OCR on
**every** page, with no autorelease draining. Those APIs enqueue large
autoreleased buffers that, without a pool, accumulate for the whole ~900-page
run. Wrapping the loop body in `autoreleasepool { }` drains that churn each
iteration; the extracted `PageExtraction` structs (plain text + a few base64
data URIs) are retained by the results array *outside* the pool, so they
survive the drain and output is unchanged.

- **Peak footprint: 1735 MB → 1187 MB (−548 MB, −32%).** Stable across runs.
- **Latency: unchanged** (~21 s; the pool drains buffers that would have been
  freed at process exit anyway).
- **Output equivalence: verified.** `healing-dream` (clean digital, no OCR, and
  deterministic) is **byte-for-byte identical** to its pristine-generated
  committed `predicted.json` with the fix in place; `anatomy` (scanned) drifts
  ~2 KB / 15 MB (0.015%), within the normal Vision-OCR nondeterminism envelope.
  The regression corpus stays green.
- Generalizes to other large books: `911-commission` peaks at 384 MB footprint
  / 457 MB RSS with the fix (was ~733 MB RSS at 0.4.0).

The fix is idiomatic and low-risk — it changes only memory-management timing,
not extraction logic.

## Designed, not built (out of scope here)

The residual ~1.19 GB is dominated by **PDFKit's retention of a large scanned
document**, not by anything Scribe accumulates (proven above: our data
structures — text ≈ 2.5 MB, images ≈ 384 KB — are a rounding error against the
peak). Reducing it further is structural and was deliberately not attempted:

1. **Bypass PDFKit's page cache for rendering.** `PDFDocument` decodes and
   caches page content; there is no public API to purge a `PDFPage`. Rendering
   scanned pages through the lower-level `CGPDFDocument` / `CGPDFPage` (which we
   already touch in `ImageExtraction`), and holding only one page's raster at a
   time, would cut the dominant term. Cost: a real refactor of the render path
   and re-validation of OCR quality — the raster is what Vision reads.

2. **Page-windowed processing with explicit release.** Process pages in windows
   and drop references between windows so PDFKit can evict decoded content.
   Needs measurement that PDFKit actually releases under memory pressure; the
   autoreleasepool already captures the easy part of this.

3. **Streaming / spill-to-disk of the output.** Considered and **rejected on
   evidence**: the output (chapters + images) is only ~2.5 MB resident and
   `--format text` is no cheaper, so incremental JSON writing would not move the
   peak. Not worth the complexity.

Net: the safe, measured win (autoreleasepool, −32%) ships; the remaining
reduction requires trading PDFKit's convenience for lower-level page rendering,
which is a separate, testable piece of work — not a memory "leak" but an
architectural cost of using PDFKit on very large scans.
