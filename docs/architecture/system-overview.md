# Scribe — System Overview

Companion to [`AGENT_BOOTSTRAP_PLAN.md`](../../AGENT_BOOTSTRAP_PLAN.md). The plan describes the destination; this document describes the **current state** and how to read the repo today.

## What Scribe is today

A Swift package providing on-device PDF content extraction (Apple frameworks only, no network, no ML models required), plus a Node-based fidelity evaluation harness with a versioned test corpus. The extraction layer ships to two real consumers; an opt-in `DocumentIntelligence` layer sits on top for Apple-native NLP + Apple Intelligence enrichment.

## Mapping current repo → bootstrap plan vocabulary

| Plan concept (`AGENT_BOOTSTRAP_PLAN.md`) | Where it lives today | State |
|---|---|---|
| Lane A: Apple-native runtime | `swift/Sources/Scribe/` | Partial — extraction core shipping; no app shell yet |
| Lane B: Universal runtime (TS/JS) | _(not present)_ | Deferred (see ADR-0003) |
| Stream 2 — Shared contracts | `shared/content-structure.schema.json`, `shared/tokenizer/` | Partial — schema exists, no `TaskDefinition` / `EvalCase` / `ModelArtifactManifest` yet |
| Stream 3 — Ingestion / parsing | `swift/Sources/Scribe/TextExtraction.swift`, `ChapterDetection.swift`, `FootnoteDetection.swift`, `ImageExtraction.swift`, `BookClassifier.swift`, `RunningHeaderDetection.swift` | Functional |
| Stream 3 — Normalization / chunking | `swift/Sources/Scribe/ContentStructure.swift` | Chapter-level only; no embedding-friendly chunking yet |
| Stream 4 — Retrieval / evidence | _(not present)_ | Not started |
| Language orchestration (summarize / extract / QA) | `swift/Sources/Scribe/DocumentIntelligence.swift`, `SemanticAnalysis.swift`, `LanguageAnalysis.swift`, `StructuralAnalysis.swift` | Opt-in enrichment layer (see ADR-0002) |
| Stream 5 — Apple app | `../velo-macos`, `../rsvp-reader` | Lives in consumer repos, not here |
| Stream 7 — Evaluation harness | `eval/regression.js`, `eval/score.js`, `eval/inspect.js`, `eval/aggregate.js` | Functional — 7-dimension fidelity scoring |
| Stream 7 — Gold sets | `corpus/` (11 books with `native.json` + `baseline.json`) | Functional |
| Stream 8 — Research / optimization loop | `vision/` (MLX experiments), `converters/` (Marker comparison) | Exploratory, not formalized |
| Plan dirs `apps/`, `packages/`, `research/`, `tooling/`, `data/`, `tests/` | _(not created)_ | Deferred — the plan's own rule ("no infrastructure without a concrete consumer") applies |

## Current architecture

```
PDF
 │
 ▼
ScribeProcessor                      ← stable public API; what rsvp-reader uses
 ├─ BookClassifier (digital vs scanned, academic vs general)
 ├─ TextExtraction (PDFKit + Vision OCR fallback, two-column split)
 ├─ ChapterDetection (outline → TOC parse → heading heuristics)
 ├─ FootnoteDetection (6 strategies, profile-driven)
 ├─ RunningHeaderDetection
 ├─ ImageExtraction (XObject + render fallback, pixel-size gating)
 └─ ContentStructure ─► contentStructure JSON (shared/content-structure.schema.json)
                          │
                          ▼
                       DocumentIntelligence     ← opt-in, what velo-macos uses
                          ├─ LanguageAnalyzer (NaturalLanguage; iOS 15+ / macOS 12+)
                          ├─ SemanticAnalyzer (FoundationModels @Generable; iOS 26+ / macOS 26+)
                          └─ StructuralAnalyzer (Vision RecognizeDocumentsRequest; iOS 26+ / macOS 26+)
```

Evaluation runs separately:

```
corpus/{book}/native.json (gold)
corpus/{book}/predicted.json (current run)
        │
        ▼
eval/score.js  ─► fidelity-report.json (7 dimensions)
eval/regression.js (compare vs baseline.json, tolerance 2%)
eval/aggregate.js (cross-book report)
```

## Public consumers

Tracked in [`../../CONSUMERS.md`](../../CONSUMERS.md). Any change to `ScribeProcessor.extractContent(from:)`, `ScribeProcessor.processForTest(url:)`, `ScribeTokenizer.parseText()`, the `contentStructure` schema, or `DocumentIntelligence`'s public surface must be validated against both consumers before tagging.

- `rsvp-reader` — iOS, SPM from GitHub, uses extraction only
- `velo-macos` — macOS SwiftUI, local SPM path, uses `DocumentIntelligence` end-to-end

## What's intentionally not here yet

Per the bootstrap plan's "no infrastructure without a consumer" rule, these are deferred until there's something to put in them:

- **Universal JS runtime** (Lane B) — ADR-0003; revisit when Apple baseline stabilizes
- **Multi-document collections / cross-doc retrieval** — Phase 5 of plan
- **Retrieval / embeddings index** — Phase 1 deliverable not started; gated on a concrete consumer flow
- **Citation spans + answer-with-evidence schema** — on backlog
- **Experiment runner / candidate promotion gate** — Phase 4
- **`tests/` directory** — Swift unit tests live in `swift/Tests/` (SPM convention); eval acts as integration suite
- **`apps/` directory** — apps live in their own repos (`velo-macos`, `rsvp-reader`)

## Why the existing layout stays put

`velo-macos` references this repo via local SPM path (`../scribe`). `rsvp-reader` references it via `kegbenk/scribe` GitHub SPM. Renaming `swift/`, `shared/`, `eval/`, or `corpus/` would break both consumers and require a coordinated multi-repo cut. Defer the rename to a tagged 1.x release if and when the plan's `packages/core/`, `packages/contracts/`, `packages/eval/` layout is justified by an actual second-runtime consumer.

## Current milestone

From [`../../MILESTONE_GATES.md`](../../MILESTONE_GATES.md): *stabilize the extraction contract while the new document-intelligence layers are being added.* Exit criteria are tracked there. This milestone closes the open "what is DocumentIntelligence?" question via [ADR-0002](adr/0002-document-intelligence-as-optional-enrichment.md).
