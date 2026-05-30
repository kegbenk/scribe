import Foundation
import FoundationModels

// MARK: - Generable Types (Foundation Models structured generation)

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedSummary {
    @Guide(description: "A concise summary of the document content in 2-3 sentences")
    var summary: String

    @Guide(description: "The key points or main arguments from the document", .count(3...7))
    var keyPoints: [String]

    @Guide(description: "Primary topics or themes discussed in the document", .count(1...5))
    var topics: [String]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedClassification {
    @Guide(description: "The document genre", .anyOf([
        "Fiction", "Non-Fiction", "Academic", "Technical",
        "Legal", "Medical", "Poetry", "Reference", "Journalism"
    ]))
    var genre: String

    @Guide(description: "The primary subject area of the document")
    var subject: String

    @Guide(description: "Reading difficulty level", .anyOf([
        "Elementary", "Intermediate", "Advanced", "Expert"
    ]))
    var readingLevel: String

    @Guide(description: "The intended audience for this document")
    var audience: String

    @Guide(description: "The overall tone of the writing", .anyOf([
        "Formal", "Informal", "Academic", "Conversational",
        "Technical", "Literary", "Journalistic"
    ]))
    var tone: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedAnswer {
    @Guide(description: "A direct answer to the question based on the provided context")
    var answer: String

    @Guide(description: "Confidence level in the answer", .anyOf(["high", "medium", "low"]))
    var confidence: String
}

// MARK: - Public Result Types

/// Style of summary to generate.
public enum SummaryStyle: String, Sendable {
    /// 1-2 sentence summary.
    case brief
    /// Single paragraph with key points.
    case concise
    /// Multi-paragraph with comprehensive key points and topics.
    case detailed
}

/// AI-generated document summary.
public struct DocumentSummary: Sendable {
    /// The summary text.
    public let text: String
    /// Key points or main arguments extracted from the document.
    public let keyPoints: [String]
    /// Primary topics or themes identified.
    public let topics: [String]
}

/// AI-generated document classification.
public struct DocumentClassification: Sendable {
    /// Genre (e.g., "Fiction", "Academic", "Technical").
    public let genre: String
    /// Primary subject area.
    public let subject: String
    /// Reading difficulty level.
    public let readingLevel: String
    /// Intended audience.
    public let audience: String
    /// Writing tone.
    public let tone: String
}

/// A named entity found in document text.
public struct NamedEntity: Sendable {
    /// The entity text as it appears in the document.
    public let text: String
    /// The type of entity.
    public let type: EntityType

    public enum EntityType: String, Sendable, CaseIterable {
        case person
        case place
        case organization
    }
}

/// A language hypothesis with confidence score.
public struct LanguageHypothesis: Sendable {
    /// BCP 47 language tag (e.g., "en", "fr", "de").
    public let language: String
    /// Confidence score from 0.0 to 1.0.
    public let confidence: Double
}

/// Language detection result.
public struct LanguageDetection: Sendable {
    /// The most likely language (BCP 47 tag).
    public let dominantLanguage: String
    /// Confidence in the dominant language (0.0–1.0).
    public let confidence: Double
    /// Alternative language hypotheses ranked by confidence.
    public let alternatives: [LanguageHypothesis]
}

/// Structural analysis of a document page image.
public struct PageStructure: Sendable {
    /// Full text transcript of the page.
    public let transcript: String
    /// Individual paragraphs detected on the page.
    public let paragraphs: [String]
    /// Tables detected on the page.
    public let tables: [TableData]
    /// Lists detected on the page.
    public let lists: [ListData]
    /// Structured data detected (emails, phones, URLs, etc.).
    public let detectedData: [DetectedDataItem]
}

/// A table extracted from a document page.
public struct TableData: Sendable {
    /// Rows of cell text values.
    public let rows: [[String]]
}

/// A list extracted from a document page.
public struct ListData: Sendable {
    /// List item texts.
    public let items: [String]
}

/// A piece of structured data detected in a document.
public struct DetectedDataItem: Sendable {
    /// The type of data detected.
    public let type: DataType
    /// The detected value.
    public let value: String

    public enum DataType: String, Sendable, CaseIterable {
        case email
        case phoneNumber
        case url
        case date
        case address
        case other
    }
}

/// Extracted content from a PDF, with chapter structure.
public struct ExtractionResult: Sendable {
    /// Full concatenated text of the document.
    public let fullText: String
    /// Detected chapters.
    public let chapters: [Chapter]
    /// Whether structural chapter boundaries were found.
    public let hasStructure: Bool

    public struct Chapter: Sendable {
        public let title: String
        public let text: String
        public let startPage: Int
        public let isBackMatter: Bool
        public let level: Int
    }
}

/// Complete result from the full intelligence pipeline.
public struct DocumentAnalysis: Sendable {
    /// Extracted content and chapter structure.
    public let extraction: ExtractionResult
    /// AI-generated summary.
    public let summary: DocumentSummary
    /// AI-generated classification.
    public let classification: DocumentClassification
    /// Named entities detected via NLP.
    public let entities: [NamedEntity]
    /// Language detection result.
    public let language: LanguageDetection
}

/// Errors from the document intelligence pipeline.
public enum DocumentIntelligenceError: Error, Sendable {
    /// Apple Intelligence models are not available on this device.
    case modelUnavailable(reason: String)
    /// PDF extraction failed (corrupt file, no pages, etc.).
    case extractionFailed
    /// On-device model generation failed.
    case generationFailed(String)
    /// Document has no extractable text.
    case documentEmpty
}
