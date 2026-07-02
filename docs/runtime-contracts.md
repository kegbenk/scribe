# Scribe — Runtime Contracts (v0)

The bootstrap plan calls for cross-runtime contracts that stay aligned across Swift, TS, and Python. Right now only Swift is a runtime. This document records what contracts exist today, where they live, and the rules for changing them.

## Active contracts

### 1. `contentStructure` JSON schema

**Location:** [`../shared/content-structure.schema.json`](../shared/content-structure.schema.json)
**Producers:** `ScribeProcessor.extractContent(from:)` (Swift), `DocumentIntelligence.process()` (Swift)
**Consumers:** `rsvp-reader` (JS-side via Capacitor), `velo-macos` (Swift), `eval/` (Node)
**Status:** Stable in shape, evolving in details. The `intelligence` block is optional per [ADR-0002](architecture/adr/0002-document-intelligence-as-optional-enrichment.md).

The contract:

- A document → an array of chapters, plus a `toc`, plus a `hasStructure` flag, plus optional `intelligence`.
- A chapter → `{ title, plainText, htmlContent, startPage, startWordIndex, endWordIndex, wordCount, footnotes, images, isBackMatter }`.
- A TOC entry → `{ title, wordIndex, chapterIndex, level }`. `level` is a 0-based outline depth (0 = top-level, 1 = first-nested, etc.). New as of [ADR-0004](architecture/adr/0004-nested-outline-and-level-field.md); optional in the JSON schema; tolerated-on-decode by the Swift `TOCEntry` decoder (defaults to 0 when missing).
- Word indices are computed by the same tokenizer as `shared/tokenizer/parseText.js` and `ScribeTokenizer.parseText()` — they MUST agree.

Change rules: see "Schema changes" in [`ops/release-process.md`](ops/release-process.md).

### 2. Tokenizer parity

**Locations:** [`../shared/tokenizer/parseText.js`](../shared/tokenizer/parseText.js) and `swift/Sources/Scribe/Tokenizer.swift` (delegates to it conceptually)
**Producers:** Both implementations are producers; they MUST produce identical word boundaries.
**Consumers:** `rsvp-reader` (RSVP playback depends on word indices), `eval/` (fidelity scoring at word level)
**Status:** Stable.

Any change to tokenization rules is a breaking change. It must:

1. Be made in both implementations in the same PR.
2. Re-baseline the corpus (every book's `startWordIndex` / `endWordIndex` shifts).
3. Notify both consumers — `rsvp-reader` may need a re-extraction of cached books.

### 3. CLI contract

**Location:** [`../swift/Sources/ScribeCLI/ScribeCLI.swift`](../swift/Sources/ScribeCLI/ScribeCLI.swift)
**Surface:** `scribe-cli extract <path> [--format json|text] [--output path] [--entities]`, `scribe-cli analyze <path> [--output path]` (`--entities` and `analyze` require iOS/macOS 26+). `<path>` may be a PDF or an EPUB — format is dispatched inside `ScribeProcessor` (extension, falling back to zip-magic + mimetype sniffing), see [ADR-0005](architecture/adr/0005-epub-extraction-in-repo.md).
**Status:** Loose. Used by developers and by `vision/` / `converters/` tooling. Not a versioned contract.

## Contracts the bootstrap plan calls for, that DO NOT exist yet

| Plan contract | Status | When to add |
|---|---|---|
| `TaskDefinition` | Not present | When more than one task type (extraction, QA, summarize, extract-fields) needs a uniform invocation contract — likely Phase 1 retrieval/QA work |
| `DocumentSchema` (richer than current chapters) | Partial — current `contentStructure` covers most of it | Extend the existing schema rather than introducing a parallel one |
| `ChunkSchema` | Not present | When a retrieval / embedding index lands (Phase 1 deliverable, not started) |
| `RetrievalResult` | Not present | Same as above |
| `CitationSpan` | Not present | When answer-with-evidence flow is implemented |
| `ExtractionSchema` (structured field extraction) | Partial — `IntelligenceModels.swift` defines result types, not yet a public schema | When velo-macos or a new consumer asks for stable structured-field outputs |
| `EvalCase` / `EvalResult` | Implicit in `eval/` JSON shapes | Formalize when intelligence eval is added |
| `ModelArtifactManifest` | Not present | When a model artifact ships with the package (none today — all models are Apple-framework-provided) |

Each of these is on the backlog. None should be invented before a concrete consumer or test forces the shape.

## Rules for adding a new contract

1. **One concrete consumer or test must exist first.** No speculative schemas.
2. **JSON Schema, not just a Swift type.** Cross-runtime contracts are expressed in a portable spec; the Swift type is one materialization.
3. **Versioned from day one.** Either a `version` field in the schema, or filename-versioned (`task-definition.v1.schema.json`).
4. **Validation tooling lands with the schema.** A consumer that can't validate a contract isn't really using it.
5. **Mention in `CONSUMERS.md` if any external consumer depends on it.**

## Rules for changing an existing contract

See `docs/ops/release-process.md` § "Schema changes". Short form:

- Additive optional → minor bump
- Additive required → breaking, coordinate with consumers
- Removal, rename, type-tightening → breaking, coordinate with consumers
- Tokenization rule change → breaking, requires corpus re-baseline
