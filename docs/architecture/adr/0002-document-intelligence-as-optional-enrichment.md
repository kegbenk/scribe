# ADR-0002 — DocumentIntelligence is an opt-in enrichment layer, not part of the default extraction pipeline

**Status:** Accepted — 2026-05-15

## Context

[`MILESTONE_GATES.md`](../../../MILESTONE_GATES.md) lists an open decision: are the recently-added document-intelligence modules part of the default extraction pipeline, an optional enrichment, or an experimental branch?

The relevant code (uncommitted at the time of writing):

- `swift/Sources/Scribe/DocumentIntelligence.swift` — facade over `ScribeProcessor` + NLP + AI
- `swift/Sources/Scribe/LanguageAnalysis.swift` — `NaturalLanguage.framework` wrapper (entities, language detection, sentiment). Available on all supported OS versions.
- `swift/Sources/Scribe/SemanticAnalysis.swift` — `FoundationModels` wrapper (summarization, classification, QA). Requires iOS 26+ / macOS 26+ (uses `@Generable` and `SystemLanguageModel.default`, which are part of the structured-output API added in those SDKs) and Apple Intelligence enabled on-device. Gated via `@available(iOS 26.0, macOS 26.0, *)`.
- `swift/Sources/Scribe/StructuralAnalysis.swift` — `Vision.RecognizeDocumentsRequest`. Requires iOS 26+ / macOS 26+.
- `swift/Sources/Scribe/IntelligenceModels.swift` — result types
- `swift/Sources/ScribeCLI/ScribeCLI.swift` — adds `--entities` flag on `extract` and a new `analyze` command
- `shared/content-structure.schema.json` — adds an **optional** `intelligence` block

Live consumers ([`CONSUMERS.md`](../../../CONSUMERS.md)) split cleanly along this line:

- **rsvp-reader** uses `ScribeProcessor.extractContent(from:)` and `ScribeTokenizer.parseText()`. Does not touch `DocumentIntelligence`. iOS-deploying via Capacitor.
- **velo-macos** uses `DocumentIntelligence` end-to-end (`extract`, `detectLanguage`, `extractEntities`, `analyzeSentiment`, `summarize`, `classify`, `ask`, `isAvailable`).

The bootstrap plan principle: *prefer deterministic retrieval, ranking, parsing, and structured extraction stages before asking a language model to improvise.* The plan also requires that *no model or prompt change ship without benchmark comparison.*

## Decision

`DocumentIntelligence` and its supporting modules (`LanguageAnalyzer`, `SemanticAnalyzer`, `StructuralAnalyzer`, `IntelligenceModels`) are a **first-class but optional** public surface of the Scribe library. They are not invoked by `ScribeProcessor` and do not gate or alter its output.

Operationally:

1. `ScribeProcessor.extractContent(from:)` and `ScribeProcessor.processForTest(url:)` remain the stable extraction contract. They run no language-model code, no FoundationModels code, no entity recognition. Pure deterministic extraction.
2. `DocumentIntelligence` is a separate type. Consumers instantiate it explicitly. Internally it calls `ScribeProcessor` for extraction, then layers NLP and (optionally, gated on `isAvailable`) AI analysis on top.
3. The `intelligence` block in `content-structure.schema.json` is `optional`. Consumers that ignore it MUST continue to validate against the schema. Producers that omit it MUST still emit valid JSON.
4. The CLI keeps the original `extract` command as the deterministic baseline. `extract --entities` and `analyze` are explicit opt-ins.
5. The eval harness (`eval/regression.js`, `eval/score.js`) scores `ScribeProcessor` output only. AI-generated fields (summary, classification) are out of scope for the current fidelity gate.

## Consequences

**For consumers:**
- `rsvp-reader` requires zero changes. The extraction API surface it uses is unchanged.
- `velo-macos` keeps its existing usage. `DocumentIntelligence` is now formally documented as a supported (if 0.x-versioned) public API.

**For the codebase:**
- `ScribeProcessor` must stay free of LLM / Apple-Intelligence imports. CI / code review should flag any PR that adds `import FoundationModels` or `import StructuralAnalysis`-equivalent code into `ScribeProcessor.swift` or its sibling extraction modules. `import NaturalLanguage` is permitted in extraction code **only** for deterministic uses (e.g., `NLLanguageRecognizer` to feed Vision OCR `recognitionLanguages`). Using `NLTagger` for entity extraction in extraction code is not permitted — that belongs in `LanguageAnalyzer`.
- `DocumentIntelligence` MAY import and call `ScribeProcessor`. The reverse is forbidden.
- New extraction features land in the existing extraction modules and are scored by `eval/`. New intelligence features land in `DocumentIntelligence`-adjacent modules and need their own quality bar (TBD — see backlog).

**For the schema:**
- `intelligence` stays optional. Adding required fields inside `intelligence` is fine. Promoting the `intelligence` block itself to required would be a breaking change requiring a new ADR.

**For the eval harness:**
- No change to the 7-dimension fidelity score.
- A separate intelligence-quality benchmark (summarization coverage, entity precision/recall) is on backlog. Until it exists, intelligence changes ship with code review only, not a benchmark gate.

## Alternatives considered

1. **Make intelligence the default pipeline.** Rejected: would force `rsvp-reader` to take a dependency on FoundationModels availability, regress cold-start latency for the simple-extraction case, and conflate two quality bars under one benchmark gate. Also violates the plan's "deterministic core" principle.

2. **Treat intelligence as an experimental branch.** Rejected: `velo-macos` is already using it in production. Calling it experimental misrepresents the operational reality and would force a contract change at `velo-macos`.

3. **Split intelligence into a separate SPM package (`ScribeIntelligence`) that depends on `Scribe`.** Considered viable but deferred. Doing it now requires consumer updates and a coordinated release. Revisit if (a) intelligence modules grow large enough to bloat the extraction binary, or (b) a non-Apple runtime needs to consume extraction without intelligence. Tracked on backlog.

## Acceptance signals

- `ScribeProcessor` source files contain no `import FoundationModels`. `import NaturalLanguage` is permitted in extraction code only when used for deterministic OCR-language configuration or similar (no `NLTagger` entity extraction). Manual check until a CI rule exists.
- `rsvp-reader` builds and passes its smoke tests against any tagged Scribe release without referencing `DocumentIntelligence`.
- `velo-macos` builds and passes its smoke tests against the same tagged release.
- `eval/regression.js` on the locked corpus baselines does not regress as a result of intelligence-layer changes.

## Revisit triggers

- A non-Apple runtime (Lane B per [ADR-0003](0003-defer-universal-js-runtime.md)) needs extraction without intelligence — split into separate packages.
- Intelligence-layer code grows beyond ~5 source files or starts pulling in a model artifact > 10 MB — split into separate packages.
- A consumer requests a guaranteed-deterministic mode where intelligence cannot be invoked at all — consider build-time exclusion.
