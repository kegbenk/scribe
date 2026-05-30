# Scribe — Product Requirements (v1)

This is the v1 PRD for Scribe-the-library. It is anchored on the two existing real consumers (`rsvp-reader`, `velo-macos`) rather than on speculative future users. Future user surfaces should extend this doc rather than replace it.

## Product thesis

A privacy-first, on-device document intelligence **library** that other applications embed to turn PDFs into structured, queryable, citable content — fast, offline, and without sending the document anywhere. Scribe ships as a Swift Package today; a universal runtime is deferred (see [ADR-0003](../architecture/adr/0003-defer-universal-js-runtime.md)).

The bootstrap plan's broader vision (apps, research lab, multi-doc collections, candidate-promotion gates) is the destination. The v1 product is the *library* that makes that destination possible.

## v1 user jobs

Grounded in real consumer behavior, not aspirational:

1. **Extract a clean structured representation of a PDF book.**
   _Consumer: rsvp-reader._ Given a PDF, produce `contentStructure` JSON with chapters, footnotes, images, headers stripped, reading order preserved, and tokenization parity with a known JS tokenizer.

2. **Extract structured content AND run on-device intelligence over it.**
   _Consumer: velo-macos._ Given a PDF, produce extraction + language detection + entity extraction; when Apple Intelligence is available, additionally produce summary, classification, and answer-with-context Q&A.

3. **Verify extraction quality against a versioned corpus.**
   _Consumer: developers / agents iterating on Scribe._ Run the fidelity scorer on the corpus, compare to locked baselines, fail on regression beyond a documented tolerance.

A v1 user job is a job at least one current consumer actually performs.

## Non-goals for v1

- Server-side or GPU-dependent extraction (the entire competitive position is on-device).
- Editing or rewriting documents — Scribe is a reader/extractor, not an authoring tool.
- Universal JS runtime — deferred (ADR-0003).
- Multi-document collections, cross-document retrieval, notebook abstractions — Phase 5 of the bootstrap plan.
- Continuous on-device model training or self-rewriting agent loops.
- A standalone Scribe end-user app — apps live in consumer repos.
- Cloud features in the default path. (An explicitly opted-in remote model could be considered later via ADR.)

## Target platforms and OS gates

| Capability | Minimum |
|---|---|
| Extraction core (`ScribeProcessor`) | iOS 15+ / macOS 12+, Swift 5.9+ |
| `LanguageAnalyzer` (NaturalLanguage) | Same as extraction core |
| `DocumentIntelligence`, `SemanticAnalyzer` (FoundationModels `@Generable` / `SystemLanguageModel`) | iOS 26+ / macOS 26+, Apple Intelligence enabled |
| `StructuralAnalyzer` (Vision RecognizeDocumentsRequest) | iOS 26+ / macOS 26+ |
| `eval/` harness | Node 18+ |

All optional layers MUST gracefully degrade when their OS minimum or runtime availability is not met. Consumers targeting older OS versions can use `ScribeProcessor` directly for extraction and `LanguageAnalyzer` for NLP-only analysis. `DocumentIntelligence.isAvailable` is the public signal for FoundationModels runtime availability (returns false when Apple Intelligence is not enabled even on a supported OS).

The iOS 26 / macOS 26 floor on the AI surface came from a measurement: `@Generable`, `@Guide`, and `SystemLanguageModel.default` are only available in iOS 26+ / macOS 26+ SDKs even though FoundationModels first shipped in iOS 18 / macOS 15. The earlier OSes lack the structured-output API the intelligence layer relies on.

## Privacy principles

See [`../ops/privacy-principles.md`](../ops/privacy-principles.md). In short: no document bytes leave the device in the default path, ever.

## Success metrics (initial)

### Extraction quality
- `eval/regression.js` on the locked 11-book corpus stays within 2% of baseline on all 7 dimensions (current default tolerance).
- Schema validity: 100% of `predicted.json` outputs validate against `shared/content-structure.schema.json`.

### Runtime
- p50 extraction latency on the primary test book (`healing-dream`) on the developer Mac: tracked, not yet budgeted.
- Peak memory: tracked, not yet budgeted.
- Budgets per device class are a Phase 2 (Apple flagship) deliverable.

### Consumer stability
- `rsvp-reader` builds and runs against any tagged Scribe release without API changes.
- `velo-macos` builds and runs against the same tagged release.

### Intelligence quality (deferred)
- No benchmark gate yet for summary, classification, or QA outputs. On backlog.

## Consumers and what they need

See [`../../CONSUMERS.md`](../../CONSUMERS.md) for the authoritative API surface list. Summary:

| Consumer | Platform | Uses |
|---|---|---|
| `rsvp-reader` | iOS, Capacitor+Svelte | Extraction core only, via Capacitor bridge |
| `velo-macos` | macOS, SwiftUI | Extraction + `DocumentIntelligence` end-to-end |

Both consumers MUST be considered before any change to:
- The `contentStructure` schema
- `ScribeProcessor.extractContent(from:)` / `processForTest(url:)` signatures or return shape
- `ScribeTokenizer.parseText()` behavior or word-index semantics
- `DocumentIntelligence` public surface (velo-macos only)

## Release cadence

`0.x` while the API and schema are still churning. Cut to `1.0` only when the milestone-gates exit criteria are met: schema churn slowed, regression runs repeatable, consumer contracts exercised end-to-end. Release process in [`../ops/release-process.md`](../ops/release-process.md).

## Out-of-scope-for-now backlog items

Held in [`../../BACKLOG.md`](../../BACKLOG.md). Examples: chunking-for-retrieval, citation-span generation, embedding index, candidate-promotion gate, JS runtime.
