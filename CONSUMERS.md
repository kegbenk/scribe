# Scribe Consumers

Projects that depend on Scribe. **Changes to Scribe's public API or behavior must be validated against all consumers.**

## rsvp-reader (PRIMARY)

**Location:** `../rsvp-reader` (`/Users/benjaminkeller/PLEROMA/BOOKTECH/rsvp-reader`)
**Platform:** iOS (Capacitor/Svelte hybrid app)
**Dependency:** SPM from GitHub (`kegbenk/scribe`, version 0.1.1)
**Integration:** Native Swift via Capacitor plugin

### API surface used

| API | Location in rsvp-reader |
|---|---|
| `ScribeProcessor.extractContent(from:)` | `ios/App/App/VeloPDFProcessor.swift:174` |
| `ScribeProcessor.processForTest(url:)` | `ios/App/App/VeloPDFProcessor.swift:168` |
| `ScribeTokenizer.parseText()` | `ios/App/App/VeloPDFProcessor.swift:184` |

### Data contract

Returns `contentStructure` JSON to the JavaScript layer via Capacitor bridge. Schema defined in `rsvp-reader/shared/content-structure.schema.json`.

Fields consumed: `chapters` (title, plainText, htmlContent, wordCount, footnotes, images, isBackMatter, startPage, startWordIndex, endWordIndex), `toc`, `hasStructure`, `images`.

### What breaks rsvp-reader

- Removing or renaming `ScribeProcessor.extractContent(from:)` or `processForTest(url:)`
- Removing or renaming `ScribeTokenizer.parseText()`
- Changing the return type or key names of the `contentStructure` dictionary
- Changing chapter text output in ways that break tokenization parity
- Adding iOS-incompatible code without `#if os()` guards

---

## velo-macos

**Location:** `../velo-macos` (`/Users/benjaminkeller/PLEROMA/BOOKTECH/velo-macos`)
**Platform:** macOS (SwiftUI native app)
**Dependency:** Local SPM path (`../scribe`)
**Integration:** Direct Swift API calls

### API surface used

| API | Location in velo-macos |
|---|---|
| `DocumentIntelligence()` | `Services/DocumentImportService.swift`, `Services/IntelligenceService.swift` |
| `intelligence.extract(document:)` | `Services/DocumentImportService.swift:38` |
| `intelligence.detectLanguage(of:)` | `Services/IntelligenceService.swift:110` |
| `intelligence.extractEntities(from:)` | `Services/IntelligenceService.swift:111` |
| `intelligence.analyzeSentiment(of:)` | `Services/IntelligenceService.swift:112` |
| `intelligence.summarize(_:)` | `Services/IntelligenceService.swift:134` |
| `intelligence.classify(_:)` | `Services/IntelligenceService.swift:145` |
| `intelligence.ask(_:context:)` | `Services/IntelligenceService.swift:171` |
| `DocumentIntelligence.isAvailable` | `Services/IntelligenceService.swift:29, 130` |
| `DocumentIntelligenceError.documentEmpty` | `Services/IntelligenceService.swift:167` |

### What breaks velo-macos

- Removing or renaming any `DocumentIntelligence` method
- Changing `ExtractionResult` struct (chapters, fullText, hasStructure)
- Changing NLP result types (`LanguageDetection`, `NamedEntity`, `DocumentSummary`, `DocumentClassification`)
