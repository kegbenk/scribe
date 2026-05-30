import CoreGraphics
import Foundation
import FoundationModels
import PDFKit

/// On-device document intelligence powered by Apple Intelligence.
///
/// `DocumentIntelligence` provides a unified API for extracting content from PDFs and
/// analyzing it using on-device AI models. All processing runs locally — no data leaves
/// the device.
///
/// ```swift
/// let intelligence = DocumentIntelligence()
///
/// // Full pipeline: extraction + AI analysis → enriched ContentStructure JSON
/// let json = try await intelligence.process(document: pdfURL)
///
/// // Or get typed analysis result
/// let analysis = try await intelligence.analyze(document: pdfURL)
/// print(analysis.summary.text)
/// print(analysis.classification.genre)
/// ```
///
/// Available on iOS 26+ / macOS 26+. Consumers targeting older OS versions can use
/// `ScribeProcessor` directly for extraction and `LanguageAnalyzer` for NLP-only analysis.
@available(iOS 26.0, macOS 26.0, *)
public struct DocumentIntelligence: Sendable {

    public init() {}

    // MARK: - Availability

    /// Whether Apple Intelligence on-device models are available.
    ///
    /// Returns `false` if the device doesn't support Apple Intelligence, the user
    /// hasn't enabled it, or the model is still downloading. NLP features
    /// (entity extraction, language detection) work regardless.
    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: - Full Pipeline (ContentStructure JSON output)

    /// Process a PDF with the full intelligence pipeline and return a ContentStructure-compatible
    /// dictionary ready for JSON serialization.
    ///
    /// This is the primary integration point — it produces the same JSON schema as the
    /// existing extraction pipeline, enriched with intelligence data:
    /// - Per-chapter `entities` (people, places, organizations)
    /// - Top-level `intelligence` block (summary, classification, language, global entities)
    ///
    /// If Apple Intelligence is unavailable, NLP features (entities, language) are still
    /// included but the `intelligence` block's `summary` and `classification` will be absent.
    public func process(document url: URL) async throws -> [String: Any] {
        // 1. Extract content (existing sync pipeline)
        let processor = ScribeProcessor()
        guard let result = processor.processFileForResult(url: url) else {
            throw DocumentIntelligenceError.extractionFailed
        }

        let fullText = result.text
        guard !fullText.isEmpty else {
            throw DocumentIntelligenceError.documentEmpty
        }

        // 2. Enrich chapters with per-chapter NLP entities (sync, no AI needed)
        var chapters = result.chapters
        for i in 0..<chapters.count {
            let chapterText = chapters[i]["plainText"] as? String ?? ""
            if !chapterText.isEmpty {
                let entities = LanguageAnalyzer.extractEntities(from: chapterText)
                chapters[i]["entities"] = [
                    "people": entities.filter { $0.type == .person }.map(\.text),
                    "places": entities.filter { $0.type == .place }.map(\.text),
                    "organizations": entities.filter { $0.type == .organization }.map(\.text),
                ] as [String: Any]
            }
        }

        // 3. Detect language and extract global entities (sync NLP)
        let language = LanguageAnalyzer.detectLanguage(of: fullText)
        let globalEntities = LanguageAnalyzer.extractEntities(from: fullText)

        // 4. Run AI analysis if available (async Foundation Models)
        var summaryDict: [String: Any]? = nil
        var classificationDict: [String: Any]? = nil

        if Self.isAvailable {
            async let summaryTask = SemanticAnalyzer.summarize(fullText, style: .concise)
            async let classificationTask = SemanticAnalyzer.classify(fullText)

            if let summary = try? await summaryTask {
                summaryDict = [
                    "text": summary.text,
                    "keyPoints": summary.keyPoints,
                    "topics": summary.topics,
                ]
            }

            if let classification = try? await classificationTask {
                classificationDict = [
                    "genre": classification.genre,
                    "subject": classification.subject,
                    "readingLevel": classification.readingLevel,
                    "audience": classification.audience,
                    "tone": classification.tone,
                ]
            }
        }

        // 5. Build intelligence block
        var intelligenceDict: [String: Any] = [
            "language": [
                "dominant": language.dominantLanguage,
                "confidence": language.confidence,
            ] as [String: Any],
            "entities": [
                "people": globalEntities.filter { $0.type == .person }.map(\.text),
                "places": globalEntities.filter { $0.type == .place }.map(\.text),
                "organizations": globalEntities.filter { $0.type == .organization }.map(\.text),
            ] as [String: Any],
        ]

        if let summary = summaryDict {
            intelligenceDict["summary"] = summary
        }
        if let classification = classificationDict {
            intelligenceDict["classification"] = classification
        }

        // 6. Build ContentStructure-compatible output
        return buildContentStructure(
            chapters: chapters,
            hasStructure: result.hasStructure,
            source: url.lastPathComponent,
            intelligence: intelligenceDict
        )
    }

    // MARK: - Typed Analysis

    /// Analyze a PDF document and return a typed `DocumentAnalysis` result.
    public func analyze(document url: URL) async throws -> DocumentAnalysis {
        let extraction = try performExtraction(from: url)

        guard !extraction.fullText.isEmpty else {
            throw DocumentIntelligenceError.documentEmpty
        }

        let text = extraction.fullText

        async let summaryTask = summarize(text)
        async let classificationTask = classify(text)
        let entities = extractEntities(from: text)
        let language = detectLanguage(of: text)

        return try await DocumentAnalysis(
            extraction: extraction,
            summary: summaryTask,
            classification: classificationTask,
            entities: entities,
            language: language
        )
    }

    // MARK: - Extraction Only

    /// Extract content from a PDF without AI analysis.
    /// Works on all Apple devices regardless of Apple Intelligence availability.
    public func extract(document url: URL) throws -> ExtractionResult {
        try performExtraction(from: url)
    }

    /// Extract content and enrich with NLP-only analysis (entities, language).
    /// No Apple Intelligence required — uses NaturalLanguage framework only.
    public func extractWithNLP(document url: URL) throws -> [String: Any] {
        let processor = ScribeProcessor()
        guard let result = processor.processFileForResult(url: url) else {
            throw DocumentIntelligenceError.extractionFailed
        }

        var chapters = result.chapters
        for i in 0..<chapters.count {
            let chapterText = chapters[i]["plainText"] as? String ?? ""
            if !chapterText.isEmpty {
                let entities = LanguageAnalyzer.extractEntities(from: chapterText)
                chapters[i]["entities"] = [
                    "people": entities.filter { $0.type == .person }.map(\.text),
                    "places": entities.filter { $0.type == .place }.map(\.text),
                    "organizations": entities.filter { $0.type == .organization }.map(\.text),
                ] as [String: Any]
            }
        }

        let language = LanguageAnalyzer.detectLanguage(of: result.text)
        let globalEntities = LanguageAnalyzer.extractEntities(from: result.text)

        let intelligenceDict: [String: Any] = [
            "language": [
                "dominant": language.dominantLanguage,
                "confidence": language.confidence,
            ] as [String: Any],
            "entities": [
                "people": globalEntities.filter { $0.type == .person }.map(\.text),
                "places": globalEntities.filter { $0.type == .place }.map(\.text),
                "organizations": globalEntities.filter { $0.type == .organization }.map(\.text),
            ] as [String: Any],
        ]

        return buildContentStructure(
            chapters: chapters,
            hasStructure: result.hasStructure,
            source: url.lastPathComponent,
            intelligence: intelligenceDict
        )
    }

    // MARK: - Individual Capabilities

    public func summarize(_ text: String, style: SummaryStyle = .concise) async throws -> DocumentSummary {
        try await SemanticAnalyzer.summarize(text, style: style)
    }

    public func classify(_ text: String) async throws -> DocumentClassification {
        try await SemanticAnalyzer.classify(text)
    }

    public func extractEntities(from text: String) -> [NamedEntity] {
        LanguageAnalyzer.extractEntities(from: text)
    }

    public func detectLanguage(of text: String) -> LanguageDetection {
        LanguageAnalyzer.detectLanguage(of: text)
    }

    public func ask(_ question: String, context: String) async throws -> String {
        try await SemanticAnalyzer.ask(question, context: context)
    }

    public func analyzePageStructure(of image: CGImage) async throws -> PageStructure {
        try await StructuralAnalyzer.analyzePageStructure(of: image)
    }

    public func recognizeText(in image: CGImage) async throws -> [String] {
        try await StructuralAnalyzer.recognizeText(in: image)
    }

    public func analyzeSentiment(of text: String) -> Double {
        LanguageAnalyzer.analyzeSentiment(of: text)
    }

    // MARK: - Private

    private func performExtraction(from url: URL) throws -> ExtractionResult {
        let processor = ScribeProcessor()
        guard let result = processor.processFileForResult(url: url) else {
            throw DocumentIntelligenceError.extractionFailed
        }

        let chapters = result.chapters.map { dict -> ExtractionResult.Chapter in
            ExtractionResult.Chapter(
                title: dict["title"] as? String ?? "Untitled",
                text: dict["plainText"] as? String ?? "",
                startPage: dict["startPage"] as? Int ?? 0,
                isBackMatter: dict["isBackMatter"] as? Bool ?? false,
                level: dict["level"] as? Int ?? 0
            )
        }

        return ExtractionResult(
            fullText: result.text,
            chapters: chapters,
            hasStructure: result.hasStructure
        )
    }

    private func buildContentStructure(
        chapters: [[String: Any]],
        hasStructure: Bool,
        source: String,
        intelligence: [String: Any]
    ) -> [String: Any] {
        var toc: [[String: Any]] = []
        var allImages: [[String: Any]] = []

        for (i, chapter) in chapters.enumerated() {
            toc.append([
                "title": chapter["title"] as? String ?? "Untitled",
                "wordIndex": chapter["startWordIndex"] as? Int ?? 0,
                "chapterIndex": i,
            ])

            if let images = chapter["images"] as? [[String: Any]] {
                allImages.append(contentsOf: images)
            }
        }

        let totalWords = chapters.reduce(0) { $0 + ($1["wordCount"] as? Int ?? 0) }

        return [
            "chapters": chapters,
            "toc": toc,
            "hasStructure": hasStructure,
            "images": allImages,
            "metadata": [
                "source": source,
                "version": "scribe-0.2.0",
                "totalChapters": chapters.count,
                "totalWords": totalWords,
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
            ] as [String: Any],
            "intelligence": intelligence,
        ]
    }
}
